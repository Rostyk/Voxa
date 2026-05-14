import Foundation
import Observation

/// Translation runs **once per committed speech segment** (after the recognizer finalizes a bubble).
/// No mid‑partial translation — avoids racing GPT against growing STT and wrong / truncated bubbles.
@MainActor
@Observable
final class CaptionTranslationViewModel {

    /// Free-form notes about the call (topic, participants, jargon) — used by the **ChatGPT** path only.
    var callContextNotes: String = ""

    /// Target locale for translation (same identifier pool as speech recognition).
    var translationLocaleIdentifier: String {
        get { _translationLocaleIdentifier }
        set { applyTranslationLocaleIdentifier(newValue) }
    }

    /// Default is **Google Translate**; switch to **ChatGPT** for correction + translation in one model call.
    var translationEngine: LiveCaptionTranslationEngine {
        get { _translationEngine }
        set {
            guard newValue != _translationEngine else { return }
            _translationEngine = newValue
            refreshEngineAvailabilityMessage()
        }
    }

    var liveCorrected: String = ""
    var liveTranslation: String = ""

    var isTranslating: Bool = false
    var translationLastError: String?

    @ObservationIgnored private var _translationLocaleIdentifier: String
    @ObservationIgnored private var _translationEngine: LiveCaptionTranslationEngine = .googleTranslate

    @ObservationIgnored private let gptCaptionService: GPTCaptionTranslationService?
    @ObservationIgnored private let googleCaptionService: GoogleTranslateCaptionService?

    @ObservationIgnored private var latestRequestID: UInt64 = 0
    /// Bumped when the conversation is cleared or recording stops so late HTTP replies never touch history.
    @ObservationIgnored private var translationSessionGeneration: UInt64 = 0
    @ObservationIgnored private var commitTranslationInFlightCount: Int = 0

    var onSupersededTranslation: ((_ turnID: UUID, _ transcript: String, _ corrected: String, _ translation: String) -> Void)?

    init() {
        print("[Caption] CaptionTranslationViewModel init engine=\(_translationEngine.rawValue) (translate on segment commit only)")
        print(
            "[GPT] chat caption model=\(OpenAIConfiguration.chatCaptionModel()) max_completion_tokens=\(OpenAIConfiguration.chatCaptionMaxCompletionTokens) reasoning_effort=\(OpenAIConfiguration.chatCaptionReasoningEffort() ?? "(none)") (env GPT_MODEL / GPT_REASONING_EFFORT; used when engine=ChatGPT)"
        )
        _translationLocaleIdentifier = Self.resolvedTranslationLocaleIdentifier(Locale.current.identifier)

        if let openAIKey = OpenAIConfiguration.apiKey() {
            print("[Caption] OpenAI API key present length=\(openAIKey.count) (OPEN_AI_KEY or OPENAI_API_KEY) — ChatGPT path available")
            gptCaptionService = GPTCaptionTranslationService(client: OpenAIRestClient(apiKey: openAIKey))
        } else {
            print("[Caption] OpenAI key missing — ChatGPT path disabled (set OPEN_AI_KEY or OPENAI_API_KEY in the Run scheme or shell environment; xcconfig alone is not enough)")
            gptCaptionService = nil
        }

        if let googleKey = GoogleTranslateConfiguration.apiKey() {
            print("[Caption] GOOGLE_TRANSLATE_KEY present length=\(googleKey.count) — Google path available")
            googleCaptionService = GoogleTranslateCaptionService(client: GoogleTranslateRestClient(apiKey: googleKey))
        } else {
            print("[Caption] GOOGLE_TRANSLATE_KEY missing — Google path disabled")
            googleCaptionService = nil
        }

        refreshEngineAvailabilityMessage()
    }

    private func refreshEngineAvailabilityMessage() {
        switch translationEngine {
        case .gpt:
            translationLastError =
                gptCaptionService == nil
                ? "Set OPEN_AI_KEY or OPENAI_API_KEY in the Run scheme (or export before launch) for ChatGPT translation."
                : nil
        case .googleTranslate:
            translationLastError =
                googleCaptionService == nil
                ? "Set GOOGLE_TRANSLATE_KEY in the run scheme (Google Cloud Console → enable Cloud Translation API → Credentials)."
                : nil
        }
    }

    static func supportedTranslationLocaleIdentifiers() -> [String] {
        SpeechRecognitionLocaleCatalog.supportedIdentifiers()
    }

    static func resolvedTranslationLocaleIdentifier(_ preferred: String) -> String {
        SpeechRecognitionLocaleCatalog.resolvedIdentifier(preferred)
    }

    private func applyTranslationLocaleIdentifier(_ raw: String) {
        let resolved = Self.resolvedTranslationLocaleIdentifier(raw)
        guard resolved != _translationLocaleIdentifier else { return }
        print("[Caption] translation target locale \(resolved) (was \(_translationLocaleIdentifier))")
        _translationLocaleIdentifier = resolved
    }

    /// Live STT partials do **not** trigger translation (waits for `onSegmentCommitted` after each bubble).
    /// **Important:** empty partials are common right after a segment commit (silence between phrases). They must **not**
    /// bump the translation session — that would discard in-flight commit translations before they can merge.
    func onLiveTranscriptChanged(_ text: String) {}

    /// Call when the user clears the transcript list — invalidates in-flight commit translations for the old session.
    func onConversationCleared() {
        translationSessionGeneration &+= 1
        latestRequestID &+= 1
        clearLiveOutputs()
        translationLastError = nil
        print("[Caption] conversation cleared — translation session bumped=\(translationSessionGeneration)")
    }

    /// One translation request per finalized segment; merges into that bubble when the model returns (even if a newer segment already started).
    func onSegmentCommitted(lateCaptionTurnID: UUID, committedTranscript: String) {
        let key = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 4 else {
            print("[Caption] segment committed — skip translate (segment too short chars=\(key.count))")
            clearLiveOutputs()
            return
        }

        invalidateInFlightRequests()
        let requestID = latestRequestID
        let sessionGen = translationSessionGeneration

        print(
            "[Caption] segment committed — translate once turn=\(lateCaptionTurnID) chars=\(key.count) requestID=\(requestID) sessionGen=\(sessionGen)"
        )

        commitTranslationInFlightCount += 1
        isTranslating = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.commitTranslationInFlightCount -= 1
                if self.commitTranslationInFlightCount <= 0 {
                    self.commitTranslationInFlightCount = 0
                    self.isTranslating = false
                }
            }
            await self.runCommitTranslation(
                requestID: requestID,
                turnID: lateCaptionTurnID,
                text: key,
                sessionGenerationAtStart: sessionGen
            )
        }
    }

    func onStoppedListening() {
        print("[Caption] stopped listening — bump translation session")
        translationSessionGeneration &+= 1
        latestRequestID &+= 1
        clearLiveOutputs()
    }

    private func clearLiveOutputs() {
        liveCorrected = ""
        liveTranslation = ""
    }

    private func invalidateInFlightRequests() {
        latestRequestID &+= 1
        print("[Caption] bumped request generation latestRequestID=\(latestRequestID)")
    }

    private func activeTranslationService() -> LiveCaptionTranslationServicing? {
        switch translationEngine {
        case .gpt: return gptCaptionService
        case .googleTranslate: return googleCaptionService
        }
    }

    private func runCommitTranslation(
        requestID: UInt64,
        turnID: UUID,
        text: String,
        sessionGenerationAtStart: UInt64
    ) async {
        guard let service = activeTranslationService() else {
            refreshEngineAvailabilityMessage()
            let msg = translationLastError ?? "Translation backend is not configured for \(translationEngine.displayName)."
            print("[Caption] translate commit skipped — \(msg)")
            return
        }

        let targetLabel =
            Locale.current.localizedString(forIdentifier: translationLocaleIdentifier)
            ?? translationLocaleIdentifier

        print(
            "[Caption] translate commit start id=\(requestID) turn=\(turnID) engine=\(translationEngine.rawValue) target=\"\(targetLabel)\" chars=\(text.count) preview=\"\(Self.logPreview(text))\""
        )

        if translationEngine == .gpt {
            print("[GPT] invoking chat/completions commit id=\(requestID)")
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        do {
            let payload = try await service.translateLine(
                transcript: text,
                targetLocaleIdentifier: translationLocaleIdentifier,
                callContextNotes: callContextNotes
            )
            let wall = CFAbsoluteTimeGetCurrent() - wallStart

            let staleRequest = requestID != latestRequestID
            if staleRequest {
                print(
                    "[Caption] translate commit STALE id=\(requestID) latest=\(latestRequestID) wall=\(String(format: "%.3f", wall))s — still merging into turn \(turnID)"
                )
            } else {
                print(
                    "[Caption] translate commit RESULT id=\(requestID) wall=\(String(format: "%.3f", wall))s correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count)"
                )
            }

            guard sessionGenerationAtStart == translationSessionGeneration else {
                print("[Caption] translate commit discarded — session generation changed (cleared or stopped)")
                return
            }

            print(
                "[Caption] translate commit delivering merge turn=\(turnID) correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count)"
            )
            onSupersededTranslation?(turnID, text, payload.corrected, payload.translation)
            if requestID == latestRequestID {
                translationLastError = nil
            }
        } catch is CancellationError {
            print("[Caption] translate commit cancelled id=\(requestID)")
        } catch {
            print(
                "[Caption] translate commit ERROR id=\(requestID) wall=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - wallStart))s \(error.localizedDescription)"
            )
            if requestID == latestRequestID {
                translationLastError = error.localizedDescription
            }
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func logPreview(_ text: String, maxLen: Int = 72) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= maxLen { return String(oneLine) }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: maxLen)
        return String(oneLine[..<idx]) + "…"
    }
}
