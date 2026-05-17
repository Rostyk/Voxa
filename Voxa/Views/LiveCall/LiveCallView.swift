import SwiftUI

struct LiveCallView: View {
    let callViewModel: CallViewModel
    let conversationViewModel: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: VoxaPanelStyle.sectionSpacing) {
            CallListenerCard(
                processes: callViewModel.activeMicrophoneProcesses,
                isListening: callViewModel.isRecording
            )

            LiveCallGoalBar(model: conversationViewModel)

            if let recorder = callViewModel.recorder, callViewModel.isRecording {
                AudioVisualizationView(
                    barCount: 100,
                    windowDuration: 30,
                    audioLevels: recorder.currentAudioLevels,
                    aiGeneratedChunks: recorder.aiGeneratedChunks,
                    verifiedIdentityChunks: recorder.verifiedIdentityChunks,
                    currentChunk: recorder.chunkCounter,
                    predictionState: recorder.predictionState
                )
                .frame(height: 60)
                .frame(maxWidth: .infinity)

                ConversationTranscriptScrollView(model: conversationViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Live transcript appears when a call app uses the microphone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
