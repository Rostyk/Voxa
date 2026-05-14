import Foundation

public enum AUAudioError: LocalizedError {
    case processTapCreationFailed(String)
    case aggregateDeviceCreationFailed(String)
    case tapNotActivated
    case invalidStreamDescription
    case failedToCreatePCMBuffer
    case failedToCreateAudioFormat
    case noTapAvailable
    case tapAlreadyRunning
    case deviceIOProcCreationFailed(String)
    case deviceStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .processTapCreationFailed(let message):
            return "Failed to create process tap: \(message)"
        case .aggregateDeviceCreationFailed(let message):
            return "Failed to create aggregate device: \(message)"
        case .tapNotActivated:
            return "Tap has not been activated"
        case .invalidStreamDescription:
            return "Tap stream description is not available"
        case .failedToCreatePCMBuffer:
            return "Failed to create PCM buffer"
        case .failedToCreateAudioFormat:
            return "Failed to create AVAudio format"
        case .noTapAvailable:
            return "No tap available for this process"
        case .tapAlreadyRunning:
            return "Tap is already running"
        case .deviceIOProcCreationFailed(let message):
            return "Failed to create device I/O proc: \(message)"
        case .deviceStartFailed(let message):
            return "Failed to start audio device: \(message)"
        }
    }
}
