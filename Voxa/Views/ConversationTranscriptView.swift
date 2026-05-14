import AppKit
import Observation
import SwiftUI

/// Transcript UI: **Observation-split** so `CaptionTranslationViewModel` mutations do not invalidate the
/// same SwiftUI subtree as live STT (`ConversationViewModel.state`). Settings still bind to caption pickers.
struct ConversationTranscriptView: View {
    let model: ConversationViewModel
    @State private var showCallContextSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CaptionSettingsSection(model: model, showCallContextSheet: $showCallContextSheet)
            TranscriptScrollCard(model: model)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings (isolated @Bindable caption)

private struct CaptionSettingsSection: View {
    @Bindable var model: ConversationViewModel
    @Binding var showCallContextSheet: Bool

    private var state: ConversationState { model.state }

    var body: some View {
        @Bindable var caption = model.captionTranslation

        captionSettingsCard(
            speechLocale: $model.speechLocaleIdentifier,
            translationEngine: $caption.translationEngine,
            translationLocale: $caption.translationLocaleIdentifier,
            translationLastError: caption.translationLastError
        )
        .sheet(isPresented: $showCallContextSheet) {
            callContextEditorSheet(isPresented: $showCallContextSheet, notes: $caption.callContextNotes)
        }
    }

    @ViewBuilder
    private func captionSettingsCard(
        speechLocale: Binding<String>,
        translationEngine: Binding<LiveCaptionTranslationEngine>,
        translationLocale: Binding<String>,
        translationLastError: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech & translation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Language")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: speechLocale) {
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
                        Picker("", selection: translationEngine) {
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

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Translate to")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: translationLocale) {
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

                    callContextButton

                    Spacer(minLength: 0)
                }
            }

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tErr = translationLastError {
                Text(tErr)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .transcriptPanelChrome()
    }

    private var callContextButton: some View {
        Button {
            showCallContextSheet = true
        } label: {
            Label("Call context", systemImage: "text.badge.plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Optional notes about this call — used in the ChatGPT translation prompt only (Google Translate ignores this).")
    }

    private func menuTitle(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
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

// MARK: - Transcript only observes conversation state

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
                            committedTurnBubble(turn: turn)
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
        .transcriptPanelChrome()
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

// MARK: - Panel chrome

private extension View {
    @ViewBuilder
    func transcriptPanelChrome() -> some View {
        background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}
