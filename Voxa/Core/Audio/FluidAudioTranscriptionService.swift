import AVFoundation
import FluidAudio
import Foundation

/// Sliding-window Parakeet TDT: first pass needs **`chunk + right`** seconds of audio, then advances by **`chunk`**.
/// Total window **`left + chunk + right`** must stay **≤ ~15 s** (`audio_signal` / `ASRConstants.maxModelSamples`).
/// ~5 s chunks reduce boundary token churn vs 2 s (fewer “missing middle” phrases) at the cost of ~6 s to first text.
private let captionSlidingWindowAsr = SlidingWindowAsrConfig(
    chunkSeconds: 5.0,
    hypothesisChunkSeconds: 1.0,
    leftContextSeconds: 4.0,
    rightContextSeconds: 1.25,
    minContextForConfirmation: 4.0,
    confirmationThreshold: 0.78
)

/// Live captions using FluidAudio **SlidingWindowAsrManager** (Parakeet TDT) and **LSEENDDiarizer** streaming LS-EEND,
/// per public APIs in the FluidAudio package (`streamAudio`, `transcriptionUpdates`, `addAudio` / `process`).
actor FluidAudioTranscriptionService {

    private var asr: SlidingWindowAsrManager?
    private var diarizer: LSEENDDiarizer?
    private let audioConverter = AudioConverter()

    private var onPartial: (@Sendable (String) -> Void)?
    private var onCommit: (@Sendable (String, String) -> Void)?
    private var onEnergy: (@Sendable (Bool) -> Void)?

    private var transcriptPumpTask: Task<Void, Never>?
    private var silenceMonitorTask: Task<Void, Never>?
    /// FIFO tap → ASR: unstructured `Task { await append }` from the recorder reorders across `await`
    /// (actors are reentrant), which shuffles `streamAudio` and drops/garbles words between windows.
    private var ingestContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var ingestTask: Task<Void, Never>?

    private var isRunning = false
    private var lastLoudAt = CFAbsoluteTimeGetCurrent()
    private var lastTranscriptChangeAt = CFAbsoluteTimeGetCurrent()
    private var lastEmittedTranscript = ""
    private var totalSamples: Int64 = 0
    private var postCommitCooldownUntil: CFAbsoluteTime = 0

    private var appendLogCount: Int = 0
    private var silenceTickCount: Int = 0
    private var transcriptUpdateCount: Int = 0

    private let pauseToCommit: TimeInterval
    private let minAudioSilence: TimeInterval
    private let rmsThreshold: Float

    init(
        pauseToCommit: TimeInterval = 1.0,
        minAudioSilence: TimeInterval = 0.55,
        rmsSpeakingThreshold: Float = 0.014
    ) {
        self.pauseToCommit = pauseToCommit
        self.minAudioSilence = minAudioSilence
        self.rmsThreshold = rmsSpeakingThreshold
    }

    func start(
        onPartial: @escaping @Sendable (String) -> Void,
        onCommit: @escaping @Sendable (String, String) -> Void,
        onEnergy: @escaping @Sendable (Bool) -> Void
    ) async throws {
        print("[FluidAudioTranscriptionService] start() enter → await stop()")
        await stop()
        self.onPartial = onPartial
        self.onCommit = onCommit
        self.onEnergy = onEnergy

        let (ingestStream, ingestCont) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .unbounded
        )
        ingestContinuation = ingestCont
        ingestTask = Task {
            for await buffer in ingestStream {
                await self.processIngestedBuffer(buffer)
            }
        }

        // Parakeet preprocessor `audio_signal` ≤ ~240_000 samples (~15 s @ 16 kHz). Keep left+chunk+right under that.
        print(
            "[FluidAudioTranscriptionService] API SlidingWindowAsrManager chunk=\(captionSlidingWindowAsr.chunkSeconds)s left=\(captionSlidingWindowAsr.leftContextSeconds)s right=\(captionSlidingWindowAsr.rightContextSeconds)s → first pass ≈ \(captionSlidingWindowAsr.chunkSeconds + captionSlidingWindowAsr.rightContextSeconds)s audio (FIFO ingest stream)"
        )
        let asrManager = SlidingWindowAsrManager(config: captionSlidingWindowAsr)

        let t0 = CFAbsoluteTimeGetCurrent()
        print("[FluidAudioTranscriptionService] API try await asrManager.loadModels() …")
        try await asrManager.loadModels()
        print(
            "[FluidAudioTranscriptionService] API loadModels() ok elapsed=\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s"
        )

        let t1 = CFAbsoluteTimeGetCurrent()
        print("[FluidAudioTranscriptionService] API try await asrManager.startStreaming(source: .microphone) …")
        try await asrManager.startStreaming(source: .microphone)
        print(
            "[FluidAudioTranscriptionService] API startStreaming() ok elapsed=\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t1))s"
        )

        // Turn on taps **before** LS-EEND downloads — otherwise `append` drops buffers for minutes and UI never transcribes.
        self.asr = asrManager
        self.diarizer = nil
        isRunning = true
        lastLoudAt = CFAbsoluteTimeGetCurrent()
        lastTranscriptChangeAt = lastLoudAt
        lastEmittedTranscript = ""
        totalSamples = 0
        appendLogCount = 0
        silenceTickCount = 0
        transcriptUpdateCount = 0

        print("[FluidAudioTranscriptionService] beginTranscriptPump + beginSilenceMonitor (subscribes to transcriptionUpdates)")
        beginTranscriptPump(asrManager: asrManager, onPartial: onPartial)
        beginSilenceMonitor()

        print(
            "[FluidAudioTranscriptionService] ASR streaming live (Parakeet); API try await LSEENDDiarizer(variant: .dihard3) …"
        )

        let t2 = CFAbsoluteTimeGetCurrent()
        do {
            let dia = try await LSEENDDiarizer(variant: .dihard3)
            self.diarizer = dia
            print(
                "[FluidAudioTranscriptionService] API LSEENDDiarizer ready elapsed=\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t2))s"
            )
        } catch {
            self.diarizer = nil
            print(
                "[FluidAudioTranscriptionService] API LSEENDDiarizer FAILED after \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t2))s: \(error.localizedDescription)"
            )
        }

        print("[FluidAudioTranscriptionService] start() exit isRunning=true append→streamAudio(buffer) diarizer→process(samples:16000)")
    }

    func stop() async {
        print(
            "[FluidAudioTranscriptionService] stop() enter isRunning=\(isRunning) asr=\(asr != nil) pump=\(transcriptPumpTask != nil) ingest=\(ingestTask != nil)"
        )
        isRunning = false
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        transcriptPumpTask?.cancel()
        transcriptPumpTask = nil

        ingestContinuation?.finish()
        ingestContinuation = nil
        await ingestTask?.value
        ingestTask = nil

        if let asrManager = asr {
            print("[FluidAudioTranscriptionService] API await asrManager.cancel() …")
            await asrManager.cancel()
            print("[FluidAudioTranscriptionService] API asrManager.cancel() returned")
        }
        asr = nil
        diarizer = nil

        onPartial = nil
        onCommit = nil
        onEnergy = nil
        print("[FluidAudioTranscriptionService] stop() exit")
    }

    /// Tap callback may use unstructured `Task { await … }`; **never** `await streamAudio` from here — only enqueue
    /// so buffers stay strictly FIFO (see `processIngestedBuffer`).
    func append(_ buffer: AVAudioPCMBuffer) async {
        guard let cont = ingestContinuation else {
            if appendLogCount < 4 {
                appendLogCount += 1
                print(
                    "[FluidAudioTranscriptionService] append dropped (ingest finished) frames=\(buffer.frameLength)"
                )
            }
            return
        }
        guard let copy = Self.copyPCMBuffer(buffer) else {
            print(
                "[FluidAudioTranscriptionService] append copyPCMBuffer FAILED format=\(Self.formatSignature(buffer.format)) frames=\(buffer.frameLength)"
            )
            return
        }
        cont.yield(copy)
    }

    private func processIngestedBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard let asrManager = asr else { return }

        let fmt = Self.formatSignature(buffer.format)
        let samples16k: [Float]
        do {
            samples16k = try audioConverter.resampleBuffer(buffer)
        } catch {
            print(
                "[FluidAudioTranscriptionService] API AudioConverter.resampleBuffer FAILED format=\(fmt) frames=\(buffer.frameLength) err=\(error.localizedDescription)"
            )
            return
        }

        let rms = Self.monoRMSSamples(samples16k)
        let speaking = rms > rmsThreshold
        onEnergy?(speaking)
        if speaking {
            lastLoudAt = CFAbsoluteTimeGetCurrent()
        }

        appendLogCount += 1
        let sec = Double(totalSamples + Int64(samples16k.count)) / 16_000.0
        if appendLogCount <= 5 || appendLogCount % 200 == 0 {
            print(
                "[FluidAudioTranscriptionService] FIFO process #\(appendLogCount) inFmt=\(fmt) inFrames=\(buffer.frameLength) →16kSamples=\(samples16k.count) rms16k=\(String(format: "%.5f", rms)) speaking=\(speaking) totalAudio≈\(String(format: "%.2f", sec))s → await streamAudio(copy)"
            )
        }

        await asrManager.streamAudio(buffer)

        if let dia = diarizer {
            do {
                let upd = try dia.process(samples: samples16k, sourceSampleRate: 16_000)
                if appendLogCount <= 5 || appendLogCount % 200 == 0 {
                    let f = upd?.finalizedSegments.count ?? 0
                    let t = upd?.tentativeSegments.count ?? 0
                    print(
                        "[FluidAudioTranscriptionService] API diarizer.process(samples:16kHz) update finalizedSeg=\(f) tentativeSeg=\(t)"
                    )
                }
            } catch {
                print(
                    "[FluidAudioTranscriptionService] API diarizer.process FAILED: \(error.localizedDescription)"
                )
            }
        } else if appendLogCount <= 5 {
            print("[FluidAudioTranscriptionService] diarizer nil — skip process()")
        }

        totalSamples += Int64(samples16k.count)
    }

    // MARK: - Private

    private func beginTranscriptPump(
        asrManager: SlidingWindowAsrManager,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        transcriptPumpTask?.cancel()
        transcriptPumpTask = Task { [weak self] in
            print("[FluidAudioTranscriptionService] transcriptPump: acquiring asrManager.transcriptionUpdates AsyncStream …")
            let stream = await asrManager.transcriptionUpdates
            print("[FluidAudioTranscriptionService] transcriptPump: for-await loop started")
            for await update in stream {
                guard !Task.isCancelled else {
                    print("[FluidAudioTranscriptionService] transcriptPump: cancelled, exiting loop")
                    break
                }
                transcriptUpdateCount += 1
                let confirmed = await asrManager.confirmedTranscript
                let volatile = await asrManager.volatileTranscript
                let live = [confirmed, volatile]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let preview = Self.logPreview(live, maxLen: 72)
                if transcriptUpdateCount <= 20 || transcriptUpdateCount % 25 == 0 || !live.isEmpty {
                    print(
                        "[FluidAudioTranscriptionService] API transcriptionUpdates #\(transcriptUpdateCount) chunkChars=\(update.text.count) isConfirmed=\(update.isConfirmed) conf=\(String(format: "%.3f", update.confidence)) tokenTimings=\(update.tokenTimings.count) mergedLiveChars=\(live.count) \(preview)"
                    )
                }
                let now = CFAbsoluteTimeGetCurrent()
                await self?.noteTranscriptEmitted(live, at: now)
                onPartial(live)
            }
            print("[FluidAudioTranscriptionService] transcriptPump: AsyncStream finished (no more yields)")
        }
    }

    private func noteTranscriptEmitted(_ text: String, at time: CFAbsoluteTime) {
        if text != lastEmittedTranscript {
            lastEmittedTranscript = text
            lastTranscriptChangeAt = time
        }
    }

    private func beginSilenceMonitor() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = Task { [weak self] in
            print("[FluidAudioTranscriptionService] silenceMonitor: loop started interval=250ms")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tickSilenceCommit()
            }
            print("[FluidAudioTranscriptionService] silenceMonitor: cancelled, exiting")
        }
    }

    private func tickSilenceCommit() async {
        silenceTickCount += 1
        guard isRunning, let asrManager = asr else {
            if silenceTickCount <= 4 {
                print("[FluidAudioTranscriptionService] silenceTick #\(silenceTickCount) skip notRunning")
            }
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now < postCommitCooldownUntil {
            if silenceTickCount <= 4 || silenceTickCount % 40 == 0 {
                print(
                    "[FluidAudioTranscriptionService] silenceTick #\(silenceTickCount) cooldown until \(String(format: "%.2f", postCommitCooldownUntil - now))s remaining"
                )
            }
            return
        }
        let trimmed = lastEmittedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let quietTranscript = now - lastTranscriptChangeAt >= pauseToCommit
        let quietAudio = now - lastLoudAt >= minAudioSilence
        if !quietTranscript || !quietAudio {
            if silenceTickCount % 16 == 0 {
                let dqT = now - lastTranscriptChangeAt
                let dqA = now - lastLoudAt
                print(
                    "[FluidAudioTranscriptionService] silenceTick #\(silenceTickCount) gates transcriptQuiet=\(quietTranscript) (Δ\(String(format: "%.2f", dqT))s need≥\(pauseToCommit)) audioQuiet=\(quietAudio) (Δ\(String(format: "%.2f", dqA))s need≥\(minAudioSilence)) pendingChars=\(trimmed.count)"
                )
            }
            return
        }

        let label: String
        if let dia = diarizer {
            label = Self.dominantSpeakerLabel(diarizer: dia, totalSamples: totalSamples, windowSeconds: 3)
        } else {
            label = "User 1"
        }
        print(
            "[FluidAudioTranscriptionService] API onCommit chars=\(trimmed.count) speaker=\(label) → then asrManager.reset()"
        )
        onCommit?(trimmed, label)
        lastEmittedTranscript = ""
        lastTranscriptChangeAt = now
        lastLoudAt = now
        postCommitCooldownUntil = now + 0.65

        do {
            print("[FluidAudioTranscriptionService] API try await asrManager.reset() after commit …")
            try await asrManager.reset()
            print("[FluidAudioTranscriptionService] API asrManager.reset() ok")
        } catch {
            print("[FluidAudioTranscriptionService] API asrManager.reset() FAILED: \(error.localizedDescription)")
        }
    }

    /// Deep copy so tap buffers can be reused by the SDK before async ASR consumes them.
    private static func copyPCMBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(src.frameLength)
        guard frames > 0,
            let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        dst.frameLength = src.frameLength
        let channels = Int(src.format.channelCount)
        switch src.format.commonFormat {
        case .pcmFormatFloat32:
            guard let sfd = src.floatChannelData, let dfd = dst.floatChannelData else { return nil }
            let byteCount = frames * MemoryLayout<Float>.size
            if src.format.isInterleaved, channels >= 1 {
                memcpy(dfd[0], sfd[0], byteCount * channels)
            } else {
                for ch in 0..<channels {
                    memcpy(dfd[ch], sfd[ch], byteCount)
                }
            }
        case .pcmFormatInt16:
            guard let sid = src.int16ChannelData, let did = dst.int16ChannelData else { return nil }
            let byteCount = frames * MemoryLayout<Int16>.size
            if src.format.isInterleaved, channels >= 1 {
                memcpy(did[0], sid[0], byteCount * channels)
            } else {
                for ch in 0..<channels {
                    memcpy(did[ch], sid[ch], byteCount)
                }
            }
        default:
            return nil
        }
        return dst
    }

    private static func monoRMSSamples(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples {
            sum += x * x
        }
        return sqrt(sum / Float(samples.count))
    }

    private static func formatSignature(_ f: AVAudioFormat) -> String {
        "\(f.commonFormat.rawValue)-\(f.sampleRate)-\(f.channelCount)-\(f.isInterleaved)"
    }

    private static func logPreview(_ text: String, maxLen: Int) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        if t.isEmpty { return "live=\"\"" }
        if t.count <= maxLen { return "live=\"\(t)\"" }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return "live=\"\(t[..<idx])…\""
    }

    /// Pick the diarizer `speakerIndex` with the most overlap in the last `windowSeconds` of audio (FluidAudio `DiarizerSegment.startTime` / `endTime` in seconds).
    private static func dominantSpeakerLabel(
        diarizer: LSEENDDiarizer,
        totalSamples: Int64,
        windowSeconds: Float
    ) -> String {
        let endSec = max(0, Float(totalSamples) / 16_000.0)
        let startSec = max(0, endSec - windowSeconds)
        var bestIndex = 0
        var bestOverlap: Float = 0

        for speaker in diarizer.timeline.speakers.values {
            let segments = speaker.finalizedSegments + speaker.tentativeSegments
            for seg in segments {
                let overlap = max(
                    0,
                    min(seg.endTime, endSec) - max(seg.startTime, startSec)
                )
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = seg.speakerIndex
                }
            }
        }

        // 1-based “user” names for chat bubbles
        return "User \(bestIndex + 1)"
    }
}
