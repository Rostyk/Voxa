import Foundation
import Observation

@MainActor
@Observable
final class ConversationViewModel {

    static let speakerLabel = "Speaker"
    private static let maxHistoryTurns = 150

    private(set) var state: ConversationState

    /// Live-line GPT correction + translation (kept out of conversation state on purpose).
    let captionTranslation = CaptionTranslationViewModel()

    @ObservationIgnored private let speech = VoiceToTextManager()
    @ObservationIgnored private var lastEnergySpeaking: Bool?
    @ObservationIgnored private let speechUI = SpeechUIBridge()

    /// Locales supported for dictation-style speech on this Mac (same pool as `SFSpeechRecognizer`).
    static func supportedSpeechLocaleIdentifiers() -> [String] {
        SpeechRecognitionLocaleCatalog.supportedIdentifiers()
    }

    /// Picks a supported locale identifier closest to `preferred` (exact match, then same language code).
    static func resolvedSpeechLocaleIdentifier(_ preferred: String) -> String {
        SpeechRecognitionLocaleCatalog.resolvedIdentifier(preferred)
    }

    init() {
        let localeId = Self.resolvedSpeechLocaleIdentifier(Locale.current.identifier)
        state = ConversationState(
            history: [],
            liveTranscript: "",
            isSpeakerSpeaking: false,
            isSilent: true,
            speechAuthorized: false,
            speechLocaleIdentifier: localeId,
            lastError: nil
        )
        speechUI.attach(host: self)
        captionTranslation.onSupersededTranslation = { [weak self] turnID, transcript, corrected, translation in
            self?.mergeSupersededCaptionIntoTurnIfNeeded(
                turnID: turnID,
                transcript: transcript,
                corrected: corrected,
                translation: translation
            )
        }
    }

    /// SwiftUI `Picker` binding; changing value rotates `SFSpeechRecognizer` while the tap stays live.
    var speechLocaleIdentifier: String {
        get { state.speechLocaleIdentifier }
        set { applySpeechLocaleIdentifier(newValue) }
    }

    private func applySpeechLocaleIdentifier(_ raw: String) {
        let resolved = Self.resolvedSpeechLocaleIdentifier(raw)
        guard resolved != state.speechLocaleIdentifier else { return }
        var s = state
        s.speechLocaleIdentifier = resolved
        state = s
        speech.applyRecognitionLocale(Locale(identifier: resolved))
    }

    func setSpeechAuthorized(_ granted: Bool) {
        print("[ConversationViewModel] setSpeechAuthorized granted=\(granted)")
        var s = state
        s.speechAuthorized = granted
        if !granted {
            s.lastError = "Speech recognition was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        } else {
            s.lastError = nil
        }
        state = s
    }

    func bindToRecorder(_ recorder: CallAudioRecorder) {
        print("[ConversationViewModel] bindToRecorder enter speechAuthorized=\(state.speechAuthorized)")
        recorder.onLiveBuffer = nil
        speechUI.cancelAll()
        speech.stop()

        guard state.speechAuthorized else {
            var s = state
            s.lastError = "Speech recognition is off — allow it to see live captions."
            state = s
            print("[ConversationViewModel] bindToRecorder aborted — speech not authorized")
            return
        }
        var s = state
        s.lastError = nil
        state = s

        let locale = Locale(identifier: state.speechLocaleIdentifier)
        let ui = speechUI
        speech.start(
            recognitionLocale: locale,
            onPartial: { text in
                ui.enqueuePartial(text)
            },
            onCommit: { text in
                ui.flushPartialThenCommit(text: text)
            },
            onEnergy: { speaking in
                ui.enqueueEnergy(speaking)
            }
        )
        recorder.onLiveBuffer = { [weak self] buffer in
            self?.speech.append(buffer)
        }
        lastEnergySpeaking = nil
        print(
            "[ConversationViewModel] bindToRecorder live tap wired locale=\(locale.identifier) (onLiveBuffer -> speech.append; UI debounced)"
        )
    }

    func unbind(from recorder: CallAudioRecorder) {
        print("[ConversationViewModel] unbind")
        recorder.onLiveBuffer = nil
        speechUI.cancelAll()
        speech.stop()
        var s = state
        s.liveTranscript = ""
        s.isSpeakerSpeaking = false
        s.isSilent = true
        state = s
        captionTranslation.onStoppedListening()
    }

    func clearConversation() {
        print("[ConversationViewModel] clearConversation")
        speechUI.cancelAll()
        var s = state
        s.history = []
        s.liveTranscript = ""
        state = s
        captionTranslation.onLiveTranscriptChanged("")
    }

    fileprivate func applyPartial(_ text: String) {
        var s = state
        s.liveTranscript = text
        s.isSilent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !s.isSpeakerSpeaking
        state = s
        captionTranslation.onLiveTranscriptChanged(text)
    }

    fileprivate func applyCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapCorrected = captionTranslation.liveCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapTranslation = captionTranslation.liveTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let turn = ConversationTurn(
            speakerLabel: Self.speakerLabel,
            text: trimmed,
            gptCorrected: snapCorrected.isEmpty ? nil : snapCorrected,
            gptTranslation: snapTranslation.isEmpty ? nil : snapTranslation
        )
        var s = state
        s.history.append(turn)
        if s.history.count > Self.maxHistoryTurns {
            s.history.removeFirst(s.history.count - Self.maxHistoryTurns)
        }
        s.liveTranscript = ""
        s.isSilent = !s.isSpeakerSpeaking
        state = s
        captionTranslation.onSegmentCommitted(lateCaptionTurnID: turn.id, committedTranscript: trimmed)
        print(
            "[ConversationViewModel] applyCommit historyCount=\(s.history.count) chars=\(trimmed.count) \(Self.commitLogPreview(trimmed))"
        )
    }

    /// Late GPT completion for a transcript that already moved into `history` (commit bumped request generation).
    private func mergeSupersededCaptionIntoTurnIfNeeded(
        turnID: UUID,
        transcript: String,
        corrected: String,
        translation: String
    ) {
        guard let lastIdx = state.history.indices.last else { return }
        let last = state.history[lastIdx]
        // Only merge into the latest committed bubble — avoids attaching a stale response to an older row when text repeats.
        guard last.id == turnID else {
            print("[ConversationViewModel] mergeSupersededCaption skipped — not the most recent committed turn")
            return
        }
        guard Self.transcriptsLikelySameTurn(last.text, transcript) else { return }
        let newCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedCorrected: String? = newCorrected.isEmpty ? last.gptCorrected : newCorrected
        let mergedTranslation: String? = newTranslation.isEmpty ? last.gptTranslation : newTranslation
        guard mergedCorrected != last.gptCorrected || mergedTranslation != last.gptTranslation else { return }
        var s = state
        s.history[lastIdx] = ConversationTurn(
            id: last.id,
            speakerLabel: last.speakerLabel,
            text: last.text,
            gptCorrected: mergedCorrected,
            gptTranslation: mergedTranslation,
            createdAt: last.createdAt
        )
        state = s
        print(
            "[ConversationViewModel] mergeSupersededCaptionIntoTurn turnID=\(turnID) transcriptChars=\(transcript.count) hadTranslation=\(last.gptTranslation != nil)"
        )
    }

    private static func transcriptsLikelySameTurn(_ committed: String, _ requestText: String) -> Bool {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }
        return false
    }

    private static func commitLogPreview(_ text: String, maxLen: Int = 64) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        if t.count <= maxLen { return "preview=\"\(t)\"" }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return "preview=\"\(t[..<idx])…\""
    }

    fileprivate func applyEnergy(_ speaking: Bool) {
        if lastEnergySpeaking != speaking {
            print("[ConversationViewModel] applyEnergy speaking=\(speaking) (was \(String(describing: lastEnergySpeaking)))")
            lastEnergySpeaking = speaking
        }
        var s = state
        s.isSpeakerSpeaking = speaking
        let empty = s.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        s.isSilent = empty && !speaking
        state = s
    }
}

// MARK: - Debounced speech → MainActor UI

/// Coalesces high-frequency STT / RMS callbacks off the audio/speech queues into occasional MainActor updates.
private final class SpeechUIBridge: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.voxa.conversation.speechUI")

    private weak var host: ConversationViewModel?

    private var partialLatest: String = ""
    private var partialFlush: DispatchWorkItem?

    private var energyLatest: Bool = false
    private var energyFlush: DispatchWorkItem?

    private static let partialDebounce: TimeInterval = 0.048
    private static let energyDebounce: TimeInterval = 0.096

    func attach(host: ConversationViewModel) {
        self.host = host
    }

    func enqueuePartial(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.partialLatest = text
            self.partialFlush?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let host = self.host else { return }
                let t = self.partialLatest
                Task { @MainActor in
                    host.applyPartial(t)
                }
            }
            self.partialFlush = work
            self.queue.asyncAfter(deadline: .now() + Self.partialDebounce, execute: work)
        }
    }

    func enqueueEnergy(_ speaking: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.energyLatest = speaking
            self.energyFlush?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let host = self.host else { return }
                let v = self.energyLatest
                Task { @MainActor in
                    host.applyEnergy(v)
                }
            }
            self.energyFlush = work
            self.queue.asyncAfter(deadline: .now() + Self.energyDebounce, execute: work)
        }
    }

    /// Apply any pending partial text, then commit — keeps `liveTranscript` in sync before history append.
    func flushPartialThenCommit(text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.partialFlush?.cancel()
            self.partialFlush = nil
            let pending = self.partialLatest
            self.partialLatest = ""
            self.energyFlush?.cancel()
            self.energyFlush = nil
            Task { @MainActor in
                guard let host = self.host else { return }
                if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    host.applyPartial(pending)
                }
                host.applyCommit(text)
            }
        }
    }

    func cancelAll() {
        queue.sync {
            partialFlush?.cancel()
            partialFlush = nil
            partialLatest = ""
            energyFlush?.cancel()
            energyFlush = nil
        }
    }
}
