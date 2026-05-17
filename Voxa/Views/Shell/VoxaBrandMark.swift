import SwiftUI

/// App mark for the window title bar (audio bars + name).
struct VoxaBrandMark: View {
    enum Style {
        case titleBar
        case regular
    }

    var style: Style = .regular

    private var barHeight: CGFloat {
        style == .titleBar ? 14 : 22
    }

    private var titleFont: Font {
        switch style {
        case .titleBar:
            return .system(size: 15, weight: .regular)
        case .regular:
            return .headline.weight(.semibold)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: style == .titleBar ? 7 : 8) {
            AudioBarsIcon(height: barHeight)

            Text("Voxa")
                .font(titleFont)
                .offset(y: style == .titleBar ? 1.5 : 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voxa")
    }
}

/// Simple equalizer-style bars for the title mark.
private struct AudioBarsIcon: View {
    let height: CGFloat
    private let relativeHeights: [CGFloat] = [0.42, 0.72, 0.55, 0.88]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(relativeHeights.enumerated()), id: \.offset) { _, relative in
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: 2.5, height: max(3, height * relative))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
