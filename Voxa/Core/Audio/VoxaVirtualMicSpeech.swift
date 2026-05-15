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

/// Speaks text into the virtual microphone (one-shot TTS, same ring path as DTMF).
final class VoxaVirtualMicSpeech: @unchecked Sendable {
    static let shared = VoxaVirtualMicSpeech()

    private init() {}

    func speak(_ text: String, localeIdentifier: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoxaVirtualMicSpeechError.emptyText }

        VoxaVirtualMicFeeder.shared.startIfNeeded()
        let buffer = try synthesizeToRingBuffer(text: trimmed, localeIdentifier: localeIdentifier)
        try await VoxaVirtualMicFeeder.shared.performRingInjection { ring in
            try VoxaMicRingPCMStreamer.streamBuffer(buffer, to: ring)
        }
    }

    private func synthesizeToRingBuffer(text: String, localeIdentifier: String?) throws -> AVAudioPCMBuffer {
        guard let ringFormat = VoxaMicPCMFileLoader.ringFormat else {
            throw VoxaMicPCMFileLoader.Error.ringFormatUnavailable
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxa-tts-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-o", tmp.path]
        if let localeIdentifier, !localeIdentifier.isEmpty {
            args.insert(contentsOf: ["-v", voiceName(for: localeIdentifier)], at: 0)
        }
        args.append(text)
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

        return try VoxaMicPCMFileLoader.loadAndConvert(url: tmp, targetFormat: ringFormat)
    }

    private func voiceName(for localeIdentifier: String) -> String {
        if let voice = AVSpeechSynthesisVoice(language: localeIdentifier) {
            return voice.name
        }
        return localeIdentifier
    }
}
