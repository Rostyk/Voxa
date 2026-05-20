import Foundation
import Observation

/// Translation runs **once per committed speech segment** (after the recognizer finalizes a bubble).
/// No mid‑partial translation — avoids racing GPT against growing STT and wrong / truncated bubbles.
@MainActor
@Observable
final class CaptionTranslationViewModel {

    /// What the caller wants to achieve on this call — used by the **ChatGPT** path only.
    var callGoal: String = ""

    /// Target locale for translation (same identifier pool as speech recognition).
    var translationLocaleIdentifier: String {
        get { _translationLocaleIdentifier }
        set { applyTranslationLocaleIdentifier(newValue) }
    }

    /// When enabled, translation uses FluidAudio’s bubble re-transcription instead of Apple’s committed line.
    var correctUsingFluidAudio: Bool = true

    /// When enabled (and Fluid STT is on), run speaker diarization (live probes + timeline on commit). Off by default.
    var diarizeSpeakersOnCommit: Bool = false

    /// Default is **ChatGPT** (correction + translation + call-goal actions in one call).
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
    @ObservationIgnored private var _translationEngine: LiveCaptionTranslationEngine = .gpt

    @ObservationIgnored private let gptCaptionService: GPTCaptionTranslationService?
    @ObservationIgnored private let googleCaptionService: GoogleTranslateCaptionService?

    @ObservationIgnored private var latestRequestID: UInt64 = 0
    /// Bumped when the conversation is cleared so late HTTP replies never touch a new call.
    @ObservationIgnored private var translationSessionGeneration: UInt64 = 0
    @ObservationIgnored private var commitTranslationInFlightCount: Int = 0

    var onSupersededTranslation: (
        (_ turnID: UUID, _ transcript: String, _ corrected: String, _ translation: String, _ actions: [CallGoalAction]) -> Void
    )?

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

        guard let service = activeTranslationService() else {
            refreshEngineAvailabilityMessage()
            let msg = translationLastError ?? "Translation backend is not configured for \(translationEngine.displayName)."
            print("[Caption] translate commit skipped — \(msg)")
            return
        }

        commitTranslationInFlightCount += 1
        isTranslating = true

        let engine = translationEngine
        let locale = translationLocaleIdentifier
        let goal = callGoal
        let targetLabel =
            Locale.current.localizedString(forIdentifier: locale) ?? locale

        Task.detached(priority: .userInitiated) { [weak self] in
            await CaptionTranslationViewModel.runCommitTranslationOffMain(
                service: service,
                engine: engine,
                requestID: requestID,
                turnID: lateCaptionTurnID,
                text: key,
                targetLabel: targetLabel,
                localeIdentifier: locale,
                callGoal: goal,
                sessionGenerationAtStart: sessionGen,
                deliver: { result in
                    await self?.finishCommitTranslationOnMain(
                        requestID: requestID,
                        turnID: lateCaptionTurnID,
                        transcript: key,
                        sessionGenerationAtStart: sessionGen,
                        result: result
                    )
                }
            )
        }
    }

    func translationSessionGenerationSnapshot() -> UInt64 {
        translationSessionGeneration
    }

    func onStoppedListening(preserveCommittedTranslations: Bool = false) {
        if preserveCommittedTranslations {
            print("[Caption] stopped listening — preserve committed translations for history")
        } else {
            print("[Caption] stopped listening — bump translation session")
            translationSessionGeneration &+= 1
            latestRequestID &+= 1
        }
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

    private enum CommitTranslationResult: Sendable {
        case success(CorrectionTranslationPayload)
        case failure(String)
        case cancelled
    }

    /// Network + decode off the main actor (same pattern as virtual-mic playback).
    private static func runCommitTranslationOffMain(
        service: LiveCaptionTranslationServicing,
        engine: LiveCaptionTranslationEngine,
        requestID: UInt64,
        turnID: UUID,
        text: String,
        targetLabel: String,
        localeIdentifier: String,
        callGoal: String,
        sessionGenerationAtStart: UInt64,
        deliver: @escaping @Sendable (CommitTranslationResult) async -> Void
    ) async {
        print(
            "[Caption] translate commit start (background) id=\(requestID) turn=\(turnID) engine=\(engine.rawValue) target=\"\(targetLabel)\" chars=\(text.count) preview=\"\(logPreview(text))\""
        )

        if engine == .gpt {
            let goalPreview = logPreview(callGoal, maxLen: 120)
            print("[GPT] invoking chat/completions commit id=\(requestID) callGoalChars=\(callGoal.count) goalPreview=\(goalPreview)")
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        do {
            let payload = try await service.translateLine(
                transcript: text,
                targetLocaleIdentifier: localeIdentifier,
                callContextNotes: callGoal
            )
            let wall = CFAbsoluteTimeGetCurrent() - wallStart
            print(
                "[Caption] translate commit RESULT (background) id=\(requestID) wall=\(String(format: "%.3f", wall))s correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count) sessionGen=\(sessionGenerationAtStart)"
            )
            await deliver(.success(payload))
        } catch is CancellationError {
            print("[Caption] translate commit cancelled id=\(requestID)")
            await deliver(.cancelled)
        } catch {
            print(
                "[Caption] translate commit ERROR (background) id=\(requestID) wall=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - wallStart))s \(error.localizedDescription)"
            )
            await deliver(.failure(error.localizedDescription))
        }
    }

    private func finishCommitTranslationOnMain(
        requestID: UInt64,
        turnID: UUID,
        transcript: String,
        sessionGenerationAtStart: UInt64,
        result: CommitTranslationResult
    ) async {
        defer {
            commitTranslationInFlightCount -= 1
            if commitTranslationInFlightCount <= 0 {
                commitTranslationInFlightCount = 0
                isTranslating = false
            }
        }

        switch result {
        case .cancelled:
            return
        case .failure(let message):
            if requestID == latestRequestID {
                translationLastError = message
            }
            return
        case .success(let payload):
            if requestID != latestRequestID {
                print(
                    "[Caption] translate commit STALE id=\(requestID) latest=\(latestRequestID) — still merging into turn \(turnID)"
                )
            }

            guard sessionGenerationAtStart == translationSessionGeneration else {
                print("[Caption] translate commit discarded — session generation changed (cleared or stopped)")
                return
            }

            print(
                "[Caption] translate commit delivering merge turn=\(turnID) correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count) actions=\(payload.actions.count)"
            )
            CallGoalActionLog.logList(payload.actions, context: "delivering to ConversationViewModel turn=\(turnID)")
            onSupersededTranslation?(turnID, transcript, payload.corrected, payload.translation, payload.actions)
            if requestID == latestRequestID {
                translationLastError = nil
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
