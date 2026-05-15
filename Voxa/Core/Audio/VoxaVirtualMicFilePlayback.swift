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

    static func playRecordingWAV() async throws {
        guard let url = recordingWAVURL() else {
            throw VoxaVirtualMicFilePlaybackError.recordingNotFound(searched: searchedRecordingPaths())
        }
        print("[VoxaMic] playRecordingWAV path=\(url.path)")
        try await play(url: url)
    }

    static func play(url: URL) async throws {
        try await VoxaVirtualMicPlaybackExecutor.run {
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

            try await VoxaVirtualMicFeeder.shared.performRingInjection { ring in
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
}
