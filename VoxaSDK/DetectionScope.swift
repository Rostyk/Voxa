import AVFoundation

public enum DetectionScope {
    case all
    case processes([AUAudioProcess])
}
