import AVFoundation
import Darwin
import Foundation

enum VoxaMicRingWriter {
    static func reset(_ ring: VoxaMicSharedMemory) {
        ring.header.pointee.writeFrameIndex = 0
        memset(ring.samplePointer(), 0, VoxaMicRingLayout.sampleBytes)
        OSMemoryBarrier()
    }

    static func write(pcm: AVAudioPCMBuffer, to ring: VoxaMicSharedMemory, logEveryNTicks: UInt64 = 0, tick: UInt64 = 0) {
        guard pcm.frameLength > 0 else { return }

        let ringChannels = Int(VoxaMicRingLayout.channelCount)
        let capacity = Int(VoxaMicRingLayout.capacityFrames)
        let dst = ring.samplePointer()
        var writeIndex = ring.header.pointee.writeFrameIndex
        let frames = Int(pcm.frameLength)
        let srcChannels = max(1, Int(pcm.format.channelCount))

        var peak: Float = 0
        if let floatChannel = pcm.floatChannelData {
            for n in 0..<frames {
                let ringFrame = Int(writeIndex % UInt64(capacity))
                let dstOffset = ringFrame * ringChannels
                for c in 0..<ringChannels {
                    let srcChannel = min(c, srcChannels - 1)
                    let s = floatChannel[srcChannel][n]
                    peak = max(peak, abs(s))
                    dst[dstOffset + c] = Int16(max(-1.0, min(1.0, s)) * Float(Int16.max))
                }
                writeIndex += 1
            }
        } else if pcm.format.isInterleaved, let interleaved = pcm.int16ChannelData?[0] {
            for n in 0..<frames {
                let ringFrame = Int(writeIndex % UInt64(capacity))
                let dstOffset = ringFrame * ringChannels
                for c in 0..<ringChannels {
                    let srcChannel = min(c, srcChannels - 1)
                    let index = srcChannels == 1 ? n : (n * srcChannels + srcChannel)
                    let sample = interleaved[index]
                    peak = max(peak, abs(Float(sample) / Float(Int16.max)))
                    dst[dstOffset + c] = sample
                }
                writeIndex += 1
            }
        } else if let channelData = pcm.int16ChannelData {
            for n in 0..<frames {
                let ringFrame = Int(writeIndex % UInt64(capacity))
                let dstOffset = ringFrame * ringChannels
                for c in 0..<ringChannels {
                    let srcChannel = min(c, srcChannels - 1)
                    let sample = channelData[srcChannel][n]
                    peak = max(peak, abs(Float(sample) / Float(Int16.max)))
                    dst[dstOffset + c] = sample
                }
                writeIndex += 1
            }
        }

        ring.header.pointee.writeFrameIndex = writeIndex
        OSMemoryBarrier()

        if logEveryNTicks > 0, tick <= 5 || tick % logEveryNTicks == 0 {
            print("[VoxaMic] ring writeIndex=\(writeIndex) peak=\(String(format: "%.4f", peak))")
        }
    }
}
