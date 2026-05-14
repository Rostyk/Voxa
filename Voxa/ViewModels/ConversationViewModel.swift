import Foundation
import Observation

@MainActor
@Observable
final class ConversationViewModel {

    static let speakerLabel = "Speaker"
    private static let maxHistoryTurns = 150

    private(set) var state = ConversationState.empty

    @ObservationIgnored private let speech = VoiceToTextManager()
    @ObservationIgnored private var lastEnergySpeaking: Bool?

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

        speech.start(
            onPartial: { [weak self] text in
                Task { @MainActor in self?.applyPartial(text) }
            },
            onCommit: { [weak self] text in
                Task { @MainActor in self?.applyCommit(text) }
            },
            onEnergy: { [weak self] speaking in
                Task { @MainActor in self?.applyEnergy(speaking) }
            }
        )
        recorder.onLiveBuffer = { [weak self] buffer in
            self?.speech.append(buffer)
        }
        lastEnergySpeaking = nil
        print("[ConversationViewModel] bindToRecorder live tap wired (onLiveBuffer -> speech.append)")
    }

    func unbind(from recorder: CallAudioRecorder) {
        print("[ConversationViewModel] unbind")
        recorder.onLiveBuffer = nil
        speech.stop()
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

    private func applyCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s = state
        s.history.append(ConversationTurn(speakerLabel: Self.speakerLabel, text: trimmed))
        if s.history.count > Self.maxHistoryTurns {
            s.history.removeFirst(s.history.count - Self.maxHistoryTurns)
        }
        s.liveTranscript = ""
        s.isSilent = !s.isSpeakerSpeaking
        state = s
        print(
            "[ConversationViewModel] applyCommit historyCount=\(s.history.count) chars=\(trimmed.count) \(Self.commitLogPreview(trimmed))"
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
