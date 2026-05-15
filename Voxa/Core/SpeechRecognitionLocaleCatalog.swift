import Foundation
import Speech

/// Locales supported for dictation-style speech on this Mac (`SFSpeechRecognizer` pool). Shared by speech and translation pickers.
enum SpeechRecognitionLocaleCatalog {
    /// App default for the original-language (speech) picker — resolved against supported locales on this Mac.
    static let defaultPreferredIdentifier = "es-ES"

    static var defaultSpeechLocaleIdentifier: String {
        resolvedIdentifier(defaultPreferredIdentifier)
    }

    static func supportedIdentifiers() -> [String] {
        Array(SFSpeechRecognizer.supportedLocales()).map(\.identifier).sorted()
    }

    /// Picks a supported locale identifier closest to `preferred` (exact match, then same language code).
    static func resolvedIdentifier(_ preferred: String) -> String {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        if supported.contains(preferred) { return preferred }
        let pref = Locale(identifier: preferred)
        if let code = pref.language.languageCode?.identifier {
            let matches = supported.filter { Locale(identifier: $0).language.languageCode?.identifier == code }
                .sorted()
            if let first = matches.first { return first }
        }
        return supported.sorted().first ?? preferred
    }
}
