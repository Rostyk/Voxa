import FluidAudio
import Foundation

/// One-shot Parakeet transcription for a single committed bubble (fresh decoder state per call).
actor FluidAudioBubbleTranscriber {

    static let shared = FluidAudioBubbleTranscriber()

    private var asrManager: AsrManager?
    private var modelsLoadWallStart: CFAbsoluteTime = 0
    private var modelsLoaded = false
    private var loadInFlight: Task<Void, Error>?

    private init() {}

    /// Pre-warm Core ML models (downloads on first launch). Safe to call from a background task.
    func preloadModels() async throws {
        try await ensureModelsLoaded()
    }

    /// Transcribes pre-resampled 16 kHz mono bubble audio. Each call uses a new `TdtDecoderState` (no cross-bubble context).
    func transcribe(samples: [Float]) async throws -> String {
        let wallStart = CFAbsoluteTimeGetCurrent()
        let durationSec = Double(samples.count) / 16_000.0
        print(
            "[FluidAudio] transcribeBubble START ts=\(WallClockLog.iso(wallStart)) samples=\(samples.count) ≈\(String(format: "%.2f", durationSec))s"
        )

        let manager = try await loadedManager()

        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        guard samples.count >= minimum else {
            print(
                "[FluidAudio] transcribeBubble SKIP — audio shorter than minimum (\(samples.count) < \(minimum))"
            )
            return ""
        }

        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let asrWall = CFAbsoluteTimeGetCurrent()
        print(
            "[FluidAudio] transcribeBubble AsrManager.transcribe START ts=\(WallClockLog.iso(asrWall)) (fresh decoder state)"
        )
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let asrMs = (CFAbsoluteTimeGetCurrent() - asrWall) * 1000
        let totalMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        print(
            "[FluidAudio] transcribeBubble DONE wall=\(String(format: "%.0f", totalMs))ms asr=\(String(format: "%.0f", asrMs))ms modelReported=\(String(format: "%.0f", result.processingTime * 1000))ms chars=\(text.count) rtfx=\(String(format: "%.2f", result.rtfx))"
        )
        return text
    }

    private func loadedManager() async throws -> AsrManager {
        try await ensureModelsLoaded()
        guard let manager = asrManager else {
            throw FluidAudioBubbleTranscriberError.modelsUnavailable
        }
        return manager
    }

    private func ensureModelsLoaded() async throws {
        if modelsLoaded, asrManager != nil { return }
        if let loadInFlight {
            try await loadInFlight.value
            return
        }

        let task = Task<Void, Error> {
            let createdWall = CFAbsoluteTimeGetCurrent()
            print(
                "[FluidAudio] AsrManager instance CREATE ts=\(WallClockLog.iso(createdWall)) (shared singleton)"
            )
            let manager = AsrManager()
            self.asrManager = manager
            self.modelsLoadWallStart = CFAbsoluteTimeGetCurrent()
            print(
                "[FluidAudio] AsrModels.downloadAndLoad START ts=\(WallClockLog.iso(self.modelsLoadWallStart))"
            )
            let models = try await AsrModels.downloadAndLoad()
            try await manager.loadModels(models)
            let loadMs = (CFAbsoluteTimeGetCurrent() - self.modelsLoadWallStart) * 1000
            self.modelsLoaded = true
            print(
                "[FluidAudio] AsrModels.downloadAndLoad DONE wall=\(String(format: "%.0f", loadMs))ms"
            )
        }
        loadInFlight = task
        defer { loadInFlight = nil }
        try await task.value
    }
}

enum FluidAudioBubbleTranscriberError: LocalizedError {
    case modelsUnavailable

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            return "FluidAudio models are not loaded."
        }
    }
}

// MARK: - Wall-clock timestamps

private enum WallClockLog {
    private static let lock = NSLock()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ absoluteTime: CFAbsoluteTime) -> String {
        lock.lock()
        defer { lock.unlock() }
        return iso8601Fractional.string(from: Date(timeIntervalSinceReferenceDate: absoluteTime))
    }
}
