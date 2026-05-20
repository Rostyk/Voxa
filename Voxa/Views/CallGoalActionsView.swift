import SwiftUI

/// Action chips shown under a translated callee line (ChatGPT path).
struct CallGoalActionsView: View {
    let actions: [CallGoalAction]
    let speechLocaleIdentifier: String
    @State private var virtualMicStatus = VoxaVirtualMicFeederStatus.shared
    @State private var accessibility = AccessibilityPermission.shared

    private var visibleActions: [CallGoalAction] {
        var seenDTMF = Set<String>()
        return actions.compactMap { action in
            let normalized = CallGoalAction.normalizedForExecution(type: action.type, content: action.content)
            switch normalized.type {
            case .voice:
                return nil
            case .dtmf:
                let digits = CallGoalAction.normalizedDTMFDigits(from: normalized.content)
                let key = digits.isEmpty ? normalized.content : digits
                guard !key.isEmpty, !seenDTMF.contains(key) else { return nil }
                seenDTMF.insert(key)
                return CallGoalAction(type: .dtmf, content: key)
            case .text:
                return CallGoalAction(type: .text, content: normalized.content)
            }
        }
    }

    var body: some View {
        if !visibleActions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let err = virtualMicStatus.lastActionError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 8) {
                    ForEach(visibleActions) { action in
                        actionControl(action)
                    }
                }
            }
            .padding(.top, 4)
            .onAppear {
                accessibility.refresh()
                CallGoalActionLog.logList(visibleActions, context: "CallGoalActionsView appeared")
            }
            .onChange(of: actions) { _, newActions in
                CallGoalActionLog.logList(visibleActions, context: "CallGoalActionsView updated raw=\(newActions.count)")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                accessibility.refresh()
            }
        }
    }

    @ViewBuilder
    private func actionControl(_ action: CallGoalAction) -> some View {
        switch action.type {
        case .dtmf:
            dtmfButton(action)
        case .text:
            Button {
                print("[UI] tap TEXT button chars=\(action.content.count) preview=\"\(String(action.content.prefix(48)))\"")
                CallGoalActionExecutor.perform(action, speechLocaleIdentifier: speechLocaleIdentifier)
            } label: {
                Label {
                    Text(action.content)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .contentShape(Rectangle())
            .help("Speak this phrase into the virtual mic")

        case .voice:
            EmptyView()
        }
    }

    @ViewBuilder
    private func dtmfButton(_ action: CallGoalAction) -> some View {
        let display = CallGoalAction.normalizedDTMFDigits(from: action.content)
        let labelText = display.isEmpty ? action.content : display
        let granted = accessibility.isGranted

        Button {
            if granted {
                print("[UI] tap DTMF button rawContent=\"\(action.content)\" normalized=\"\(labelText)\"")
                CallGoalActionExecutor.perform(action, speechLocaleIdentifier: speechLocaleIdentifier)
            } else {
                print("[UI] tap DTMF button — request Accessibility")
                accessibility.requestGrant()
            }
        } label: {
            Group {
                if granted {
                    Label(labelText, systemImage: "circle.grid.3x3.fill")
                } else {
                    Text(labelText)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 20)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !granted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .padding(.top, granted ? 0 : 4)
            .padding(.trailing, granted ? 0 : 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .contentShape(Rectangle())
        .help(
            granted
                ? "Send DTMF \(labelText) via FaceTime keypad (Accessibility)"
                : "Accessibility required — tap to grant, then Voxa can press FaceTime keypad buttons"
        )
    }
}

/// Simple left-to-right wrap layout for action buttons.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            if current.indices.isEmpty {
                current.width = size.width
            } else {
                current.width += spacing + size.width
            }
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
