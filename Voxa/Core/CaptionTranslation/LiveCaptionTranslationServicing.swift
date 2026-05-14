import Foundation

/// Pluggable live translation (and optional correction) for one transcript line.
protocol LiveCaptionTranslationServicing: Sendable {
    /// `callContextNotes` may be ignored by backends that do not support it (e.g. Google Cloud Translation).
    func translateLine(
        transcript: String,
        targetLocaleIdentifier: String,
        callContextNotes: String
    ) async throws -> CorrectionTranslationPayload
}
