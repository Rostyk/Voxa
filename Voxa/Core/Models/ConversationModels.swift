import Foundation

/// One committed line after a pause (treated like a chat message).
struct ConversationTurn: Identifiable, Hashable, Sendable {
    let id: UUID
    let speakerLabel: String
    /// Raw committed transcript from Apple speech recognition.
    let text: String
    /// Accurate offline re-transcription of this bubble’s audio (FluidAudio / Parakeet), when enabled.
    let fluidAudioText: String?
    /// Waiting for FluidAudio before sending text to translation.
    let isAwaitingFluidAudio: Bool
    /// GPT “corrected” line at commit time (same language as transcript), if any.
    let gptCorrected: String?
    /// GPT translation at commit time (or filled in shortly after if the request finished late).
    let gptTranslation: String?
    /// Suggested next steps toward the call goal (ChatGPT path only).
    let gptActions: [CallGoalAction]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        speakerLabel: String,
        text: String,
        fluidAudioText: String? = nil,
        isAwaitingFluidAudio: Bool = false,
        gptCorrected: String? = nil,
        gptTranslation: String? = nil,
        gptActions: [CallGoalAction] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.text = text
        self.fluidAudioText = fluidAudioText
        self.isAwaitingFluidAudio = isAwaitingFluidAudio
        self.gptCorrected = gptCorrected
        self.gptTranslation = gptTranslation
        self.gptActions = gptActions
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
    /// `Locale.identifier` for `SFSpeechRecognizer` (defaults to Spanish in `SpeechRecognitionLocaleCatalog`).
    var speechLocaleIdentifier: String
    var lastError: String?

    static let empty = ConversationState(
        history: [],
        liveTranscript: "",
        isSpeakerSpeaking: false,
        isSilent: true,
        speechAuthorized: false,
        speechLocaleIdentifier: SpeechRecognitionLocaleCatalog.defaultSpeechLocaleIdentifier,
        lastError: nil
    )
}
