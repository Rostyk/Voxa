import SwiftUI

struct SettingsView: View {
    @Bindable var conversationViewModel: ConversationViewModel

    @State private var virtualMicStatus = VoxaVirtualMicFeederStatus.shared
    @State private var virtualMicTestMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoxaPanelStyle.sectionSpacing) {
                Text("Settings")
                    .font(.title2.weight(.semibold))

                SpeechTranslationSettingsBlock(conversationViewModel: conversationViewModel)

                virtualMicSection

                faceTimeSection
            }
            .padding(VoxaPanelStyle.blockPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Virtual mic

    private var virtualMicSection: some View {
        SettingsSectionCard(
            title: "Virtual microphone",
            systemImage: "mic.fill"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    statusDot(virtualMicStatus.isHealthy ? .green : (virtualMicStatus.isRunning ? .orange : .secondary))
                    Text(virtualMicHeadline)
                        .font(.body.weight(.medium))
                }

                Text(virtualMicDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let virtualMicTestMessage {
                    Text(virtualMicTestMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = virtualMicStatus.lastActionError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 12) {
                    Button("Test") {
                        runVirtualMicTest()
                    }
                    .buttonStyle(.borderedProminent)

                    if virtualMicStatus.muteToggleAvailable {
                        Button(virtualMicStatus.isOutputMuted ? "Unmute output" : "Mute output") {
                            VoxaVirtualMicFeeder.shared.setOutputMuted(!virtualMicStatus.isOutputMuted)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var virtualMicHeadline: String {
        if virtualMicStatus.isHealthy { return "Virtual mic is running" }
        if virtualMicStatus.isRunning { return "Virtual mic running (check details)" }
        return "Virtual mic not running"
    }

    private var virtualMicDetail: String {
        if let detail = virtualMicStatus.detailMessage { return detail }
        if virtualMicStatus.isRunning, let name = virtualMicStatus.captureDeviceName {
            return "Capturing “\(name)”. Choose “\(FaceTimeSettingsInspector.voxaVirtualMicDisplayName)” in a call app only when you want Voxa to speak for you."
        }
        return "Use Test to verify the driver appears in macOS input devices and the feeder is running."
    }

    private func runVirtualMicTest() {
        print("[Settings] Virtual mic Test")
        VoxaVirtualMicFeeder.shared.startIfNeeded()
        virtualMicStatus.clearLastActionError()

        let deviceNames = SystemInputDeviceCatalog.inputDeviceNames()
        let voxaListed = SystemInputDeviceCatalog.containsVoxaVirtualMicrophone()
        let feederRunning = virtualMicStatus.isRunning

        var lines: [String] = []
        if voxaListed {
            lines.append("“\(FaceTimeSettingsInspector.voxaVirtualMicDisplayName)” is listed in system input devices.")
        } else {
            lines.append("“\(FaceTimeSettingsInspector.voxaVirtualMicDisplayName)” was not found among \(deviceNames.count) input device(s). Install/start the virtual mic driver.")
        }
        lines.append(feederRunning ? "Voxa feeder process is running." : "Voxa feeder is not running yet.")
        virtualMicTestMessage = lines.joined(separator: " ")
    }

    // MARK: - FaceTime

    private var faceTimeSection: some View {
        FaceTimeSettingsSection()
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

// MARK: - Speech & translation

private struct SpeechTranslationSettingsBlock: View {
    @Bindable var conversationViewModel: ConversationViewModel

    var body: some View {
        @Bindable var caption = conversationViewModel.captionTranslation

        SettingsSectionCard(
            title: "Speech & translation",
            systemImage: "character.bubble"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                settingsRow(label: "Recognition language") {
                    Picker("", selection: $conversationViewModel.speechLocaleIdentifier) {
                        ForEach(ConversationViewModel.supportedSpeechLocaleIdentifiers(), id: \.self) { id in
                            Text(menuTitle(for: id)).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }

                settingsRow(label: "Translate via") {
                    Picker("", selection: $caption.translationEngine) {
                        ForEach(LiveCaptionTranslationEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                settingsRow(label: "Translate to") {
                    Picker("", selection: $caption.translationLocaleIdentifier) {
                        ForEach(CaptionTranslationViewModel.supportedTranslationLocaleIdentifiers(), id: \.self) { id in
                            Text(menuTitle(for: id)).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }

                Toggle(isOn: $caption.correctUsingFluidAudio) {
                    Text("Correct using FluidAudio (offline STT per bubble)")
                        .font(.body)
                }
                .toggleStyle(.checkbox)
                .onChange(of: caption.correctUsingFluidAudio) { _, enabled in
                    if enabled {
                        Task.detached(priority: .utility) {
                            do {
                                try await FluidAudioBubbleTranscriber.shared.preloadModels()
                            } catch {
                                print("[Caption] FluidAudio preload failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }

                if let err = conversationViewModel.state.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let tErr = caption.translationLastError {
                    Text(tErr)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func menuTitle(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

// MARK: - Section chrome

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            content
        }
        .padding(VoxaPanelStyle.blockPadding)
        .voxaPanelBackground()
    }
}
