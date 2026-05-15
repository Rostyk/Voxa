import AVFoundation
import Foundation

/// Resolves a macOS `say -v` argument for a BCP-47 locale (used by all virtual-mic TTS / play actions).
enum VoxaSayVoiceResolver {
    /// `say -v` voice id (e.g. `com.apple.voice.compact.es-ES.Monica`). Works for any locale AVSpeech supports.
    static func voiceArgument(forLocaleIdentifier localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if let voice = speechVoice(for: trimmed) {
            print(
                "[VoxaMic] say voice locale=\(trimmed) → \"\(voice.identifier)\" " +
                    "(\(voice.name), \(voice.language))"
            )
            return voice.identifier
        }

        let fallback = defaultVoice.identifier
        print("[VoxaMic] say voice locale=\(trimmed.isEmpty ? "(empty)" : trimmed) → default \"\(fallback)\"")
        return fallback
    }

    private static func speechVoice(for localeIdentifier: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: localeIdentifier) {
            return exact
        }

        let hyphen = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        if hyphen != localeIdentifier, let voice = AVSpeechSynthesisVoice(language: hyphen) {
            return voice
        }

        let underscore = localeIdentifier.replacingOccurrences(of: "-", with: "_")
        if underscore != localeIdentifier, let voice = AVSpeechSynthesisVoice(language: underscore.replacingOccurrences(of: "_", with: "-")) {
            return voice
        }

        let languagePrefix = localeIdentifier.prefix(2).lowercased()
        guard languagePrefix.count == 2 else { return nil }

        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            voice.language.lowercased().hasPrefix(String(languagePrefix))
        }
    }

    private static var defaultVoice: AVSpeechSynthesisVoice {
        AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first
            ?? AVSpeechSynthesisVoice()
    }
}
