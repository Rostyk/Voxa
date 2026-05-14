import Foundation
import Observation

/// Live translation: **no time debounce** — each eligible partial cancels the previous in-flight request.
/// Published `liveCorrected` / `liveTranslation` update the UI; keep translation in a **separate**
/// SwiftUI subtree (see `LiveTranslationPanel`) so STT line layout does not invalidate with every response.
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
    @ObservationIgnored private var lateCaptionAnchor: (turnID: UUID, committedTranscript: String)?
    @ObservationIgnored private var translateLogTask: Task<Void, Never>?

    var onSupersededTranslation: ((_ turnID: UUID, _ transcript: String, _ corrected: String, _ translation: String) -> Void)?

    init() {
        print("[Caption] CaptionTranslationViewModel init engine=\(_translationEngine.rawValue) (no debounce; UI isolated in transcript view)")
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

    /// Immediate translate attempt on each partial (cancels only the previous in-flight log request — no time debounce).
    func onLiveTranscriptChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            translateLogTask?.cancel()
            translateLogTask = nil
            lateCaptionAnchor = nil
            latestRequestID &+= 1
            clearLiveOutputs()
            print("[Caption] live transcript cleared — translation log idle")
            return
        }
        if trimmed.count < 4 {
            return
        }

        translateLogTask?.cancel()
        latestRequestID &+= 1
        let requestID = latestRequestID
        isTranslating = true
        translateLogTask = Task { [weak self] in
            await self?.runTranslationRequest(requestID: requestID, text: trimmed)
        }
    }

    func onSegmentCommitted(lateCaptionTurnID: UUID, committedTranscript: String) {
        let key = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        lateCaptionAnchor = (lateCaptionTurnID, key)
        print("[Caption] segment committed — cancel in-flight log translate anchor turn=\(lateCaptionTurnID)")
        translateLogTask?.cancel()
        translateLogTask = nil
        invalidateInFlightRequests()
        clearLiveOutputs()
    }

    func onStoppedListening() {
        print("[Caption] stopped listening — cancel in-flight log translate")
        lateCaptionAnchor = nil
        translateLogTask?.cancel()
        translateLogTask = nil
        invalidateInFlightRequests()
        clearLiveOutputs()
    }

    private func clearLiveOutputs() {
        liveCorrected = ""
        liveTranslation = ""
        isTranslating = false
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

    private func runTranslationRequest(requestID: UInt64, text: String) async {
        guard let service = activeTranslationService() else {
            refreshEngineAvailabilityMessage()
            let msg = translationLastError ?? "Translation backend is not configured for \(translationEngine.displayName)."
            print("[Caption] translate skipped — \(msg)")
            isTranslating = false
            return
        }

        let targetLabel =
            Locale.current.localizedString(forIdentifier: translationLocaleIdentifier)
            ?? translationLocaleIdentifier

        print(
            "[Caption] translate start id=\(requestID) engine=\(translationEngine.rawValue) target=\"\(targetLabel)\" chars=\(text.count) preview=\"\(Self.logPreview(text))\""
        )

        if translationEngine == .gpt {
            print("[GPT] invoking chat/completions id=\(requestID)")
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        do {
            let payload = try await service.translateLine(
                transcript: text,
                targetLocaleIdentifier: translationLocaleIdentifier,
                callContextNotes: callContextNotes
            )
            let wall = CFAbsoluteTimeGetCurrent() - wallStart

            if requestID != latestRequestID {
                print(
                    "[Caption] translate STALE id=\(requestID) latest=\(latestRequestID) wall=\(String(format: "%.3f", wall))s corrected=\"\(Self.oneLine(payload.corrected))\" translation=\"\(Self.oneLine(payload.translation))\""
                )
                if let anchor = lateCaptionAnchor,
                    TranscriptTurnMatch.likelySameTurn(committed: anchor.committedTranscript, inflight: text) {
                    onSupersededTranslation?(anchor.turnID, text, payload.corrected, payload.translation)
                } else if lateCaptionAnchor != nil {
                    print("[Caption] translate STALE — superseded merge skipped (committed vs inflight pairing rejected)")
                }
                return
            }

            liveCorrected = payload.corrected
            liveTranslation = payload.translation
            translationLastError = nil
            isTranslating = false
            print(
                "[Caption] translate RESULT id=\(requestID) engine=\(translationEngine.rawValue) wall=\(String(format: "%.3f", wall))s transcript=\"\(Self.logPreview(text))\" corrected=\"\(Self.oneLine(payload.corrected))\" translation=\"\(Self.oneLine(payload.translation))\""
            )
        } catch is CancellationError {
            // A newer partial bumps `latestRequestID` before cancelling this task; do not clear
            // `isTranslating` here or we would stomp the in-flight successor.
            if requestID == latestRequestID {
                isTranslating = false
            }
            print("[Caption] translate cancelled id=\(requestID)")
        } catch {
            if requestID == latestRequestID {
                translationLastError = error.localizedDescription
                isTranslating = false
            }
            print(
                "[Caption] translate ERROR id=\(requestID) wall=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - wallStart))s \(error.localizedDescription)"
            )
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
