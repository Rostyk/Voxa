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

/// Speaks text into the virtual microphone — single path for every play/text call-goal action.
enum VoxaVirtualMicSpeech {
    /// Must run on `VoxaVirtualMicPlaybackExecutor.queue` only.
    static func speakOnPlaybackQueue(text: String, localeIdentifier: String) throws {
        VoxaVirtualMicPlaybackExecutor.assertNotOnMainThread("speakOnPlaybackQueue")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoxaVirtualMicSpeechError.emptyText }

        VoxaVirtualMicFeeder.shared.startIfNeeded()
        let buffer = try synthesizeToRingBuffer(text: trimmed, localeIdentifier: localeIdentifier)
        try VoxaVirtualMicFeeder.shared.performRingInjectionSync { ring in
            try VoxaMicRingPCMStreamer.streamBuffer(
                buffer,
                to: ring,
                logLabel: "tts",
                options: .virtualMicPlayback
            )
        }
    }

    /// Enqueues TTS on the playback queue; returns immediately (UI thread safe).
    static func enqueueSpeak(text: String, localeIdentifier: String, onComplete: @escaping @Sendable (Error?) -> Void) {
        VoxaVirtualMicPlaybackExecutor.dispatch {
            do {
                try speakOnPlaybackQueue(text: text, localeIdentifier: localeIdentifier)
                DispatchQueue.main.async { onComplete(nil) }
            } catch {
                DispatchQueue.main.async { onComplete(error) }
            }
        }
    }

    private static func synthesizeToRingBuffer(text: String, localeIdentifier: String) throws -> AVAudioPCMBuffer {
        VoxaVirtualMicPlaybackExecutor.assertNotOnMainThread("synthesizeToRingBuffer")

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
