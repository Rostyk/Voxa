import Darwin
import Foundation

/// Layout must match `AudioDriver/Common/VoxaMicRing.h`.
enum VoxaMicRingLayout {
    static let ringPath = "/var/tmp/com.aurigin.voxa.virtual_mic.ring"
    static let magic: UInt32 = 0x564F_5841 // 'VOXA'
    static let version: UInt32 = 2
    static let sampleRate: UInt32 = 48_000
    static let channelCount: UInt32 = 2
    static let capacityFrames: UInt32 = 16_384

    static let headerSize = 32
    static let sampleBytes = Int(capacityFrames * channelCount * 2)
    static let totalSize = headerSize + sampleBytes
}

/// Maps the ring file `VoxaMic.driver` reads from.
final class VoxaMicSharedMemory {
    private var fd: Int32 = -1
    private var mapped: UnsafeMutableRawPointer?
    let header: UnsafeMutablePointer<VoxaMicRingHeader>

    struct VoxaMicRingHeader {
        var magic: UInt32
        var version: UInt32
        var sampleRate: UInt32
        var channelCount: UInt32
        var capacityFrames: UInt32
        var reserved: UInt32
        var writeFrameIndex: UInt64
    }

    init?() {
        let path = VoxaMicRingLayout.ringPath
        fd = open(path, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else { return nil }

        if ftruncate(fd, off_t(VoxaMicRingLayout.totalSize)) != 0 {
            close(fd)
            return nil
        }

        guard let ptr = mmap(
            nil,
            VoxaMicRingLayout.totalSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        ), ptr != MAP_FAILED else {
            close(fd)
            return nil
        }
        mapped = ptr
        header = ptr.bindMemory(to: VoxaMicRingHeader.self, capacity: 1)
        let needsInit = header.pointee.magic != VoxaMicRingLayout.magic
            || header.pointee.version != VoxaMicRingLayout.version
            || header.pointee.sampleRate != VoxaMicRingLayout.sampleRate
            || header.pointee.channelCount != VoxaMicRingLayout.channelCount
            || header.pointee.capacityFrames != VoxaMicRingLayout.capacityFrames
        if needsInit {
            memset(ptr, 0, VoxaMicRingLayout.totalSize)
            header.pointee.magic = VoxaMicRingLayout.magic
            header.pointee.version = VoxaMicRingLayout.version
            header.pointee.sampleRate = VoxaMicRingLayout.sampleRate
            header.pointee.channelCount = VoxaMicRingLayout.channelCount
            header.pointee.capacityFrames = VoxaMicRingLayout.capacityFrames
            header.pointee.reserved = 0
            header.pointee.writeFrameIndex = 0
            print("[VoxaMic] Initialized ring file v\(VoxaMicRingLayout.version) @ \(VoxaMicRingLayout.sampleRate) Hz")
        }
    }

    func samplePointer() -> UnsafeMutablePointer<Int16> {
        let base = mapped!.advanced(by: VoxaMicRingLayout.headerSize)
        return base.bindMemory(to: Int16.self, capacity: Int(VoxaMicRingLayout.capacityFrames * VoxaMicRingLayout.channelCount))
    }

    deinit {
        if let mapped {
            munmap(mapped, VoxaMicRingLayout.totalSize)
        }
        if fd >= 0 {
            close(fd)
        }
    }
}
