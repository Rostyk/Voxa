import AVFoundation
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
    @ObservationIgnored private let bubbleAudio = BubbleSegmentAudioBuffer()
    @ObservationIgnored private var lastEnergySpeaking: Bool?
    @ObservationIgnored private let speechUI = SpeechUIBridge()
    @ObservationIgnored private var liveDiarizationGeneration: UInt64 = 0
    @ObservationIgnored private var liveDiarizationInFlight = false
    @ObservationIgnored private var activeCallSession: CallHistorySession?
    @ObservationIgnored private var endedCallSession: CallHistorySession?
    @ObservationIgnored private var endedCallGeneratedTitle: String?

    /// Locales supported for dictation-style speech on this Mac (same pool as `SFSpeechRecognizer`).
    static func supportedSpeechLocaleIdentifiers() -> [String] {
        SpeechRecognitionLocaleCatalog.supportedIdentifiers()
    }

    /// Picks a supported locale identifier closest to `preferred` (exact match, then same language code).
    static func resolvedSpeechLocaleIdentifier(_ preferred: String) -> String {
        SpeechRecognitionLocaleCatalog.resolvedIdentifier(preferred)
    }

    init() {
        let localeId = SpeechRecognitionLocaleCatalog.defaultSpeechLocaleIdentifier
        state = ConversationState(
            history: [],
            liveTranscript: "",
            liveSpeakerSegments: nil,
            liveBubbleAudioSeconds: 0,
            isSpeakerSpeaking: false,
            isSilent: true,
            speechAuthorized: false,
            speechLocaleIdentifier: localeId,
            lastError: nil
        )
        speechUI.attach(host: self)
        captionTranslation.onSupersededTranslation = { [weak self] turnID, transcript, corrected, translation, actions in
            self?.mergeSupersededCaptionIntoTurnIfNeeded(
                turnID: turnID,
                transcript: transcript,
                corrected: corrected,
                translation: translation,
                actions: actions
            )
        }
    }

    /// Settings flag: speaker diarization UI + FluidAudio `DiarizerManager` (off by default).
    var speakerDiarizationEnabled: Bool {
        captionTranslation.diarizeSpeakersOnCommit
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
        beginCallHistorySessionIfNeeded()
        recorder.onLiveBuffer = nil
        speechUI.cancelAll()
        speech.stop()
        liveDiarizationGeneration &+= 1
        liveDiarizationInFlight = false
        bubbleAudio.reset()
        configureLiveDiarizationProbes()

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
            self?.bubbleAudio.append(buffer)
            self?.speech.append(buffer)
        }
        lastEnergySpeaking = nil
        if captionTranslation.correctUsingFluidAudio {
            let preloadDiarizer = captionTranslation.diarizeSpeakersOnCommit
            Task.detached(priority: .utility) {
                do {
                    try await FluidAudioBubbleTranscriber.shared.preloadModels()
                } catch {
                    print("[ConversationViewModel] FluidAudio STT preload failed: \(error.localizedDescription)")
                }
                if preloadDiarizer {
                    do {
                        try await FluidAudioBubbleDiarizer.shared.preloadModels()
                    } catch {
                        print("[ConversationViewModel] FluidAudio diarizer preload failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        print(
            "[ConversationViewModel] bindToRecorder live tap wired locale=\(locale.identifier) (onLiveBuffer -> speech.append; UI debounced)"
        )
    }

    func unbind(from recorder: CallAudioRecorder) {
        print("[ConversationViewModel] unbind")
        recorder.onLiveBuffer = nil
        speechUI.cancelAll()
        speech.stop()
        clearLiveDiarizationState()
        bubbleAudio.onLiveDiarizationInterval = nil
        bubbleAudio.reset()
        var s = state
        s.liveTranscript = ""
        s.liveSpeakerSegments = nil
        s.liveBubbleAudioSeconds = 0
        s.isSpeakerSpeaking = false
        s.isSilent = true
        state = s
        captionTranslation.onStoppedListening(preserveCommittedTranslations: true)
        endCallHistorySessionIfNeeded()
    }

    func clearConversation() {
        print("[ConversationViewModel] clearConversation")
        clearLiveDiarizationState()
        bubbleAudio.reset()
        speechUI.cancelAll()
        var s = state
        s.history = []
        s.liveTranscript = ""
        s.liveSpeakerSegments = nil
        s.liveBubbleAudioSeconds = 0
        state = s
        captionTranslation.onConversationCleared()
    }

    /// Call when the settings checkbox toggles (clears live UI or wires 10 s probes while recording).
    func applySpeakerDiarizationSetting(_ enabled: Bool) {
        if enabled {
            configureLiveDiarizationProbes()
        } else {
            bubbleAudio.onLiveDiarizationInterval = nil
            clearLiveDiarizationState()
        }
    }

    private func configureLiveDiarizationProbes() {
        guard speakerDiarizationEnabled else {
            bubbleAudio.onLiveDiarizationInterval = nil
            return
        }
        bubbleAudio.onLiveDiarizationInterval = { [weak self] in
            Task { @MainActor in
                self?.runLiveDiarizationProbe()
            }
        }
    }

    private func clearLiveDiarizationState() {
        liveDiarizationGeneration &+= 1
        liveDiarizationInFlight = false
        var s = state
        s.liveSpeakerSegments = nil
        s.liveBubbleAudioSeconds = 0
        state = s
        persistEndedCallSnapshotIfNeeded(reason: "fluid audio")
    }

    /// Diarization-only on the in-progress bubble (~every 10 s). Does not commit or run Parakeet STT.
    private func runLiveDiarizationProbe() {
        guard speakerDiarizationEnabled else { return }
        guard captionTranslation.correctUsingFluidAudio, speakerDiarizationEnabled else { return }
        guard !liveDiarizationInFlight else {
            print("[ConversationViewModel] live diarization probe skipped — previous probe in flight")
            return
        }

        let samples = bubbleAudio.peekSnapshot()
        let audioSec = Float(samples.count) / Float(BubbleSegmentAudioBuffer.sampleRate)
        guard samples.count >= FluidAudioBubbleDiarizer.minimumSamplesForProbe else {
            print(
                "[ConversationViewModel] live diarization probe skipped — audio too short samples=\(samples.count)"
            )
            return
        }

        liveDiarizationInFlight = true
        let generation = liveDiarizationGeneration
        print(
            "[ConversationViewModel] live diarization probe START gen=\(generation) samples=\(samples.count) ≈\(String(format: "%.2f", audioSec))s"
        )

        Task.detached(priority: .utility) { [weak self] in
            let segments: [SpeakerDiarizationSegment]
            do {
                segments = try await FluidAudioBubbleDiarizer.shared.diarize(
                    samples: samples,
                    pass: .liveProbe
                )
            } catch {
                print(
                    "[ConversationViewModel] live diarization probe failed gen=\(generation): \(error.localizedDescription)"
                )
                await MainActor.run {
                    guard let self else { return }
                    if generation == self.liveDiarizationGeneration {
                        self.liveDiarizationInFlight = false
                    }
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                self.liveDiarizationInFlight = false
                guard generation == self.liveDiarizationGeneration else {
                    print("[ConversationViewModel] live diarization probe discarded — stale gen=\(generation)")
                    return
                }
                var s = self.state
                s.liveSpeakerSegments = segments.isEmpty ? nil : segments
                s.liveBubbleAudioSeconds = audioSec
                self.state = s
                let unique = Set(segments.map(\.speakerId)).count
                print(
                    "[ConversationViewModel] live diarization probe DONE gen=\(generation) segments=\(segments.count) uniqueSpeakers=\(unique)"
                )
            }
        }
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

        if speakerDiarizationEnabled {
            clearLiveDiarizationState()
        }

        let audioSnapshot = bubbleAudio.takeSnapshotAndReset()
        let useFluid = captionTranslation.correctUsingFluidAudio
        let useDiarization = useFluid && captionTranslation.diarizeSpeakersOnCommit
        let turn = ConversationTurn(
            speakerLabel: Self.speakerLabel,
            text: trimmed,
            fluidAudioText: nil,
            isAwaitingFluidAudio: useFluid,
            speakerSegments: nil,
            isAwaitingDiarization: useDiarization,
            gptCorrected: nil,
            gptTranslation: nil
        )
        var s = state
        s.history.append(turn)
        if s.history.count > Self.maxHistoryTurns {
            s.history.removeFirst(s.history.count - Self.maxHistoryTurns)
        }
        s.liveTranscript = ""
        s.liveSpeakerSegments = nil
        s.liveBubbleAudioSeconds = 0
        s.isSilent = !s.isSpeakerSpeaking
        state = s
        let audioSec = Double(audioSnapshot.count) / 16_000.0
        print(
            "[ConversationViewModel] applyCommit historyCount=\(s.history.count) appleChars=\(trimmed.count) fluid=\(useFluid) diarize=\(useDiarization) audioSamples=\(audioSnapshot.count) ≈\(String(format: "%.2f", audioSec))s \(Self.commitLogPreview(trimmed))"
        )

        if useFluid {
            scheduleFluidAudioThenTranslate(
                turnID: turn.id,
                appleTranscript: trimmed,
                audioSnapshot: audioSnapshot,
                runDiarization: useDiarization
            )
        } else {
            captionTranslation.onSegmentCommitted(lateCaptionTurnID: turn.id, committedTranscript: trimmed)
        }
        persistEndedCallSnapshotIfNeeded(reason: "late commit")
    }

    private func scheduleFluidAudioThenTranslate(
        turnID: UUID,
        appleTranscript: String,
        audioSnapshot: [Float],
        runDiarization: Bool
    ) {
        let sessionGen = captionTranslation.translationSessionGenerationSnapshot()
        Task.detached(priority: .userInitiated) { [weak self] in
            async let transcribeTask = Self.transcribeBubble(samples: audioSnapshot, turnID: turnID)
            async let diarizeTask: [SpeakerDiarizationSegment] = runDiarization
                ? await Self.diarizeBubble(samples: audioSnapshot, turnID: turnID)
                : []

            let transcription: FluidBubbleTranscription
            do {
                transcription = try await transcribeTask
            } catch {
                print(
                    "[ConversationViewModel] FluidAudio bubble failed turn=\(turnID): \(error.localizedDescription) — falling back to Apple transcript for translation"
                )
                let segments = runDiarization ? await diarizeTask : []
                await MainActor.run {
                    self?.finishFluidAudioPath(
                        turnID: turnID,
                        appleTranscript: appleTranscript,
                        fluidText: nil,
                        fluidTokenTimings: nil,
                        speakerSegments: runDiarization && !segments.isEmpty ? segments : nil,
                        sessionGeneration: sessionGen
                    )
                }
                return
            }

            let segments = runDiarization ? await diarizeTask : []
            let tokenTimings: [VoxaTokenTiming]? =
                runDiarization && !transcription.tokenTimings.isEmpty ? transcription.tokenTimings : nil
            await MainActor.run {
                self?.finishFluidAudioPath(
                    turnID: turnID,
                    appleTranscript: appleTranscript,
                    fluidText: transcription.text,
                    fluidTokenTimings: tokenTimings,
                    speakerSegments: runDiarization && !segments.isEmpty ? segments : nil,
                    sessionGeneration: sessionGen
                )
            }
        }
    }

    private static func transcribeBubble(samples: [Float], turnID: UUID) async throws -> FluidBubbleTranscription {
        try await FluidAudioBubbleTranscriber.shared.transcribe(samples: samples)
    }

    private static func diarizeBubble(samples: [Float], turnID: UUID) async -> [SpeakerDiarizationSegment] {
        do {
            return try await FluidAudioBubbleDiarizer.shared.diarize(
                samples: samples,
                pass: .committedBubble
            )
        } catch {
            print(
                "[ConversationViewModel] FluidAudio diarization failed turn=\(turnID): \(error.localizedDescription)"
            )
            return []
        }
    }

    private func finishFluidAudioPath(
        turnID: UUID,
        appleTranscript: String,
        fluidText: String?,
        fluidTokenTimings: [VoxaTokenTiming]?,
        speakerSegments: [SpeakerDiarizationSegment]?,
        sessionGeneration: UInt64
    ) {
        guard sessionGeneration == captionTranslation.translationSessionGenerationSnapshot() else {
            print("[ConversationViewModel] FluidAudio result discarded — session generation changed turn=\(turnID)")
            return
        }

        let trimmedFluid = fluidText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateTurnAfterFluidAudio(
            turnID: turnID,
            fluidText: trimmedFluid.isEmpty ? nil : trimmedFluid,
            fluidTokenTimings: fluidTokenTimings,
            speakerSegments: speakerSegments
        )

        let transcriptForTranslation =
            trimmedFluid.isEmpty ? appleTranscript : trimmedFluid
        let segmentCount = speakerSegments?.count ?? 0
        let uniqueSpeakers = Set(speakerSegments?.map(\.speakerId) ?? []).count
        print(
            "[ConversationViewModel] FluidAudio → translate turn=\(turnID) fluidChars=\(trimmedFluid.count) useChars=\(transcriptForTranslation.count) diarizationSegments=\(segmentCount) uniqueSpeakers=\(uniqueSpeakers)"
        )
        captionTranslation.onSegmentCommitted(
            lateCaptionTurnID: turnID,
            committedTranscript: transcriptForTranslation
        )
    }

    private func updateTurnAfterFluidAudio(
        turnID: UUID,
        fluidText: String?,
        fluidTokenTimings: [VoxaTokenTiming]?,
        speakerSegments: [SpeakerDiarizationSegment]?
    ) {
        guard let idx = state.history.firstIndex(where: { $0.id == turnID }) else { return }
        let row = state.history[idx]
        let label =
            speakerDiarizationEnabled
            ? (Self.speakerLabel(for: speakerSegments) ?? row.speakerLabel)
            : row.speakerLabel
        var s = state
        s.history[idx] = ConversationTurn(
            id: row.id,
            speakerLabel: label,
            text: row.text,
            fluidAudioText: fluidText,
            isAwaitingFluidAudio: false,
            speakerSegments: speakerSegments,
            fluidTokenTimings: fluidTokenTimings,
            isAwaitingDiarization: false,
            gptCorrected: row.gptCorrected,
            gptTranslation: row.gptTranslation,
            gptActions: row.gptActions,
            createdAt: row.createdAt
        )
        state = s
    }

    /// Header label from diarization: dominant talker, or “N speakers”.
    private static func speakerLabel(for segments: [SpeakerDiarizationSegment]?) -> String? {
        guard let segments, !segments.isEmpty else { return nil }
        let unique = Set(segments.map(\.speakerId))
        if unique.count == 1, let id = unique.first {
            return SpeakerDiarizationSegment.displayLabel(for: id)
        }
        if unique.count > 1 {
            return "\(unique.count) speakers"
        }
        return nil
    }

    /// Merges caption / translation into the history row for `turnID` (may not be the last row if several segments finish out of API order).
    private func mergeSupersededCaptionIntoTurnIfNeeded(
        turnID: UUID,
        transcript: String,
        corrected: String,
        translation: String,
        actions: [CallGoalAction]
    ) {
        guard let idx = state.history.firstIndex(where: { $0.id == turnID }) else {
            print("[ConversationViewModel] mergeCaption skipped — no history row for turnID=\(turnID)")
            return
        }
        let row = state.history[idx]
        let rowText = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inflight = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fluid = row.fluidAudioText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Fluid re-transcription often drops Apple ASR preamble; translation is keyed by turnID + fluid text.
        let pairOK =
            rowText == inflight
            || (!fluid.isEmpty && fluid == inflight)
            || TranscriptTurnMatch.likelySameTurn(committed: rowText, inflight: inflight)
            || TranscriptTurnMatch.likelySameTurnLenient(committed: rowText, inflight: inflight)
            || (!fluid.isEmpty && TranscriptTurnMatch.likelySameTurn(committed: fluid, inflight: inflight))
            || (!fluid.isEmpty && TranscriptTurnMatch.likelySameTurnLenient(committed: fluid, inflight: inflight))
        guard pairOK else {
            print(
                "[ConversationViewModel] mergeCaption skipped — inflight transcript does not pair with row text turnID=\(turnID) rowChars=\(rowText.count) inflightChars=\(inflight.count) fluidChars=\(fluid.count)"
            )
            return
        }
        let newCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedCorrected: String? = newCorrected.isEmpty ? row.gptCorrected : newCorrected
        let mergedTranslation: String? = newTranslation.isEmpty ? row.gptTranslation : newTranslation
        let mergedActions = actions.isEmpty ? row.gptActions : actions
        if !actions.isEmpty {
            CallGoalActionLog.logList(actions, context: "mergeCaption incoming turnID=\(turnID)")
        }
        if mergedActions != row.gptActions {
            CallGoalActionLog.logList(mergedActions, context: "mergeCaption stored on history[\(idx)] (was \(row.gptActions.count))")
        }
        guard mergedCorrected != row.gptCorrected || mergedTranslation != row.gptTranslation || mergedActions != row.gptActions else {
            print("[CallGoal] mergeCaption skipped — no changes for turnID=\(turnID)")
            return
        }
        var s = state
        s.history[idx] = ConversationTurn(
            id: row.id,
            speakerLabel: row.speakerLabel,
            text: row.text,
            fluidAudioText: row.fluidAudioText,
            isAwaitingFluidAudio: row.isAwaitingFluidAudio,
            speakerSegments: row.speakerSegments,
            fluidTokenTimings: row.fluidTokenTimings,
            isAwaitingDiarization: row.isAwaitingDiarization,
            gptCorrected: mergedCorrected,
            gptTranslation: mergedTranslation,
            gptActions: mergedActions,
            createdAt: row.createdAt
        )
        state = s
        print(
            "[ConversationViewModel] mergeCaptionIntoTurn turnID=\(turnID) rowIndex=\(idx) transcriptChars=\(transcript.count) hadTranslation=\(row.gptTranslation != nil) actions=\(mergedActions.count)"
        )
        persistEndedCallSnapshotIfNeeded(reason: "translation merge")
    }

    private static func commitLogPreview(_ text: String, maxLen: Int = 64) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        if t.count <= maxLen { return "preview=\"\(t)\"" }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return "preview=\"\(t[..<idx])…\""
    }

    private func beginCallHistorySessionIfNeeded() {
        guard activeCallSession == nil else { return }

        let previousHistoryCount = state.history.count
        let previousLiveChars = state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).count
        activeCallSession = CallHistorySession(id: UUID(), startedAt: Date())
        endedCallSession = nil
        endedCallGeneratedTitle = nil

        if !state.history.isEmpty || !state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var s = state
            s.history = []
            s.liveTranscript = ""
            s.liveSpeakerSegments = nil
            s.liveBubbleAudioSeconds = 0
            state = s
        }
        captionTranslation.onConversationCleared()
        print(
            "[History] call session started id=\(activeCallSession?.id.uuidString ?? "(nil)") startedAt=\(activeCallSession?.startedAt.description ?? "(nil)") clearedPreviousTurns=\(previousHistoryCount) clearedLiveChars=\(previousLiveChars)"
        )
    }

    private func endCallHistorySessionIfNeeded() {
        guard let session = activeCallSession else { return }
        activeCallSession = nil
        let endedAt = Date()
        endedCallSession = CallHistorySession(id: session.id, startedAt: session.startedAt, endedAt: endedAt)
        print(
            "[History] call session ended id=\(session.id) startedAt=\(session.startedAt) endedAt=\(endedAt) duration=\(String(format: "%.2f", endedAt.timeIntervalSince(session.startedAt)))s currentTurns=\(state.history.count)"
        )
        saveEndedCallSnapshot(reason: "call ended")
        requestGeneratedTitleForEndedCall()
    }

    private func persistEndedCallSnapshotIfNeeded(reason: String) {
        guard endedCallSession != nil else {
            print("[History] snapshot skip reason=\(reason) — no ended session")
            return
        }
        saveEndedCallSnapshot(reason: reason)
    }

    private func saveEndedCallSnapshot(reason: String) {
        guard let session = endedCallSession else { return }
        let record = makeCallHistoryRecord(
            session: session,
            generatedTitle: endedCallGeneratedTitle
        )
        guard !record.turns.isEmpty else {
            print("[History] skip save \(reason) — no bubbles")
            return
        }
        CallHistoryStore.shared.upsert(record)
        print(
            "[History] snapshot saved reason=\(reason) id=\(record.id) turns=\(record.turns.count) translatedTurns=\(record.turns.filter { ($0.gptTranslation ?? "").isEmpty == false }.count) fluidTurns=\(record.turns.filter { ($0.fluidAudioText ?? "").isEmpty == false }.count) actions=\(record.turns.reduce(0) { $0 + $1.gptActions.count }) generatedTitle=\"\(record.generatedTitle ?? "")\""
        )
    }

    private func requestGeneratedTitleForEndedCall() {
        guard let session = endedCallSession else { return }
        let sessionID = session.id

        print("[HistoryTitle] schedule title generation id=\(sessionID) delayMs=1500")
        Task { [weak self] in
            // Speech can flush a final committed bubble just after the tap stops.
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self else { return }
            guard self.endedCallSession?.id == sessionID else {
                print("[HistoryTitle] cancel title generation id=\(sessionID) — ended session changed")
                return
            }

            let record = self.makeCallHistoryRecord(
                session: session,
                generatedTitle: self.endedCallGeneratedTitle
            )
            guard !record.turns.isEmpty else {
                print("[HistoryTitle] skip title generation id=\(sessionID) — no turns after delay")
                return
            }
            print(
                "[HistoryTitle] begin title generation id=\(record.id) turns=\(record.turns.count) translatedTurns=\(record.turns.filter { ($0.gptTranslation ?? "").isEmpty == false }.count)"
            )
            guard let title = await CallTitleGenerator.generateTitle(for: record) else {
                print("[HistoryTitle] no generated title id=\(record.id)")
                return
            }
            guard self.endedCallSession?.id == record.id else {
                print("[HistoryTitle] discard generated title id=\(record.id) — ended session changed")
                return
            }
            self.endedCallGeneratedTitle = title
            print("[HistoryTitle] apply generated title id=\(record.id) title=\"\(title)\"")
            self.saveEndedCallSnapshot(reason: "generated title")
        }
    }

    private func makeCallHistoryRecord(
        session: CallHistorySession,
        generatedTitle: String?
    ) -> CallHistoryRecord {
        CallHistoryRecord(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt ?? Date(),
            manualTitle: nil,
            generatedTitle: generatedTitle,
            speechLocaleIdentifier: state.speechLocaleIdentifier,
            translationLocaleIdentifier: captionTranslation.translationLocaleIdentifier,
            translationEngine: captionTranslation.translationEngine,
            callGoal: captionTranslation.callGoal,
            turns: state.history.map(Self.finishedHistoryTurn)
        )
    }

    private static func finishedHistoryTurn(_ turn: ConversationTurn) -> ConversationTurn {
        ConversationTurn(
            id: turn.id,
            speakerLabel: turn.speakerLabel,
            text: turn.text,
            fluidAudioText: turn.fluidAudioText,
            isAwaitingFluidAudio: false,
            speakerSegments: turn.speakerSegments,
            fluidTokenTimings: turn.fluidTokenTimings,
            isAwaitingDiarization: false,
            gptCorrected: turn.gptCorrected,
            gptTranslation: turn.gptTranslation,
            gptActions: turn.gptActions,
            createdAt: turn.createdAt
        )
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

private struct CallHistorySession {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
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

    /// Avoid `queue.sync` from the main thread (can stall UI during bind/clear).
    func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.partialFlush?.cancel()
            self.partialFlush = nil
            self.partialLatest = ""
            self.energyFlush?.cancel()
            self.energyFlush = nil
        }
    }
}
