import SwiftUI

/// Debug control: fires the same path as tapping a **play** chip under a translated bubble.
enum CallGoalActionHardcodedTest {
    /// Fixed phrase from live IVR testing (Spanish mortgage inquiry).
    static let phrase = "Quisiera información sobre una hipoteca inmobiliaria."

    static func fire(speechLocaleIdentifier: String) {
        let action = CallGoalAction(type: .text, content: phrase)
        print("[UI] tap TEXT button chars=\(action.content.count) preview=\"\(String(action.content.prefix(48)))\"")
        print("[UI] hardcoded virtual-mic test — same as CallGoalActionsView play chip")
        CallGoalActionExecutor.perform(action, speechLocaleIdentifier: speechLocaleIdentifier)
    }

    static func fireRecordingWAV() {
        print("[UI] tap WAV recording button — VoxaVirtualMicFilePlayback.playRecordingWAV")
        Task {
            await MainActor.run {
                VoxaVirtualMicFeederStatus.shared.clearLastActionError()
            }
            do {
                try await VoxaVirtualMicFilePlayback.playRecordingWAV()
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[UI] WAV recording playback FAILED: \(error)")
                await MainActor.run {
                    VoxaVirtualMicFeederStatus.shared.setLastActionError(detail)
                }
            }
        }
    }
}

/// Always-visible test row for checking virtual-mic TTS / WAV on a real phone call.
struct CallGoalActionHardcodedTestButton: View {
    let speechLocaleIdentifier: String
    @State private var virtualMicStatus = VoxaVirtualMicFeederStatus.shared
    @State private var recordingPathHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Virtual mic test (hardcoded)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Set the call app mic to “Voxa Virtual Microphone”, then tap a test.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = virtualMicStatus.lastActionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let recordingPathHint {
                Text("recording.wav: \(recordingPathHint)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button {
                CallGoalActionHardcodedTest.fire(speechLocaleIdentifier: speechLocaleIdentifier)
            } label: {
                Label {
                    Text(CallGoalActionHardcodedTest.phrase)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .contentShape(Rectangle())
            .help("TTS phrase into virtual mic (same as bubble play chip)")

            Button {
                CallGoalActionHardcodedTest.fireRecordingWAV()
            } label: {
                Label("Play recording.wav", systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .contentShape(Rectangle())
            .help("Stream repo-root recording.wav into virtual mic (real-time paced)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .onAppear {
            if let url = VoxaVirtualMicFilePlayback.recordingWAVURL() {
                recordingPathHint = url.path
            } else {
                recordingPathHint = "not found — add Voxa/recording.wav"
            }
        }
    }
}
