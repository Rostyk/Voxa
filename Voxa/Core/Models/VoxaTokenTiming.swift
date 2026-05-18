import Foundation

/// Per-token timing from FluidAudio Parakeet (used to color transcript by diarization time).
struct VoxaTokenTiming: Hashable, Sendable {
    let token: String
    let startTimeSeconds: Float
    let endTimeSeconds: Float
}

struct FluidBubbleTranscription: Sendable {
    let text: String
    let tokenTimings: [VoxaTokenTiming]
}
