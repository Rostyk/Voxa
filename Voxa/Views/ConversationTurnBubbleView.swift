import SwiftUI

struct ConversationTurnBubbleView: View {
    let turn: ConversationTurn
    let speechLocaleIdentifier: String
    let speakerDiarizationEnabled: Bool

    private var transcript: String {
        let fluid = turn.fluidAudioText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fluid.isEmpty ? turn.text : fluid
    }

    private var translation: String {
        turn.gptTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var diarizationReady: Bool {
        speakerDiarizationEnabled
        && !turn.isAwaitingDiarization
        && !(turn.speakerSegments?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)

            transcriptBody

            if !translation.isEmpty {
                Text(translation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CallGoalActionsView(
                    actions: turn.gptActions,
                    speechLocaleIdentifier: speechLocaleIdentifier
                )
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if diarizationReady, let segments = turn.speakerSegments {
            SpeakerDiarizationTimelineView(segments: segments)

            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SpeakerColoredTranscriptText(
                    spans: SpeakerTranscriptColorizer.transcriptSpans(
                        transcript: transcript,
                        speakerSegments: segments,
                        tokenTimings: turn.fluidTokenTimings
                    )
                )
            }
        } else if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(transcript)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if turn.isAwaitingFluidAudio || (speakerDiarizationEnabled && turn.isAwaitingDiarization) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    speakerDiarizationEnabled && turn.isAwaitingDiarization
                        ? "Detecting speakers..."
                        : "Refining with FluidAudio..."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
