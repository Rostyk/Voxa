import Foundation

/// One committed line after a pause (treated like a chat message).
struct ConversationTurn: Identifiable, Hashable, Sendable {
    let id: UUID
    let speakerLabel: String
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), speakerLabel: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.text = text
        self.createdAt = createdAt
    }
}

/// Snapshot for UI + debugging; replace as a whole when updating.
struct ConversationState: Sendable {
    var history: [ConversationTurn]
    /// Current streaming line from Speech partial results (same “bubble” until pause).
    var liveTranscript: String
    /// Recent energy on converted tap audio (rough proxy for “someone talking”).
    var isSpeakerSpeaking: Bool
    /// No partial updates and low energy for a short window (derived in view model).
    var isSilent: Bool
    var speechAuthorized: Bool
    /// `Locale.identifier` for `SFSpeechRecognizer` (defaults to Mac locale in `ConversationViewModel.init`).
    var speechLocaleIdentifier: String
    var lastError: String?

    static let empty = ConversationState(
        history: [],
        liveTranscript: "",
        isSpeakerSpeaking: false,
        isSilent: true,
        speechAuthorized: false,
        speechLocaleIdentifier: Locale.current.identifier,
        lastError: nil
    )
}
