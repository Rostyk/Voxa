import AVFoundation
import Foundation

/// TEMPORARY: loops `Audio.wav` into the virtual-mic ring at 48 kHz stereo (matches `VoxaMic.driver`).
final class VoxaMicWAVFileFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aurigin.test.Voxa.VoxaMicWAVFileFeeder", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var ring: VoxaMicSharedMemory?
    private var playbackBuffer: AVAudioPCMBuffer?
    private var playFramePosition: Int = 0
    private var tickCount: UInt64 = 0
    private var isRunning = false

    private static let framesPerTick: AVAudioFrameCount = 512
    private static let ringFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(VoxaMicRingLayout.sampleRate),
        channels: VoxaMicRingLayout.channelCount,
        interleaved: true
    )

    func start(url: URL, ring: VoxaMicSharedMemory) throws {
        try queue.sync {
            try startOnQueue(url: url, ring: ring)
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue(url: URL, ring: VoxaMicSharedMemory) throws {
        stopOnQueue()
        guard let ringFormat = Self.ringFormat else {
            throw FeedError.ringFormatUnavailable
        }

        self.ring = ring
        VoxaMicRingWriter.reset(ring)

        playbackBuffer = try Self.loadAndConvert(url: url, targetFormat: ringFormat)
        playFramePosition = 0
        tickCount = 0

        let interval = Double(Self.framesPerTick) / ringFormat.sampleRate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
        isRunning = true

        let frames = Int(playbackBuffer?.frameLength ?? 0)
        print("[VoxaMic] TEMP WAV feeder started — \(url.lastPathComponent) \(frames) frames @ \(Int(ringFormat.sampleRate)) Hz stereo (looping)")
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        playbackBuffer = nil
        ring = nil
        isRunning = false
        playFramePosition = 0
    }

    private func tick() {
        guard isRunning, let ring, let playbackBuffer, let ringFormat = Self.ringFormat else { return }

        let totalFrames = Int(playbackBuffer.frameLength)
        guard totalFrames > 0 else { return }

        guard let chunk = AVAudioPCMBuffer(pcmFormat: ringFormat, frameCapacity: Self.framesPerTick) else {
            return
        }

        let framesToCopy = min(Int(Self.framesPerTick), totalFrames)
        chunk.frameLength = AVAudioFrameCount(framesToCopy)

        if ringFormat.isInterleaved, let dst = chunk.int16ChannelData?[0], let src = playbackBuffer.int16ChannelData?[0] {
            for offset in 0..<framesToCopy {
                let srcIndex = (playFramePosition + offset) % totalFrames
                let channels = Int(ringFormat.channelCount)
                let srcChannels = max(1, Int(playbackBuffer.format.channelCount))
                for c in 0..<channels {
                    let sc = min(c, srcChannels - 1)
                    let si = srcChannels == 1 ? srcIndex : (srcIndex * srcChannels + sc)
                    dst[offset * channels + c] = src[si]
                }
            }
        } else if let dstCh = chunk.floatChannelData, let srcCh = playbackBuffer.floatChannelData {
            for offset in 0..<framesToCopy {
                let srcIndex = (playFramePosition + offset) % totalFrames
                let channels = Int(ringFormat.channelCount)
                let srcChannels = max(1, Int(playbackBuffer.format.channelCount))
                for c in 0..<channels {
                    let sc = min(c, srcChannels - 1)
                    dstCh[c][offset] = srcCh[sc][srcIndex]
                }
            }
        }

        playFramePosition = (playFramePosition + framesToCopy) % totalFrames
        tickCount += 1
        VoxaMicRingWriter.write(pcm: chunk, to: ring, logEveryNTicks: 200, tick: tickCount)
    }

    private static func loadAndConvert(url: URL, targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw FeedError.converterFailed
        }

        let estimatedOut = AVAudioFrameCount(
            Double(file.length) * targetFormat.sampleRate / file.processingFormat.sampleRate
        ) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOut) else {
            throw FeedError.bufferFailed
        }

        var error: NSError?
        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            let capacity = AVAudioFrameCount(file.length)
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            try? file.read(into: input)
            inputConsumed = true
            outStatus.pointee = .haveData
            return input
        }

        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error { throw error }

        if output.frameLength == 0 {
            throw FeedError.emptyAfterConvert
        }
        return output
    }

    enum FeedError: Error {
        case ringFormatUnavailable
        case converterFailed
        case bufferFailed
        case emptyAfterConvert
    }
}
