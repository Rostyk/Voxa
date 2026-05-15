import AppKit
import Observation
import SwiftUI

/// Speech / translation pickers and **Set goal** — shown before a call starts (no recording required).
struct ConversationCaptionSettingsView: View {
    let model: ConversationViewModel
    @State private var showCallGoalSheet = false

    var body: some View {
        CaptionSettingsSection(model: model, showCallGoalSheet: $showCallGoalSheet)
    }
}

/// Live transcript list — only meaningful while system-audio capture is running.
struct ConversationTranscriptScrollView: View {
    let model: ConversationViewModel

    var body: some View {
        TranscriptScrollCard(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Full column: settings + transcript (used when both are visible).
struct ConversationTranscriptView: View {
    let model: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConversationCaptionSettingsView(model: model)
            ConversationTranscriptScrollView(model: model)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings (isolated @Bindable caption)

private struct CaptionSettingsSection: View {
    @Bindable var model: ConversationViewModel
    @Binding var showCallGoalSheet: Bool

    private var state: ConversationState { model.state }

    var body: some View {
        @Bindable var caption = model.captionTranslation

        captionSettingsCard(
            speechLocale: $model.speechLocaleIdentifier,
            translationEngine: $caption.translationEngine,
            translationLocale: $caption.translationLocaleIdentifier,
            translationLastError: caption.translationLastError
        )
        .sheet(isPresented: $showCallGoalSheet) {
            callGoalEditorSheet(isPresented: $showCallGoalSheet, goal: $caption.callGoal)
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

                    callGoalButton

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

    private var callGoalButton: some View {
        Button {
            showCallGoalSheet = true
        } label: {
            Label("Set goal", systemImage: "target")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("What you want to achieve on this call — ChatGPT uses this for translation + suggested actions.")
    }

    private func menuTitle(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func callGoalEditorSheet(isPresented: Binding<Bool>, goal: Binding<String>) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Describe the goal of this call. ChatGPT will translate each callee line and suggest actions (DTMF, phrases to say, or when you should speak).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: goal)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            }
            .padding(16)
            .frame(minWidth: 400, minHeight: 260)
            .navigationTitle("Set goal")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let trimmed = goal.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("[CallGoal] call goal saved chars=\(trimmed.count) preview=\"\(String(trimmed.prefix(80)))\"")
                        isPresented.wrappedValue = false
                    }
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

    private func committedTurnBubble(turn: ConversationTurn, speechLocaleIdentifier: String) -> some View {
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
