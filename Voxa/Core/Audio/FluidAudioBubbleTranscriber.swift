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
    func transcribe(samples: [Float]) async throws -> FluidBubbleTranscription {
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
            return FluidBubbleTranscription(text: "", tokenTimings: [])
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
        logASRResult(result, audioDurationSec: durationSec)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let timings = Self.mapTokenTimings(result.tokenTimings ?? [])
        print(
            "[FluidAudio] transcribeBubble DONE wall=\(String(format: "%.0f", totalMs))ms asr=\(String(format: "%.0f", asrMs))ms modelReported=\(String(format: "%.0f", result.processingTime * 1000))ms chars=\(text.count) tokenTimings=\(timings.count) rtfx=\(String(format: "%.2f", result.rtfx))"
        )
        return FluidBubbleTranscription(text: text, tokenTimings: timings)
    }

    private static func mapTokenTimings(_ timings: [TokenTiming]) -> [VoxaTokenTiming] {
        timings.map { t in
            VoxaTokenTiming(token: t.token, startTimeSeconds: Float(t.startTime), endTimeSeconds: Float(t.endTime))
        }
    }

    /// Parakeet `ASRResult` is text + optional per-token timings — no speaker / diarization fields.
    /// Speaker labels require FluidAudio's separate `DiarizerManager` / Sortformer path (not wired in Voxa).
    private func logASRResult(_ result: ASRResult, audioDurationSec: Double) {
        let timings = result.tokenTimings ?? []
        print(
            "[FluidAudio] ASRResult fields: textChars=\(result.text.count) confidence=\(String(format: "%.3f", result.confidence)) audioDuration=\(String(format: "%.2f", audioDurationSec))s processingTime=\(String(format: "%.3f", result.processingTime))s tokenTimings=\(timings.count) speakerInfo=none (ASR-only)"
        )
        if !timings.isEmpty {
            let first = timings[0]
            let last = timings[timings.count - 1]
            print(
                "[FluidAudio] ASRResult tokenTimings sample: first='\(Self.tokenPreview(first.token))' @\(String(format: "%.2f", first.startTime))-\(String(format: "%.2f", first.endTime))s last='\(Self.tokenPreview(last.token))' @\(String(format: "%.2f", last.startTime))-\(String(format: "%.2f", last.endTime))s (no speakerId on TokenTiming)"
            )
        }
        if result.ctcDetectedTerms?.isEmpty == false || result.ctcAppliedTerms?.isEmpty == false {
            print(
                "[FluidAudio] ASRResult CTC vocabulary: detected=\(result.ctcDetectedTerms?.count ?? 0) applied=\(result.ctcAppliedTerms?.count ?? 0)"
            )
        }
    }

    private static func tokenPreview(_ token: String, maxLen: Int = 24) -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= maxLen { return t }
        return String(t.prefix(maxLen)) + "…"
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
                "[FluidAudio] AsrManager instance CREATE ts=\(WallClockLog.iso(createdWall)) (Parakeet ASR; diarization via DiarizerManager on commit)"
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
