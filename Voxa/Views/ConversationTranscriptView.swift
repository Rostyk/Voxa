import AppKit
import Observation
import SwiftUI

struct ConversationTranscriptView: View {
    @Bindable var model: ConversationViewModel
    @State private var showCallContextSheet = false

    private var state: ConversationState { model.state }

    var body: some View {
        @Bindable var caption = model.captionTranslation

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Live transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                statusChip
            }

            HStack(alignment: .center, spacing: 12) {
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
                    .frame(maxWidth: 200, alignment: .trailing)
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Speech recognition language")

                HStack(spacing: 6) {
                    Text("Via")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $caption.translationEngine) {
                        ForEach(LiveCaptionTranslationEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Translation engine")

                HStack(spacing: 6) {
                    Text("Translate to")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $caption.translationLocaleIdentifier) {
                        ForEach(CaptionTranslationViewModel.supportedTranslationLocaleIdentifiers(), id: \.self) { id in
                            Text(menuTitle(for: id)).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Translation target language")

                Button {
                    showCallContextSheet = true
                } label: {
                    Label("Call context", systemImage: "text.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Optional notes about this call — used in the ChatGPT translation prompt only (Google Translate ignores this).")

                Spacer(minLength: 0)
            }

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tErr = caption.translationLastError {
                Text(tErr)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.history) { turn in
                            committedTurnBubble(turn: turn)
                                .id(turn.id)
                        }
                        if !state.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            liveMessageBubble(
                                label: ConversationViewModel.speakerLabel,
                                rawTranscript: state.liveTranscript,
                                caption: caption
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
                .onChange(of: caption.liveTranslation) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: caption.liveCorrected) { _, _ in
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
        .sheet(isPresented: $showCallContextSheet) {
            callContextEditorSheet(isPresented: $showCallContextSheet, notes: $caption.callContextNotes)
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

    private func committedTurnBubble(turn: ConversationTurn) -> some View {
        let corrected = turn.gptCorrected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceLine = corrected.isEmpty ? turn.text : corrected
        let translation = turn.gptTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 6) {
            Text(turn.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)

            Text(sourceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !translation.isEmpty {
                Text(translation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func liveMessageBubble(label: String, rawTranscript: String, caption: CaptionTranslationViewModel) -> some View {
        let sourceLine =
            caption.liveCorrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawTranscript
            : caption.liveCorrected

        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(sourceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if caption.isTranslating && caption.liveTranslation.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !caption.liveTranslation.isEmpty {
                Text(caption.liveTranslation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
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

    private func callContextEditorSheet(isPresented: Binding<Bool>, notes: Binding<String>) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("This text is sent to GPT as call context (topic, names, product jargon). It is not shown in the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: notes)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            }
            .padding(16)
            .frame(minWidth: 400, minHeight: 260)
            .navigationTitle("Call context")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { isPresented.wrappedValue = false }
                }
            }
        }
    }
}
