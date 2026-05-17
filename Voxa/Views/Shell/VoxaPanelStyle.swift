import SwiftUI

enum VoxaPanelStyle {
    static let cornerRadius: CGFloat = 14
    static let blockPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let sidebarWidth: CGFloat = 220
}

/// Shared window chrome — one background for sidebar + content so the shell does not look patchy.
enum VoxaColors {
    static var shell: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var panelFill: Color {
        Color.primary.opacity(0.045)
    }

    static var panelStroke: Color {
        Color.primary.opacity(0.08)
    }

    static var sidebarSelection: Color {
        Color.primary.opacity(0.07)
    }
}

extension View {
    func voxaShellBackground() -> some View {
        background(VoxaColors.shell)
    }

    func voxaPanelBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: VoxaPanelStyle.cornerRadius, style: .continuous)
                .fill(VoxaColors.panelFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: VoxaPanelStyle.cornerRadius, style: .continuous)
                .strokeBorder(VoxaColors.panelStroke, lineWidth: 1)
        }
    }
}
