import AVFoundation
import Foundation

/// Streams PCM into the virtual-mic ring (shared by DTMF and speech feeders).
enum VoxaMicRingPCMStreamer {
    private static let framesPerChunk: AVAudioFrameCount = 512

    struct Options: Sendable {
        /// When true, sleep between chunks so `writeFrameIndex` advances at ~real time (required for DTMF / IVR).
        var paceRealtime = false
        /// Linear gain applied to int16 samples before writing (DTMF tones benefit from a small boost).
        var gain: Float = 1.0
    }

    static func streamBuffer(
        _ buffer: AVAudioPCMBuffer,
        to ring: VoxaMicSharedMemory,
        logLabel: String? = nil,
        options: Options = Options()
    ) throws {
        guard let ringFormat = VoxaMicPCMFileLoader.ringFormat else {
            throw VoxaMicPCMFileLoader.Error.ringFormatUnavailable
        }

        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0 else {
            if let logLabel { print("[VoxaMic] streamBuffer \(logLabel): empty buffer — skip") }
            return
        }
        if let logLabel {
            print(
                "[VoxaMic] streamBuffer \(logLabel): \(totalFrames) frames → ring paceRealtime=\(options.paceRealtime) gain=\(options.gain)"
            )
        }

        let startWriteIndex = ring.header.pointee.writeFrameIndex
        var offset = 0
        var peak: Float = 0
        while offset < totalFrames {
            let chunkFrames = min(Int(framesPerChunk), totalFrames - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: ringFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
                return
            }
            chunk.frameLength = AVAudioFrameCount(chunkFrames)
            copyFrames(from: buffer, sourceOffset: offset, to: chunk, frameCount: chunkFrames, ringFormat: ringFormat)
            if options.gain != 1.0 {
                applyGain(options.gain, to: chunk)
            }
            peak = max(peak, measurePeak(chunk))
            VoxaMicRingWriter.write(pcm: chunk, to: ring, logEveryNTicks: 0, tick: 0)
            offset += chunkFrames
            if options.paceRealtime {
                let chunkSeconds = Double(chunkFrames) / ringFormat.sampleRate
                Thread.sleep(forTimeInterval: chunkSeconds)
            }
        }
        if let logLabel {
            let endWrite = ring.header.pointee.writeFrameIndex
            print(
                "[VoxaMic] streamBuffer \(logLabel): done writeIndex \(startWriteIndex)→\(endWrite) peak=\(String(format: "%.3f", peak))"
            )
        }
    }

    static func writeSilence(
        duration: TimeInterval,
        to ring: VoxaMicSharedMemory,
        paceRealtime: Bool = false
    ) throws {
        guard duration > 0, let ringFormat = VoxaMicPCMFileLoader.ringFormat else { return }
        let totalFrames = Int(duration * ringFormat.sampleRate)
        guard totalFrames > 0 else { return }

        var written = 0
        while written < totalFrames {
            let chunkFrames = min(Int(framesPerChunk), totalFrames - written)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: ringFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
                return
            }
            chunk.frameLength = AVAudioFrameCount(chunkFrames)
            if let data = chunk.int16ChannelData?[0] {
                data.initialize(repeating: 0, count: chunkFrames * Int(ringFormat.channelCount))
            }
            VoxaMicRingWriter.write(pcm: chunk, to: ring)
            written += chunkFrames
            if paceRealtime {
                Thread.sleep(forTimeInterval: Double(chunkFrames) / ringFormat.sampleRate)
            }
        }
    }

    private static func measurePeak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.int16ChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        var peak: Int16 = 0
        for i in 0..<count {
            peak = max(peak, abs(data[i]))
        }
        return Float(peak) / Float(Int16.max)
    }

    private static func applyGain(_ gain: Float, to buffer: AVAudioPCMBuffer) {
        guard gain != 1.0, let data = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        for i in 0..<count {
            let scaled = Float(data[i]) * gain
            data[i] = Int16(max(Float(Int16.min), min(Float(Int16.max), scaled)))
        }
    }

    private static func copyFrames(
        from source: AVAudioPCMBuffer,
        sourceOffset: Int,
        to destination: AVAudioPCMBuffer,
        frameCount: Int,
        ringFormat: AVAudioFormat
    ) {
        if ringFormat.isInterleaved,
           let dst = destination.int16ChannelData?[0],
           let src = source.int16ChannelData?[0] {
            let channels = Int(ringFormat.channelCount)
            let srcChannels = max(1, Int(source.format.channelCount))
            for offset in 0..<frameCount {
                let srcIndex = sourceOffset + offset
                for c in 0..<channels {
                    let sc = min(c, srcChannels - 1)
                    let si = srcChannels == 1 ? srcIndex : (srcIndex * srcChannels + sc)
                    dst[offset * channels + c] = src[si]
                }
            }
        } else if let dstCh = destination.floatChannelData, let srcCh = source.floatChannelData {
            let channels = Int(ringFormat.channelCount)
            let srcChannels = max(1, Int(source.format.channelCount))
            for offset in 0..<frameCount {
                let srcIndex = sourceOffset + offset
                for c in 0..<channels {
                    let sc = min(c, srcChannels - 1)
                    dstCh[c][offset] = srcCh[sc][srcIndex]
                }
            }
        }
    }
}
