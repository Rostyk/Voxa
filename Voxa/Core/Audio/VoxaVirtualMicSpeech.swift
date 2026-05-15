import AVFoundation
import Foundation

enum VoxaVirtualMicSpeechError: LocalizedError {
    case emptyText
    case synthesisFailed(String)
    case feederUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyText: return "Nothing to speak."
        case .synthesisFailed(let detail): return "Text-to-speech failed: \(detail)"
        case .feederUnavailable: return "Virtual mic is not available."
        }
    }
}

/// Speaks text into the virtual microphone — **single path** for every play/text call-goal action.
final class VoxaVirtualMicSpeech: @unchecked Sendable {
    static let shared = VoxaVirtualMicSpeech()

    private init() {}

    func speak(_ text: String, localeIdentifier: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoxaVirtualMicSpeechError.emptyText }

        let locale = localeIdentifier ?? ""
        try await VoxaVirtualMicPlaybackExecutor.run {
            VoxaVirtualMicFeeder.shared.startIfNeeded()
            let buffer = try self.synthesizeToRingBuffer(text: trimmed, localeIdentifier: locale)
            try await VoxaVirtualMicFeeder.shared.performRingInjection { ring in
                try VoxaMicRingPCMStreamer.streamBuffer(
                    buffer,
                    to: ring,
                    logLabel: "tts",
                    options: .virtualMicPlayback
                )
            }
        }
    }

    private func synthesizeToRingBuffer(text: String, localeIdentifier: String) throws -> AVAudioPCMBuffer {
        guard let ringFormat = VoxaMicPCMFileLoader.ringFormat else {
            throw VoxaMicPCMFileLoader.Error.ringFormatUnavailable
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxa-tts-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sayVoice = VoxaSayVoiceResolver.voiceArgument(forLocaleIdentifier: localeIdentifier)
        let args = ["-v", sayVoice, "-o", tmp.path, text]

        print("[VoxaMic] TTS say \(args.prefix(4).joined(separator: " ")) … chars=\(text.count)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = args

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw VoxaVirtualMicSpeechError.synthesisFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            throw VoxaVirtualMicSpeechError.synthesisFailed("say exited \(process.terminationStatus)")
        }

        if let file = try? AVAudioFile(forReading: tmp) {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            print(
                "[VoxaMic] TTS say output \(tmp.lastPathComponent): " +
                    "\(Int(file.processingFormat.sampleRate)) Hz \(file.processingFormat.channelCount)ch " +
                    "≈\(String(format: "%.0f", seconds * 1000))ms voice=\(sayVoice)"
            )
        }

        return try VoxaMicPCMFileLoader.loadAndConvert(url: tmp, targetFormat: ringFormat)
    }
}
