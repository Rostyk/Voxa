import Foundation

enum VoxaVirtualMicFeederError: LocalizedError {
    case ringUnavailable
    case playbackCancelled

    var errorDescription: String? {
        switch self {
        case .ringUnavailable:
            return "Virtual microphone ring buffer is not available."
        case .playbackCancelled:
            return "Virtual microphone playback was cancelled."
        }
    }
}
