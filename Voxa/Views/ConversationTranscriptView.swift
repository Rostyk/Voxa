import SwiftUI

/// Live transcript list — shown on the Live call tab while system-audio capture is running.
struct ConversationTranscriptScrollView: View {
    let model: ConversationViewModel

    var body: some View {
        TranscriptScrollCard(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Transcript

private struct TranscriptScrollCard: View {
    let model: ConversationViewModel

    private var state: ConversationState { model.state }
    private var speakerDiarizationEnabled: Bool { model.speakerDiarizationEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Live transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                statusChip
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.history) { turn in
                            committedTurnBubble(turn: turn, speechLocaleIdentifier: state.speechLocaleIdentifier)
                                .id(turn.id)
                        }
                        if !state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Group {
                                if speakerDiarizationEnabled {
                                    livePartialBubbleWithDiarization(
                                        rawTranscript: state.liveTranscript,
                                        liveSegments: state.liveSpeakerSegments,
                                        liveAudioSeconds: state.liveBubbleAudioSeconds
                                    )
                                } else {
                                    livePartialBubblePlain(rawTranscript: state.liveTranscript)
                                }
                            }
                            .id("live")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: state.history) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: state.liveTranscript) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voxaPanelBackground()
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isSpeakerSpeaking ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(state.isSilent ? "Silent" : "Audio")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private func livePartialBubblePlain(rawTranscript: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ConversationViewModel.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(rawTranscript)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        }
    }

    private func livePartialBubbleWithDiarization(
        rawTranscript: String,
        liveSegments: [SpeakerDiarizationSegment]?,
        liveAudioSeconds: Float
    ) -> some View {
        let liveLabel =
            liveSegments.flatMap { SpeakerTranscriptColorizer.liveSpeakerLabel(segments: $0, audioDurationSeconds: liveAudioSeconds) }
            ?? ConversationViewModel.speakerLabel

        return VStack(alignment: .leading, spacing: 6) {
            Text(liveLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            if let segments = liveSegments,
               !segments.isEmpty,
               liveAudioSeconds > 0 {
                SpeakerColoredTranscriptText(
                    spans: SpeakerTranscriptColorizer.proportionalSpans(
                        transcript: rawTranscript,
                        speakerSegments: segments,
                        audioDurationSeconds: liveAudioSeconds
                    )
                )
            } else {
                Text(rawTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        }
    }

    private func committedTurnBubble(turn: ConversationTurn, speechLocaleIdentifier: String) -> some View {
        let fluid = turn.fluidAudioText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcript = fluid.isEmpty ? turn.text : fluid
        let translation = turn.gptTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let diarizationReady =
            speakerDiarizationEnabled
            && !turn.isAwaitingDiarization
            && !(turn.speakerSegments?.isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 6) {
            Text(turn.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)

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
            } else if turn.isAwaitingFluidAudio
                || (speakerDiarizationEnabled && turn.isAwaitingDiarization) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        speakerDiarizationEnabled && turn.isAwaitingDiarization
                            ? "Detecting speakers…"
                            : "Refining with FluidAudio…"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
}
