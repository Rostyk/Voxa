import SwiftUI

/// Transcript with soft per-speaker background fills (no timeline bar).
struct SpeakerColoredTranscriptText: View {
    let spans: [SpeakerColoredSpan]

    private var orderedSpeakerIDs: [String] {
        Array(Set(spans.compactMap(\.speakerId))).sorted()
    }

    var body: some View {
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            run.foregroundColor = .secondary
            if let speakerId = span.speakerId {
                run.backgroundColor = SpeakerDiarizationPalette.backgroundColor(
                    for: speakerId,
                    orderedIDs: orderedSpeakerIDs
                )
            }
            result.append(run)
        }
        return result
    }
}

enum SpeakerDiarizationPalette {
    private static let base: [(r: Double, g: Double, b: Double)] = [
        (0.23, 0.43, 0.61),
        (0.85, 0.45, 0.18),
        (0.28, 0.62, 0.42),
        (0.55, 0.36, 0.72),
        (0.78, 0.32, 0.48),
        (0.20, 0.58, 0.62),
    ]

    static func backgroundColor(for speakerID: String, orderedIDs: [String]) -> Color {
        let index = orderedIDs.firstIndex(of: speakerID) ?? 0
        let c = base[index % base.count]
        return Color(red: c.r, green: c.g, blue: c.b).opacity(0.22)
    }

    static func barColor(for speakerID: String, orderedIDs: [String]) -> Color {
        let index = orderedIDs.firstIndex(of: speakerID) ?? 0
        let c = base[index % base.count]
        return Color(red: c.r, green: c.g, blue: c.b).opacity(0.85)
    }
}
