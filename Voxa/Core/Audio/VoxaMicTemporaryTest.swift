import Foundation

/// TEMPORARY — delete before shipping. Feeds `Audio.wav` from the Voxa repo into the virtual mic.
enum VoxaMicTemporaryTest {
    /// Set to `false` to use the real microphone again.
    static let feedProjectAudioWAV = true

    static var projectAudioWAVURL: URL? {
        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            let url = URL(fileURLWithPath: srcRoot).appendingPathComponent("Audio.wav")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let workspace = URL(fileURLWithPath: "/Users/rostyslav/Work/mac/Voxa/Audio.wav")
        if FileManager.default.fileExists(atPath: workspace.path) { return workspace }
        return nil
    }
}
