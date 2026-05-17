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
                            LiveSttAndTranslationColumn(
                                speakerLabel: ConversationViewModel.speakerLabel,
                                rawTranscript: state.liveTranscript,
                                caption: model.captionTranslation
                            )
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

    private func committedTurnBubble(turn: ConversationTurn, speechLocaleIdentifier: String) -> some View {
        let translation = turn.gptTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 6) {
            Text(turn.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)

            Text(turn.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let fluid = turn.fluidAudioText?.trimmingCharacters(in: .whitespacesAndNewlines), !fluid.isEmpty {
                Text(fluid)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.yellow)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if turn.isAwaitingFluidAudio {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refining with FluidAudio…")
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

/// STT text comes from conversation state; translation UI is a **nested** subtree that subscribes only to `caption`.
private struct LiveSttAndTranslationColumn: View {
    let speakerLabel: String
    let rawTranscript: String
    let caption: CaptionTranslationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            liveRawBubble(label: speakerLabel, rawTranscript: rawTranscript)
            LiveTranslationPanel(caption: caption)
        }
    }

    private func liveRawBubble(label: String, rawTranscript: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
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
}

/// Only this view reads `caption` published fields — translation churn does not rebuild the STT bubble above.
private struct LiveTranslationPanel: View {
    let caption: CaptionTranslationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if caption.isTranslating && caption.liveTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            let corrected = caption.liveCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !corrected.isEmpty {
                Text(corrected)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let t = caption.liveTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                Text(t)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let err = caption.translationLastError?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live translation")
    }
}
