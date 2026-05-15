// Copyright (c) Voxa — virtual input fed from Voxa.app via POSIX shared memory.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include "../Common/VoxaMicRing.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <memory>
#include <mutex>

namespace {

constexpr UInt32 SampleRate = VOXA_MIC_SAMPLE_RATE;
constexpr UInt32 ChannelCount = VOXA_MIC_CHANNEL_COUNT;

class RingMap {
public:
    RingMap() = default;

    RingMap(const RingMap&) = delete;
    RingMap& operator=(const RingMap&) = delete;

    RingMap(RingMap&& other) noexcept { *this = std::move(other); }

    RingMap& operator=(RingMap&& other) noexcept
    {
        if (this != &other) {
            Unmap();
            header_ = other.header_;
            mappedSize_ = other.mappedSize_;
            other.header_ = nullptr;
            other.mappedSize_ = 0;
        }
        return *this;
    }

    ~RingMap() { Unmap(); }

    void TryOpen()
    {
        if (header_ != nullptr && VoxaMicRingHeaderValid(header_)) {
            return;
        }
        Unmap();

        const int fd = open(VOXA_MIC_RING_PATH, O_RDONLY, 0);
        if (fd < 0) {
            return;
        }
        const size_t size = VoxaMicRingTotalSize();
        void* ptr = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (ptr == MAP_FAILED) {
            return;
        }
        auto* header = static_cast<VoxaMicRingHeader*>(ptr);
        if (!VoxaMicRingHeaderValid(header)) {
            munmap(ptr, size);
            return;
        }
        header_ = header;
        mappedSize_ = size;
    }

    const VoxaMicRingHeader* Header() const { return header_; }

private:
    void Unmap()
    {
        if (header_ != nullptr && mappedSize_ > 0) {
            munmap(header_, mappedSize_);
        }
        header_ = nullptr;
        mappedSize_ = 0;
    }

    VoxaMicRingHeader* header_ = nullptr;
    size_t mappedSize_ = 0;
};

class VoxaMicHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        (void)client;
        (void)stream;
        (void)zeroTimestamp;

        std::lock_guard<std::mutex> lock(mutex_);
        ring_.TryOpen();

        auto* samples = static_cast<int16_t*>(bytes);
        const UInt32 numFrames = bytesCount / sizeof(int16_t) / ChannelCount;

        if (!ring_.Header() || numFrames == 0) {
            std::memset(bytes, 0, bytesCount);
            return;
        }

        VoxaMicRingReadSequentialFrames(ring_.Header(), &readFrameIndex_, numFrames, samples);
    }

private:
    std::mutex mutex_;
    RingMap ring_;
    uint64_t readFrameIndex_ = 0;
};

std::shared_ptr<aspl::Driver> CreateVoxaMicDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "Voxa Virtual Microphone";
    deviceParams.SampleRate = SampleRate;
    deviceParams.ChannelCount = ChannelCount;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);
    device->AddStreamWithControlsAsync(aspl::Direction::Input);

    auto handler = std::make_shared<VoxaMicHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* VoxaMicEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateVoxaMicDriver();
    return driver->GetReference();
}
