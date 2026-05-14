import Foundation

/// Live translation via Google Cloud Translation API v2. Does not use `callContextNotes` (not supported by the API).
final class GoogleTranslateCaptionService: LiveCaptionTranslationServicing, @unchecked Sendable {

    private let client: GoogleTranslateRestClienting

    init(client: GoogleTranslateRestClienting) {
        self.client = client
    }

    func translateLine(
        transcript: String,
        targetLocaleIdentifier: String,
        callContextNotes: String
    ) async throws -> CorrectionTranslationPayload {
        _ = callContextNotes
        let targetCode = Self.googleLanguageCode(from: targetLocaleIdentifier)
        let translated = try await client.translate(text: transcript, targetLanguageCode: targetCode)
        return CorrectionTranslationPayload(corrected: transcript, translation: translated)
    }

    /// Maps BCP-47 identifiers (e.g. `en_US`, `uk-UA`) to Google’s `target` language codes.
    static func googleLanguageCode(from localeIdentifier: String) -> String {
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        if let lang = Locale(identifier: normalized).language.languageCode?.identifier, !lang.isEmpty {
            return lang
        }
        let head = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return head.isEmpty ? "en" : head
    }
}
