// Shared ring buffer between Voxa.app (writer) and VoxaMic.driver (reader).
// POSIX shm — both processes map the same segment.

#pragma once

#include <cstdint>
#include <cstring>

/// World-readable path so coreaudiod (driver) and Voxa.app can map the same ring.
#define VOXA_MIC_RING_PATH "/var/tmp/com.aurigin.voxa.virtual_mic.ring"
#define VOXA_MIC_MAGIC 0x564F5841u /* 'VOXA' */
#define VOXA_MIC_VERSION 2
#define VOXA_MIC_SAMPLE_RATE 48000u
#define VOXA_MIC_CHANNEL_COUNT 2u
#define VOXA_MIC_CAPACITY_FRAMES 16384u

#pragma pack(push, 1)
struct VoxaMicRingHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved;
    volatile uint64_t writeFrameIndex;
};
#pragma pack(pop)

static inline size_t VoxaMicRingTotalSize()
{
    return sizeof(VoxaMicRingHeader)
        + static_cast<size_t>(VOXA_MIC_CAPACITY_FRAMES) * VOXA_MIC_CHANNEL_COUNT * sizeof(int16_t);
}

static inline int16_t* VoxaMicRingSamples(VoxaMicRingHeader* header)
{
    return reinterpret_cast<int16_t*>(header + 1);
}

static inline bool VoxaMicRingHeaderValid(const VoxaMicRingHeader* header)
{
    return header != nullptr && header->magic == VOXA_MIC_MAGIC && header->version == VOXA_MIC_VERSION
        && header->sampleRate == VOXA_MIC_SAMPLE_RATE && header->channelCount == VOXA_MIC_CHANNEL_COUNT
        && header->capacityFrames == VOXA_MIC_CAPACITY_FRAMES;
}

/// Read `numFrames` of interleaved SInt16 into `dest` for device sample position `startFrame`.
static inline void VoxaMicRingReadFrames(
    const VoxaMicRingHeader* header,
    uint64_t startFrame,
    uint32_t numFrames,
    int16_t* dest)
{
    if (!VoxaMicRingHeaderValid(header) || dest == nullptr || numFrames == 0) {
        return;
    }

    const uint64_t writeIndex = header->writeFrameIndex;
    const uint32_t capacity = header->capacityFrames;
    const uint32_t channels = header->channelCount;
    const int16_t* ring = VoxaMicRingSamples(const_cast<VoxaMicRingHeader*>(header));

    for (uint32_t n = 0; n < numFrames; n++) {
        const uint64_t frameIndex = startFrame + n;
        const int16_t* srcFrame = nullptr;

        if (frameIndex < writeIndex && writeIndex - frameIndex <= capacity) {
            const uint32_t ringFrame = static_cast<uint32_t>(frameIndex % capacity);
            srcFrame = ring + static_cast<size_t>(ringFrame) * channels;
        }

        int16_t* dstFrame = dest + static_cast<size_t>(n) * channels;
        if (srcFrame != nullptr) {
            for (uint32_t c = 0; c < channels; c++) {
                dstFrame[c] = srcFrame[c];
            }
        } else {
            for (uint32_t c = 0; c < channels; c++) {
                dstFrame[c] = 0;
            }
        }
    }
}

/// Read the most recently written frames (live passthrough; ignores HAL sample time).
static inline void VoxaMicRingReadLatestFrames(
    const VoxaMicRingHeader* header,
    uint32_t numFrames,
    int16_t* dest)
{
    if (!VoxaMicRingHeaderValid(header) || dest == nullptr || numFrames == 0) {
        return;
    }
    const uint64_t writeIndex = header->writeFrameIndex;
    const uint64_t readStart = (writeIndex >= numFrames) ? (writeIndex - numFrames) : 0;
    VoxaMicRingReadFrames(header, readStart, numFrames, dest);
}

/// Sequential consumer read — one ring frame per output frame (avoids repeat/skip distortion).
/// `readIndex` is driver state; `latencyFrames` keeps a small buffer for stable passthrough.
static inline void VoxaMicRingReadSequentialFrames(
    const VoxaMicRingHeader* header,
    uint64_t* readIndex,
    uint32_t numFrames,
    int16_t* dest,
    uint32_t latencyFrames = 2400)
{
    if (!VoxaMicRingHeaderValid(header) || readIndex == nullptr || dest == nullptr || numFrames == 0) {
        return;
    }

    const uint32_t capacity = header->capacityFrames;
    const uint32_t channels = header->channelCount;
    const int16_t* ring = VoxaMicRingSamples(const_cast<VoxaMicRingHeader*>(header));

    uint64_t writeIndex = header->writeFrameIndex;
    uint64_t ri = *readIndex;

    if (writeIndex < ri) {
        ri = 0;
    }

    const uint64_t backlog = writeIndex - ri;
    if (backlog > capacity) {
        ri = (writeIndex > latencyFrames) ? (writeIndex - latencyFrames) : 0;
    } else if (ri == 0 && writeIndex > latencyFrames) {
        ri = writeIndex - latencyFrames;
    }

    for (uint32_t n = 0; n < numFrames; n++) {
        writeIndex = header->writeFrameIndex;
        int16_t* dstFrame = dest + static_cast<size_t>(n) * channels;

        if (ri < writeIndex) {
            const uint32_t ringFrame = static_cast<uint32_t>(ri % capacity);
            const int16_t* srcFrame = ring + static_cast<size_t>(ringFrame) * channels;
            for (uint32_t c = 0; c < channels; c++) {
                dstFrame[c] = srcFrame[c];
            }
            ri++;
        } else {
            for (uint32_t c = 0; c < channels; c++) {
                dstFrame[c] = 0;
            }
        }
    }

    *readIndex = ri;
}
