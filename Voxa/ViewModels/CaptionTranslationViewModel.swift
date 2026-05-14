import Foundation
import Observation

/// Owns live caption correction + translation for the current partial line. Backend is selected by ``translationEngine``.
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

    /// Latest model outputs for the current live segment.
    var liveCorrected: String = ""
    var liveTranslation: String = ""

    var isTranslating: Bool = false
    var translationLastError: String?

    @ObservationIgnored private var _translationLocaleIdentifier: String
    @ObservationIgnored private var _translationEngine: LiveCaptionTranslationEngine = .googleTranslate

    @ObservationIgnored private let gptCaptionService: GPTCaptionTranslationService?
    @ObservationIgnored private let googleCaptionService: GoogleTranslateCaptionService?

    /// Latest STT text we may send to the translator (updated on every partial).
    @ObservationIgnored private var latestTranscriptForGPT: String = ""
    @ObservationIgnored private var lastPartialAt: Date?
    @ObservationIgnored private var lastGPTFlushCompletedAt: Date?
    @ObservationIgnored private var debouncerBurstStartedAt: Date?
    @ObservationIgnored private var debounceLoopTask: Task<Void, Never>?
    @ObservationIgnored private var latestRequestID: UInt64 = 0
    @ObservationIgnored private var lateCaptionAnchor: (turnID: UUID, committedTranscript: String)?

    var onSupersededTranslation: ((_ turnID: UUID, _ transcript: String, _ corrected: String, _ translation: String) -> Void)?

    private static let quietDebounceSeconds: TimeInterval = 1.3
    private static let maxFlushIntervalSeconds: TimeInterval = 4.0
    private static let debouncePollMillis: UInt64 = 200

    init() {
        print("[Caption] CaptionTranslationViewModel init engine=\(_translationEngine.rawValue)")
        print(
            "[GPT] chat caption model=\(OpenAIConfiguration.chatCaptionModel()) max_completion_tokens=\(OpenAIConfiguration.chatCaptionMaxCompletionTokens) reasoning_effort=\(OpenAIConfiguration.chatCaptionReasoningEffort() ?? "(none)") (env GPT_MODEL / GPT_REASONING_EFFORT; used when engine=ChatGPT)"
        )
        _translationLocaleIdentifier = Self.resolvedTranslationLocaleIdentifier(Locale.current.identifier)

        if let openAIKey = OpenAIConfiguration.apiKey() {
            print("[Caption] OPEN_AI_KEY present length=\(openAIKey.count) — ChatGPT path available")
            gptCaptionService = GPTCaptionTranslationService(client: OpenAIRestClient(apiKey: openAIKey))
        } else {
            print("[Caption] OpenAI key missing — ChatGPT path disabled")
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
                ? "Set OPEN_AI_KEY in the run scheme for ChatGPT translation (platform.openai.com/api-keys)."
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

    /// Debounced: follows streaming partials from speech.
    func onLiveTranscriptChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            print("[Caption] live transcript cleared — stopping debouncer, clearing outputs")
            lateCaptionAnchor = nil
            stopDebouncerLoop()
            lastPartialAt = nil
            lastGPTFlushCompletedAt = nil
            latestTranscriptForGPT = ""
            debouncerBurstStartedAt = nil
            clearLiveOutputs()
            return
        }
        if trimmed.count < 4 {
            print("[Caption] transcript too short (<4 chars) — not scheduling translation")
            return
        }

        latestTranscriptForGPT = trimmed
        lastPartialAt = Date()

        if debounceLoopTask == nil {
            debouncerBurstStartedAt = Date()
            print(
                "[Caption] debouncer started — flush after \(Self.quietDebounceSeconds)s quiet, or every \(Self.maxFlushIntervalSeconds)s while partials stream; engine=\(translationEngine.rawValue) chars=\(trimmed.count) preview=\"\(Self.logPreview(trimmed))\""
            )
            debounceLoopTask = Task { @MainActor [weak self] in
                await self?.runDebouncerLoop()
            }
        }
    }

    func onSegmentCommitted(lateCaptionTurnID: UUID, committedTranscript: String) {
        let key = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        lateCaptionAnchor = (lateCaptionTurnID, key)
        print("[Caption] segment committed — invalidate in-flight, clear live outputs anchor turn=\(lateCaptionTurnID)")
        stopDebouncerLoop()
        lastPartialAt = nil
        lastGPTFlushCompletedAt = nil
        latestTranscriptForGPT = ""
        debouncerBurstStartedAt = nil
        invalidateInFlightRequests()
        clearLiveOutputs()
    }

    func onStoppedListening() {
        print("[Caption] stopped listening — invalidate in-flight, clear live outputs")
        lateCaptionAnchor = nil
        stopDebouncerLoop()
        lastPartialAt = nil
        lastGPTFlushCompletedAt = nil
        latestTranscriptForGPT = ""
        debouncerBurstStartedAt = nil
        invalidateInFlightRequests()
        clearLiveOutputs()
    }

    private func stopDebouncerLoop() {
        debounceLoopTask?.cancel()
        debounceLoopTask = nil
    }

    private func runDebouncerLoop() async {
        defer {
            debounceLoopTask = nil
            print("[Caption] debouncer loop ended")
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.debouncePollMillis * 1_000_000)
            if Task.isCancelled { break }
            guard let last = lastPartialAt else { return }

            let quietAge = Date().timeIntervalSince(last)
            let quietOK = quietAge >= Self.quietDebounceSeconds

            var maxIntervalOK = false
            if let flushedAt = lastGPTFlushCompletedAt {
                maxIntervalOK = Date().timeIntervalSince(flushedAt) >= Self.maxFlushIntervalSeconds
            }

            let burstAge = debouncerBurstStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let firstBurstMaxOK =
                lastGPTFlushCompletedAt == nil && burstAge >= Self.maxFlushIntervalSeconds

            if quietOK {
                print(
                    "[Caption] debouncer: \(Int(quietAge * 1000))ms quiet — flushing translation (engine=\(translationEngine.rawValue))"
                )
            } else if lastGPTFlushCompletedAt != nil, maxIntervalOK {
                print(
                    "[Caption] debouncer: max interval \(Int(Self.maxFlushIntervalSeconds))s since last flush while partials stream — flushing"
                )
            } else if firstBurstMaxOK {
                print(
                    "[Caption] debouncer: max interval \(Int(Self.maxFlushIntervalSeconds))s since debouncer start (no flush yet) — flushing"
                )
            } else {
                continue
            }

            let text = latestTranscriptForGPT
            guard text.count >= 4 else { return }

            await runRequest(for: text)
            lastGPTFlushCompletedAt = Date()
            lastPartialAt = nil
            return
        }
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

    private func runRequest(for text: String) async {
        guard let service = activeTranslationService() else {
            refreshEngineAvailabilityMessage()
            let msg = translationLastError ?? "Translation backend is not configured for \(translationEngine.displayName)."
            print("[Caption] runRequest aborted — \(msg)")
            isTranslating = false
            return
        }

        latestRequestID &+= 1
        let requestID = latestRequestID
        isTranslating = true
        translationLastError = nil

        let targetLabel =
            Locale.current.localizedString(forIdentifier: translationLocaleIdentifier)
            ?? translationLocaleIdentifier

        print(
            "[Caption] runRequest start id=\(requestID) engine=\(translationEngine.rawValue) target=\"\(targetLabel)\" contextChars=\(callContextNotes.count) transcriptChars=\(text.count) preview=\"\(Self.logPreview(text))\""
        )

        if translationEngine == .gpt {
            print("[GPT] invoking chat/completions id=\(requestID)")
        }

        let runWallStart = CFAbsoluteTimeGetCurrent()
        do {
            let payload = try await service.translateLine(
                transcript: text,
                targetLocaleIdentifier: translationLocaleIdentifier,
                callContextNotes: callContextNotes
            )
            guard requestID == latestRequestID else {
                print(
                    "[Caption] runRequest id=\(requestID) dropped stale (latest=\(latestRequestID)) — parent may merge into committed bubble"
                )
                if let anchor = lateCaptionAnchor,
                    Self.transcriptsLikelySameTurn(anchor.committedTranscript, text) {
                    onSupersededTranslation?(anchor.turnID, text, payload.corrected, payload.translation)
                }
                return
            }
            liveCorrected = payload.corrected
            liveTranslation = payload.translation
            translationLastError = nil
            isTranslating = false
            print(
                "[Caption] runRequest success id=\(requestID) correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count) wallTotal=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - runWallStart))s"
            )
        } catch {
            guard requestID == latestRequestID else {
                print(
                    "[Caption] runRequest id=\(requestID) error ignored (stale) latest=\(latestRequestID) error=\(error.localizedDescription)"
                )
                return
            }
            translationLastError = error.localizedDescription
            isTranslating = false
            print(
                "[Caption] runRequest failed id=\(requestID) wallTotal=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - runWallStart))s error=\(error.localizedDescription)"
            )
        }
    }

    private static func logPreview(_ text: String, maxLen: Int = 72) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= maxLen { return String(oneLine) }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: maxLen)
        return String(oneLine[..<idx]) + "…"
    }

    private static func transcriptsLikelySameTurn(_ committed: String, _ requestText: String) -> Bool {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }
        return false
    }
}
