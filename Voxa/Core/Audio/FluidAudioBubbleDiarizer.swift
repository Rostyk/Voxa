import FluidAudio
import Foundation

/// Per-bubble speaker diarization via FluidAudio `DiarizerManager` (16 kHz mono, batch chunk pipeline).
actor FluidAudioBubbleDiarizer {

    static let shared = FluidAudioBubbleDiarizer()

    private static let sampleRate = 16_000
  /// ~3 s minimum — below this the segmentation model is unreliable.
    private static let minimumSamples = sampleRate * 3

    /// Exposed for live probes (same threshold as committed bubbles).
    static var minimumSamplesForProbe: Int { minimumSamples }

    private var diarizer: DiarizerManager?
    private var modelsPrepared = false
    private var loadInFlight: Task<Void, Error>?

    private init() {}

    func preloadModels() async throws {
        try await ensureDiarizerReady()
    }

    enum Pass: Sendable {
        case liveProbe
        case committedBubble
    }

    /// Returns speaker segments for the bubble audio, or `[]` if audio is too short.
    func diarize(samples: [Float], pass: Pass = .committedBubble) async throws -> [SpeakerDiarizationSegment] {
        let logTag = pass == .liveProbe ? "[FluidAudio][Diarizer][Live]" : "[FluidAudio][Diarizer]"
        let durationSec = Double(samples.count) / Double(Self.sampleRate)
        print(
            "\(logTag) diarize START pass=\(pass) samples=\(samples.count) ≈\(String(format: "%.2f", durationSec))s"
        )

        guard samples.count >= Self.minimumSamples else {
            print(
                "\(logTag) diarize SKIP — audio shorter than minimum (\(samples.count) < \(Self.minimumSamples))"
            )
            return []
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        let manager = try await ensureDiarizerReady()
        let result = try await manager.performCompleteDiarization(samples, sampleRate: Self.sampleRate)
        let mapped = Self.mapSegments(result.segments)
        let wallMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000

        logDiarizationResult(
            logTag: logTag,
            result: result,
            mapped: mapped,
            durationSec: durationSec,
            wallMs: wallMs
        )

        return mapped
    }

    private func ensureDiarizerReady() async throws -> DiarizerManager {
        if modelsPrepared, let diarizer {
            return diarizer
        }
        if let loadInFlight {
            try await loadInFlight.value
            guard let diarizer, modelsPrepared else {
                throw FluidAudioBubbleDiarizerError.modelsUnavailable
            }
            return diarizer
        }

        let task = Task<Void, Error> {
            let loadWall = CFAbsoluteTimeGetCurrent()
            print("[FluidAudio][Diarizer] DiarizerModels.downloadIfNeeded START")
            let models = try await DiarizerModels.downloadIfNeeded()
            let loadMs = (CFAbsoluteTimeGetCurrent() - loadWall) * 1000
            print(
                "[FluidAudio][Diarizer] DiarizerModels.downloadIfNeeded DONE wall=\(String(format: "%.0f", loadMs))ms"
            )

            var config = DiarizerConfig.default
            config.chunkDuration = 10
            config.chunkOverlap = 0
            config.minSpeechDuration = 0.8
            config.minSilenceGap = 0.4
            config.debugMode = false

            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            self.diarizer = manager
            self.modelsPrepared = true
            print(
                "[FluidAudio][Diarizer] DiarizerManager initialized chunkDuration=\(config.chunkDuration)s minSpeech=\(config.minSpeechDuration)s"
            )
        }
        loadInFlight = task
        defer { loadInFlight = nil }
        try await task.value
        guard let diarizer else {
            throw FluidAudioBubbleDiarizerError.modelsUnavailable
        }
        return diarizer
    }

    private static func mapSegments(_ segments: [TimedSpeakerSegment]) -> [SpeakerDiarizationSegment] {
        segments.map { seg in
            SpeakerDiarizationSegment(
                speakerId: seg.speakerId,
                startTimeSeconds: seg.startTimeSeconds,
                endTimeSeconds: seg.endTimeSeconds,
                qualityScore: seg.qualityScore
            )
        }
    }

    private func logDiarizationResult(
        logTag: String,
        result: DiarizationResult,
        mapped: [SpeakerDiarizationSegment],
        durationSec: Double,
        wallMs: Double
    ) {
        let uniqueSpeakers = Set(mapped.map(\.speakerId))
        print(
            "\(logTag) diarize DONE wall=\(String(format: "%.0f", wallMs))ms segments=\(mapped.count) uniqueSpeakers=\(uniqueSpeakers.count) audio≈\(String(format: "%.2f", durationSec))s"
        )

        if let timings = result.timings {
            print(
                "\(logTag) pipeline timings total=\(String(format: "%.2f", timings.totalProcessingSeconds))s segmentation=\(String(format: "%.2f", timings.segmentationSeconds))s embedding=\(String(format: "%.2f", timings.embeddingExtractionSeconds))s clustering=\(String(format: "%.2f", timings.speakerClusteringSeconds))s"
            )
        }

        for (index, seg) in mapped.prefix(12).enumerated() {
            print(
                "\(logTag)   segment[\(index)] \(seg.displayLabel) \(String(format: "%.2f", seg.startTimeSeconds))–\(String(format: "%.2f", seg.endTimeSeconds))s quality=\(String(format: "%.2f", seg.qualityScore))"
            )
        }
        if mapped.count > 12 {
            print("\(logTag)   … +\(mapped.count - 12) more segments")
        }
        if mapped.isEmpty {
            print("\(logTag)   (no speech segments detected)")
        }
    }
}

enum FluidAudioBubbleDiarizerError: LocalizedError {
    case modelsUnavailable

    var errorDescription: String? {
        switch self {
        case .modelsUnavailable:
            return "FluidAudio diarization models are not loaded."
        }
    }
}
