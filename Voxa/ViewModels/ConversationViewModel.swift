import Foundation
import Observation

@MainActor
@Observable
final class ConversationViewModel {

    static let liveSpeakerLabel = "Live"
    private static let maxHistoryTurns = 150

    private(set) var state = ConversationState.empty

    @ObservationIgnored private let fluid = FluidAudioTranscriptionService()
    @ObservationIgnored private var lastEnergySpeaking: Bool?
    @ObservationIgnored private var fluidBindTask: Task<Void, Never>?
    @ObservationIgnored private var lastBoundRecorder: ObjectIdentifier?
    @ObservationIgnored private var lastBindAt: CFAbsoluteTime = 0

    /// Gate for starting FluidAudio (Parakeet + LS-EEND). Set after mic + system audio are ready.
    func setTranscriptionAuthorized(_ granted: Bool) {
        print("[ConversationViewModel] setTranscriptionAuthorized granted=\(granted)")
        var s = state
        s.transcriptionAuthorized = granted
        if !granted {
            s.lastError =
                "Local transcription is unavailable. FluidAudio models could not be prepared on this device."
        } else {
            s.lastError = nil
        }
        state = s
    }

    func bindToRecorder(_ recorder: CallAudioRecorder) {
        print("[ConversationViewModel] bindToRecorder enter transcriptionAuthorized=\(state.transcriptionAuthorized)")
        let rid = ObjectIdentifier(recorder)
        let now = CFAbsoluteTimeGetCurrent()
        if lastBoundRecorder == rid, now - lastBindAt < 0.75 {
            print("[ConversationViewModel] bindToRecorder skipped (debounce duplicate bind)")
            return
        }
        lastBoundRecorder = rid
        lastBindAt = now

        recorder.onLiveBuffer = nil
        fluidBindTask?.cancel()

        guard state.transcriptionAuthorized else {
            var s = state
            s.lastError = "Allow transcription to see live captions (FluidAudio runs on device)."
            state = s
            print("[ConversationViewModel] bindToRecorder aborted — transcription not authorized")
            return
        }
        var s = state
        s.lastError = nil
        state = s

        fluidBindTask = Task { @MainActor in
            await self.fluid.stop()
            do {
                try await self.fluid.start(
                    onPartial: { [weak self] text in
                        Task { @MainActor in self?.applyPartial(text) }
                    },
                    onCommit: { [weak self] text, speakerLabel in
                        Task { @MainActor in self?.applyCommit(text, speakerLabel: speakerLabel) }
                    },
                    onEnergy: { [weak self] speaking in
                        Task { @MainActor in self?.applyEnergy(speaking) }
                    }
                )
                recorder.onLiveBuffer = { [weak self] buffer in
                    Task { await self?.fluid.append(buffer) }
                }
                self.lastEnergySpeaking = nil
                print("[ConversationViewModel] bindToRecorder FluidAudio live tap wired")
            } catch is CancellationError {
                print("[ConversationViewModel] bindToRecorder FluidAudio start cancelled (rebind)")
            } catch {
                var st = self.state
                st.lastError =
                    "FluidAudio failed to start: \(error.localizedDescription). First launch downloads models from the FluidAudio registry."
                self.state = st
                print("[ConversationViewModel] bindToRecorder FluidAudio start failed: \(error)")
            }
        }
    }

    func unbind(from recorder: CallAudioRecorder) {
        print("[ConversationViewModel] unbind")
        lastBoundRecorder = nil
        recorder.onLiveBuffer = nil
        fluidBindTask?.cancel()
        fluidBindTask = Task { @MainActor in await self.fluid.stop() }
        var s = state
        s.liveTranscript = ""
        s.isSpeakerSpeaking = false
        s.isSilent = true
        state = s
    }

    func clearConversation() {
        print("[ConversationViewModel] clearConversation")
        var s = state
        s.history = []
        s.liveTranscript = ""
        state = s
    }

    private func applyPartial(_ text: String) {
        var s = state
        s.liveTranscript = text
        s.isSilent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !s.isSpeakerSpeaking
        state = s
    }

    private func applyCommit(_ text: String, speakerLabel: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s = state
        s.history.append(ConversationTurn(speakerLabel: speakerLabel, text: trimmed))
        if s.history.count > Self.maxHistoryTurns {
            s.history.removeFirst(s.history.count - Self.maxHistoryTurns)
        }
        s.liveTranscript = ""
        s.isSilent = !s.isSpeakerSpeaking
        state = s
        print(
            "[ConversationViewModel] applyCommit speaker=\(speakerLabel) historyCount=\(s.history.count) chars=\(trimmed.count) \(Self.commitLogPreview(trimmed))"
        )
    }

    private static func commitLogPreview(_ text: String, maxLen: Int = 64) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        if t.count <= maxLen { return "preview=\"\(t)\"" }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return "preview=\"\(t[..<idx])…\""
    }

    private func applyEnergy(_ speaking: Bool) {
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
