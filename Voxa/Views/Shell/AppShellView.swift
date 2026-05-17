import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case liveCall
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveCall: return "Live call"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .liveCall: return "phone.fill"
        case .history: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct AppShellView: View {
    let callViewModel: CallViewModel
    let conversationViewModel: ConversationViewModel

    @State private var selection: AppSection = .liveCall

    /// Red live-call indicator while we are capturing (not when sidebar should hide).
    private var isLiveCallActive: Bool {
        callViewModel.isRecording
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn

            Divider()
                .overlay(VoxaColors.panelStroke)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(VoxaPanelStyle.blockPadding)
        }
        .voxaShellBackground()
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    SidebarNavRow(
                        section: section,
                        isSelected: selection == section,
                        liveCallActive: isLiveCallActive
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(width: VoxaPanelStyle.sidebarWidth)
        .voxaShellBackground()
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .liveCall:
            LiveCallView(
                callViewModel: callViewModel,
                conversationViewModel: conversationViewModel
            )
        case .history:
            HistoryPlaceholderView()
        case .settings:
            SettingsView(conversationViewModel: conversationViewModel)
        }
    }
}

private struct SidebarNavRow: View {
    let section: AppSection
    let isSelected: Bool
    let liveCallActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 22)

                Text(section.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(labelColor)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VoxaColors.sidebarSelection : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        if section == .liveCall {
            return liveCallActive ? .red : .secondary
        }
        return .secondary
    }

    private var labelColor: Color {
        if section == .liveCall, liveCallActive {
            return .primary
        }
        return isSelected ? .primary : .secondary
    }
}
