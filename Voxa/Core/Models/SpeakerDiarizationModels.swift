import Foundation

/// One “who spoke when” interval from FluidAudio diarization (mapped from `TimedSpeakerSegment`).
struct SpeakerDiarizationSegment: Identifiable, Hashable, Sendable {
    let id: UUID
    let speakerId: String
    let startTimeSeconds: Float
    let endTimeSeconds: Float
    let qualityScore: Float

    var durationSeconds: Float {
        max(0, endTimeSeconds - startTimeSeconds)
    }

    init(
        id: UUID = UUID(),
        speakerId: String,
        startTimeSeconds: Float,
        endTimeSeconds: Float,
        qualityScore: Float
    ) {
        self.id = id
        self.speakerId = speakerId
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.qualityScore = qualityScore
    }

    /// Human-readable label, e.g. `Speaker_1` → `Speaker 1`.
    var displayLabel: String {
        Self.displayLabel(for: speakerId)
    }

    static func displayLabel(for speakerId: String) -> String {
        if speakerId.hasPrefix("Speaker_") {
            let suffix = speakerId.dropFirst("Speaker_".count)
            return "Speaker \(suffix)"
        }
        return speakerId.replacingOccurrences(of: "_", with: " ")
    }
}
