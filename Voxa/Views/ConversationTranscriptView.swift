import AppKit
import Observation
import SwiftUI

struct ConversationTranscriptView: View {
    @Bindable var model: ConversationViewModel

    private var state: ConversationState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Live transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("Language")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.speechLocaleIdentifier) {
                        ForEach(ConversationViewModel.supportedSpeechLocaleIdentifiers(), id: \.self) { id in
                            Text(menuTitle(for: id)).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Speech recognition language")
                statusChip
            }

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.history) { turn in
                            messageBubble(label: turn.speakerLabel, text: turn.text, isLive: false)
                                .id(turn.id)
                        }
                        if !state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messageBubble(
                                label: ConversationViewModel.speakerLabel,
                                text: state.liveTranscript,
                                isLive: true
                            )
                            .id("live")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: state.history.count) { _, _ in
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
            .frame(minHeight: 120, maxHeight: 220)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func menuTitle(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
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

    private func messageBubble(label: String, text: String, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLive ? Color.accentColor : Color.secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isLive ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
    }
}
