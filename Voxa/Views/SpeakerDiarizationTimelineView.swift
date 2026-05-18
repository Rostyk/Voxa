import SwiftUI

/// Compact timeline + legend for one bubble’s diarization segments.
struct SpeakerDiarizationTimelineView: View {
    let segments: [SpeakerDiarizationSegment]

    private var orderedSpeakerIDs: [String] {
        SpeakerTranscriptColorizer.orderedUniqueSpeakerIDs(from: segments)
    }

    private var timelineDurationSeconds: Float {
        max(segments.map(\.endTimeSeconds).max() ?? 0, 0.01)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speakers (FluidAudio)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                    ForEach(segments) { segment in
                        segmentBar(segment, in: geo.size)
                    }
                }
            }
            .frame(height: 10)

            ForEach(orderedSpeakerIDs, id: \.self) { speakerID in
                legendRow(speakerID: speakerID)
            }
        }
    }

    private func segmentBar(_ segment: SpeakerDiarizationSegment, in size: CGSize) -> some View {
        let total = CGFloat(timelineDurationSeconds)
        let x = size.width * CGFloat(segment.startTimeSeconds / Float(total))
        let width = max(size.width * CGFloat(segment.durationSeconds / Float(total)), 2)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                SpeakerDiarizationPalette.barColor(
                    for: segment.speakerId,
                    orderedIDs: orderedSpeakerIDs
                )
            )
            .frame(width: width, height: size.height)
            .offset(x: x)
    }

    private func legendRow(speakerID: String) -> some View {
        let label = SpeakerDiarizationSegment.displayLabel(for: speakerID)
        let talkSeconds = segments
            .filter { $0.speakerId == speakerID }
            .reduce(0) { $0 + $1.durationSeconds }
        return HStack(spacing: 6) {
            Circle()
                .fill(SpeakerDiarizationPalette.barColor(for: speakerID, orderedIDs: orderedSpeakerIDs))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text("· \(String(format: "%.1f", talkSeconds))s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }
}
