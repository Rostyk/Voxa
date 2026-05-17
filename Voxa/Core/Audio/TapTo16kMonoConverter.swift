import AVFoundation
import Foundation

/// Incrementally converts live tap `AVAudioPCMBuffer` chunks to 16 kHz mono Float32 using one reused `AVAudioConverter`.
/// Intended for real-time accumulation (bubble audio); amortizes resampling cost across the call instead of at commit.
final class TapTo16kMonoConverter: @unchecked Sendable {

    private static let outputFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }()

    private var converter: AVAudioConverter?
    private var converterInputSignature: String?

    /// Appends converted samples to `destination`. Returns `false` if conversion failed.
    @discardableResult
    func appendTapBuffer(_ source: AVAudioPCMBuffer, into destination: inout [Float]) -> Bool {
        guard source.frameLength > 0 else { return true }

        let src = source.format
        let signature = Self.formatSignature(src)
        if converterInputSignature != signature {
            converterInputSignature = signature
            converter = AVAudioConverter(from: src, to: Self.outputFormat)
        }
        guard let converter else { return false }

        let ratio = Self.outputFormat.sampleRate / src.sampleRate
        let outFrames = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: outFrames) else {
            return false
        }

        var err: NSError?
        var fedInput = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            fedInput = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error || err != nil {
            return false
        }

        guard let channelData = out.floatChannelData else { return false }
        let count = Int(out.frameLength)
        guard count > 0 else { return true }
        destination.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
        return true
    }

    func reset() {
        converter = nil
        converterInputSignature = nil
    }

    private static func formatSignature(_ format: AVAudioFormat) -> String {
        "\(format.commonFormat.rawValue)-\(format.sampleRate)-\(format.channelCount)-\(format.isInterleaved)"
    }
}
