import Foundation

enum GoogleTranslateConfiguration: Sendable {
    static let translateV2URL = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    /// API key from the process environment (Xcode Scheme → `GOOGLE_TRANSLATE_KEY`).
    static func apiKey() -> String? {
        if let raw = ProcessInfo.processInfo.environment["GOOGLE_TRANSLATE_KEY"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
