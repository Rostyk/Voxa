import AppKit
import SwiftUI

private enum FaceTimeSetupTab: String, CaseIterable, Identifiable {
    case yourMac
    case iPhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yourMac: return "Your Mac"
        case .iPhone: return "iPhone"
        }
    }
}

/// FaceTime setup: Mac automation check + iPhone manual checklist.
struct FaceTimeSettingsSection: View {
    @State private var selectedTab: FaceTimeSetupTab = .yourMac
    @State private var accessibilityPermission = AccessibilityPermission.shared
    @State private var faceTimeCheckResult: FaceTimeSettingsCheckResult?
    @State private var faceTimeCheckRunning = false
    @State private var faceTimeLogExpanded = true
    @State private var faceTimeMicSelecting = false

    var body: some View {
        SettingsSectionCard(title: "FaceTime", systemImage: "video.fill") {
            VStack(alignment: .leading, spacing: 14) {
                FaceTimeSetupTabPicker(selection: $selectedTab)

                switch selectedTab {
                case .yourMac:
                    yourMacTab
                case .iPhone:
                    iPhoneTab
                }
            }
        }
        .onAppear {
            accessibilityPermission.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityPermission.refresh()
        }
    }

    // MARK: - Your Mac

    private var yourMacTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            faceTimeAccessibilityPermissionRow

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    runFaceTimeCheck()
                } label: {
                    if faceTimeCheckRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking FaceTime…")
                        }
                    } else {
                        Label("Check FaceTime setup", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(faceTimeCheckRunning || faceTimeMicSelecting)
            }

            if let faceTimeCheckResult, !faceTimeCheckResult.statusRows.isEmpty {
                FaceTimeCheckResultPanel(
                    result: faceTimeCheckResult,
                    isSelectingVoxaMic: faceTimeMicSelecting,
                    onSelectVoxaMic: accessibilityPermission.isGranted ? { runSelectVoxaMicrophone() } : nil
                )

                DisclosureGroup("Accessibility scan log", isExpanded: $faceTimeLogExpanded) {
                    Text(faceTimeCheckResult.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private var faceTimeAccessibilityPermissionRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(accessibilityPermission.isGranted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility")
                    .font(.subheadline.weight(.medium))
                Text(
                    accessibilityPermission.isGranted
                        ? "Allowed for Voxa — FaceTime check can read menus and settings."
                        : "Not allowed for Voxa — enable in Privacy & Security → Accessibility."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !accessibilityPermission.isGranted {
                Button("Open Settings") {
                    accessibilityPermission.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    accessibilityPermission.isGranted
                        ? Color.green.opacity(0.08)
                        : Color.orange.opacity(0.08)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    accessibilityPermission.isGranted
                        ? Color.green.opacity(0.2)
                        : Color.orange.opacity(0.25),
                    lineWidth: 1
                )
        }
    }

    // MARK: - iPhone

    private var iPhoneTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            iPhoneGuideCard(
                title: "FaceTime app settings",
                systemImage: "video.fill",
                intro: "On your iPhone, sign in to FaceTime with the same Apple ID you use on this Mac.",
                settingsPath: "Settings → Apps → FaceTime",
                checklistTitle: "Under “You can be reached by FaceTime at”",
                checklistItems: [
                    "Your Apple ID shows a checkmark.",
                    "Your phone number shows a checkmark.",
                ],
                footer: "If either item is missing a checkmark, tap that row and turn it on.",
                screenshotAssetNames: ["facetime1", "facetime2"]
            )

            iPhoneGuideCard(
                title: "Phone app settings",
                systemImage: "phone.fill",
                intro: "Allow calls from your iPhone to ring on this Mac.",
                settingsPath: "Settings → Apps → Phone → Calls on Other Devices",
                checklistTitle: "On that screen",
                checklistItems: [
                    "Turn on “Allow Calls on Other Devices”.",
                    "Turn on the switch next to this Mac’s name.",
                ],
                footer: nil,
                screenshotAssetNames: ["phone1"]
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func runSelectVoxaMicrophone() {
        accessibilityPermission.refresh()
        guard accessibilityPermission.isGranted else { return }

        faceTimeMicSelecting = true
        faceTimeLogExpanded = true
        let axGranted = accessibilityPermission.isGranted
        Task {
            let outcome = await FaceTimeSettingsInspector.selectVoxaVirtualMicrophone(accessibilityGranted: axGranted)
            await MainActor.run {
                faceTimeMicSelecting = false
                activateVoxa()

                if var result = faceTimeCheckResult {
                    result.logLines.append(contentsOf: outcome.logLines)
                    if let mic = outcome.selectedMicrophone {
                        result.faceTimeSelectedMicrophone = mic
                        result.voxaMicSelectedInFaceTime = outcome.success
                    }
                    faceTimeCheckResult = FaceTimeSettingsInspector.resultWithRefreshedStatusRows(result)
                }
            }
        }
    }

    private func runFaceTimeCheck() {
        accessibilityPermission.refresh()
        if !accessibilityPermission.isGranted {
            accessibilityPermission.requestGrant()
            accessibilityPermission.refresh()
        }
        faceTimeCheckRunning = true
        faceTimeLogExpanded = true
        let axGranted = accessibilityPermission.isGranted
        Task {
            let result = await FaceTimeSettingsInspector.runCheck(accessibilityGranted: axGranted)
            await MainActor.run {
                accessibilityPermission.refresh()
                faceTimeCheckResult = result
                faceTimeCheckRunning = false
                activateVoxa()
            }
        }
    }

    private func activateVoxa() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }
}

// MARK: - Tab picker

private struct FaceTimeSetupTabPicker: View {
    @Binding var selection: FaceTimeSetupTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FaceTimeSetupTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.plain)
                .background {
                    if selection == tab {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    }
                }
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - iPhone guide card

private struct iPhoneGuideCard: View {
    let title: String
    let systemImage: String
    let intro: String
    let settingsPath: String
    let checklistTitle: String
    let checklistItems: [String]
    let footer: String?
    var screenshotAssetNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))

            Text(intro)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(settingsPath)
                    .font(.caption.weight(.medium))
            }

            Text(checklistTitle)
                .font(.caption.weight(.semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(checklistItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !screenshotAssetNames.isEmpty {
                iPhoneScreenshotStrip(assetNames: screenshotAssetNames)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }
}

/// Portrait phone screenshots from asset catalog (taller than wide).
private struct iPhoneScreenshotStrip: View {
    let assetNames: [String]

    private let phoneWidth: CGFloat = 152

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(assetNames, id: \.self) { name in
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: phoneWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}
