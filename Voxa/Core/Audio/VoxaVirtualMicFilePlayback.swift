import AVFoundation
import Foundation

enum VoxaVirtualMicFilePlaybackError: LocalizedError {
    case recordingNotFound(searched: [String])

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let searched):
            return "recording.wav not found. Tried:\n" + searched.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

/// Plays a WAV/AIFF file into the virtual-mic ring (real-time paced).
enum VoxaVirtualMicFilePlayback {
    private static let recordingBaseName = "recording"

    static func recordingWAVURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: recordingBaseName, withExtension: "wav") {
            return bundled
        }
        let atRepoRoot = VoxaProjectPaths.fileInRepoRoot("\(recordingBaseName).wav")
        if FileManager.default.fileExists(atPath: atRepoRoot.path) {
            return atRepoRoot
        }
        if let envRoot = ProcessInfo.processInfo.environment["VOXA_ROOT"] {
            let envURL = URL(fileURLWithPath: envRoot).appendingPathComponent("\(recordingBaseName).wav")
            if FileManager.default.fileExists(atPath: envURL.path) {
                return envURL
            }
        }
        return nil
    }

    static func searchedRecordingPaths() -> [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.url(forResource: recordingBaseName, withExtension: "wav") {
            paths.append(bundled.path)
        }
        paths.append(VoxaProjectPaths.fileInRepoRoot("\(recordingBaseName).wav").path)
        if let envRoot = ProcessInfo.processInfo.environment["VOXA_ROOT"] {
            paths.append(URL(fileURLWithPath: envRoot).appendingPathComponent("\(recordingBaseName).wav").path)
        }
        return paths
    }

    static func enqueuePlayRecordingWAV(onComplete: @escaping @Sendable (Error?) -> Void) {
        guard let url = recordingWAVURL() else {
            let error = VoxaVirtualMicFilePlaybackError.recordingNotFound(searched: searchedRecordingPaths())
            DispatchQueue.main.async { onComplete(error) }
            return
        }
        print("[VoxaMic] playRecordingWAV path=\(url.path)")
        enqueuePlay(url: url, onComplete: onComplete)
    }

    static func enqueuePlay(url: URL, onComplete: @escaping @Sendable (Error?) -> Void) {
        VoxaVirtualMicPlaybackExecutor.dispatch {
            do {
                try playOnPlaybackQueue(url: url)
                DispatchQueue.main.async { onComplete(nil) }
            } catch {
                DispatchQueue.main.async { onComplete(error) }
            }
        }
    }

    /// Must run on `VoxaVirtualMicPlaybackExecutor.queue` only.
    private static func playOnPlaybackQueue(url: URL) throws {
        VoxaVirtualMicPlaybackExecutor.assertNotOnMainThread("playOnPlaybackQueue")

        VoxaVirtualMicFeeder.shared.startIfNeeded()
        guard let ringFormat = VoxaMicPCMFileLoader.ringFormat else {
            throw VoxaMicPCMFileLoader.Error.ringFormatUnavailable
        }

        let buffer = try VoxaMicPCMFileLoader.loadAndConvert(url: url, targetFormat: ringFormat)
        let durationMs = Double(buffer.frameLength) / ringFormat.sampleRate * 1000
        print(
            "[VoxaMic] file playback START \(url.lastPathComponent) frames=\(buffer.frameLength) " +
                "≈\(String(format: "%.0f", durationMs))ms paceRealtime=true"
        )

        try VoxaVirtualMicFeeder.shared.performRingInjectionSync { ring in
            try VoxaMicRingPCMStreamer.streamBuffer(
                buffer,
                to: ring,
                logLabel: url.lastPathComponent,
                options: .virtualMicPlayback
            )
        }

        print("[VoxaMic] file playback SUCCESS \(url.lastPathComponent)")
    }
}
