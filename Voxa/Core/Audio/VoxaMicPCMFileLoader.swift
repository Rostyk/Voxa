import AVFoundation
import Foundation

enum VoxaMicPCMFileLoader {
    /// Virtual mic ring: 48 kHz stereo interleaved int16 (see `VoxaMicRingLayout`).
    static let ringFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(VoxaMicRingLayout.sampleRate),
        channels: VoxaMicRingLayout.channelCount,
        interleaved: true
    )

    static func loadAndConvert(url: URL, targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        logFormat(url: url, source: source, target: targetFormat)

        if formatsMatch(source: source, target: targetFormat) {
            return try readEntireFile(file, format: source)
        }

        guard let converter = AVAudioConverter(from: source, to: targetFormat) else {
            throw Error.converterFailed
        }
        converter.sampleRateConverterQuality = .max
        converter.downmix = source.channelCount > targetFormat.channelCount

        let estimatedOut = AVAudioFrameCount(
            Double(file.length) * targetFormat.sampleRate / source.sampleRate
        ) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOut) else {
            throw Error.bufferFailed
        }

        var conversionError: NSError?
        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            let capacity = AVAudioFrameCount(file.length)
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            try? file.read(into: input)
            inputConsumed = true
            outStatus.pointee = .haveData
            return input
        }

        converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        if let conversionError { throw conversionError }
        if output.frameLength == 0 { throw Error.emptyAfterConvert }

        let outSeconds = Double(output.frameLength) / targetFormat.sampleRate
        print(
            "[VoxaMic] PCM convert \(url.lastPathComponent): \(output.frameLength) frames @ \(Int(targetFormat.sampleRate)) Hz \(targetFormat.channelCount)ch ≈\(String(format: "%.0f", outSeconds * 1000))ms"
        )
        return output
    }

    private static func logFormat(url: URL, source: AVAudioFormat, target: AVAudioFormat) {
        print(
            "[VoxaMic] PCM source \(url.lastPathComponent): \(Int(source.sampleRate)) Hz \(source.channelCount)ch \(source.commonFormat.rawValue) → ring \(Int(target.sampleRate)) Hz \(target.channelCount)ch interleaved"
        )
    }

    private static func formatsMatch(source: AVAudioFormat, target: AVAudioFormat) -> Bool {
        source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && source.commonFormat == target.commonFormat
            && source.isInterleaved == target.isInterleaved
    }

    private static func readEntireFile(_ file: AVAudioFile, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Error.bufferFailed
        }
        try file.read(into: buffer)
        return buffer
    }

    enum Error: Swift.Error {
        case ringFormatUnavailable
        case converterFailed
        case bufferFailed
        case emptyAfterConvert
    }
}
