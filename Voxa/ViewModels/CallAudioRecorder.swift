import AVFoundation
import Foundation
import Observation
import VoxaSDK

@MainActor
@Observable
final class CallAudioRecorder {
    private static let visualizationBarCount: CGFloat = 100
    private static let saveLiveAudioChunksToDisk = true

    private var visualDetector: VoxaAudioKit?
    private let liveBufferQueue = DispatchQueue(label: "CallAudioRecorder.LiveBuffer", qos: .userInitiated)

    @ObservationIgnored
    private var chunkWriter: LocalAudioChunkWriter?

    /// Fired on the tap queue for every buffer (same stream as chunk writer). Keep work minimal.
    @ObservationIgnored nonisolated(unsafe) var onLiveBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    @ObservationIgnored
    private var audioLevels: [AudioLevel] = []
    private var lastAutoModeBarTime: DispatchTime?
    @ObservationIgnored
    private var lastUIUpdateTime: DispatchTime?
    private let uiUpdateInterval: TimeInterval = 0.025

    private(set) var isRecording = false
    private(set) var currentAudioLevels: [AudioLevel] = []
    private(set) var predictionState: PredictionState = .none
    private(set) var chunkCounter: Int = 0
    private(set) var aiGeneratedChunks: [Int: Double] = [:]
    private(set) var verifiedIdentityChunks: [Int: Double] = [:]
    private(set) var automaticRecordingStartTime: Date?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        automaticRecordingStartTime = Date()
        predictionState = .none
        aiGeneratedChunks = [:]
        verifiedIdentityChunks = [:]
        chunkCounter = 0
        audioLevels = []
        currentAudioLevels = []
        lastAutoModeBarTime = nil
        lastUIUpdateTime = nil

        if Self.saveLiveAudioChunksToDisk {
            let writer = LocalAudioChunkWriter()
            chunkWriter = writer
            print("[CallAudioRecorder] saving chunks (Aurigin-style WAV) -> \(writer.folderPath)")
        } else {
            chunkWriter = nil
        }

        startLiveVisualizationStream()
    }

    func stop(userInitiated: Bool = false) {
        isRecording = false
        onLiveBuffer = nil
        visualDetector?.stopLiveAudioBufferStream()
        liveBufferQueue.sync { [chunkWriter] in
            chunkWriter?.flush()
        }
        chunkWriter = nil
        visualDetector = nil
        audioLevels = []
        currentAudioLevels = []
        lastAutoModeBarTime = nil
        lastUIUpdateTime = nil
        automaticRecordingStartTime = nil
    }

    func restartTapsForUpdatedProcessList() {
        guard isRecording else {
            print("[CallAudioRecorder] restartTaps skipped — not recording")
            return
        }
        print("[CallAudioRecorder] restartTaps begin")

        liveBufferQueue.sync { [chunkWriter] in
            chunkWriter?.flush()
        }

        visualDetector?.stopLiveAudioBufferStream()
        visualDetector = nil
        audioLevels = []
        currentAudioLevels = []
        lastAutoModeBarTime = nil
        lastUIUpdateTime = nil

        startLiveVisualizationStream()
        print("[CallAudioRecorder] restartTaps complete")
    }

    private func startLiveVisualizationStream() {
        if visualDetector == nil {
            visualDetector = VoxaAudioKit()
        }
        guard let visualDetector else {
            print("[CallAudioRecorder] visualDetector is nil")
            return
        }
        let chunkSink: LocalAudioChunkWriter? = chunkWriter
        var callbackCounter = 0
        let startError = visualDetector.startLiveAudioBufferStream(.all, queue: liveBufferQueue) { [weak self] buffer in
            self?.onLiveBuffer?(buffer)
            chunkSink?.append(buffer: buffer)
            callbackCounter += 1
            let shouldProcessAudio = callbackCounter % 4 == 0
            guard shouldProcessAudio else { return }
            let newLevels = CallAudioLevels.extractAudioLevels(from: buffer, segments: 1)
            Task { @MainActor in
                self?.updateAudioLevels(newLevels)
            }
        }
        if let startError {
            print("[CallAudioRecorder] startLiveAudioBufferStream failed: \(startError)")
            visualDetector.stopLiveAudioBufferStream()
        } else {
            print("[CallAudioRecorder] startLiveAudioBufferStream started")
        }
    }

    private func updateAudioLevels(_ levels: [Float]) {
        let now = DispatchTime.now()

        if lastAutoModeBarTime == nil {
            lastAutoModeBarTime = now
            if let maxLevel = levels.max() {
                audioLevels.append(AudioLevel(value: maxLevel, chunkId: chunkCounter))
            }
        } else if let lastTime = lastAutoModeBarTime {
            let elapsed = Double(now.uptimeNanoseconds - lastTime.uptimeNanoseconds) / 1_000_000_000.0
            let optimalInterval = 30.0 / Double(Self.visualizationBarCount)
            if elapsed >= optimalInterval {
                if let maxLevel = levels.max() {
                    audioLevels.append(AudioLevel(value: maxLevel, chunkId: chunkCounter))
                }
                lastAutoModeBarTime = now
                if audioLevels.count > Int(Self.visualizationBarCount) {
                    audioLevels.removeFirst()
                }
            }
        }

        if lastUIUpdateTime == nil
            || Double(now.uptimeNanoseconds - (lastUIUpdateTime?.uptimeNanoseconds ?? 0)) / 1_000_000_000.0 >= uiUpdateInterval {
            lastUIUpdateTime = now
            currentAudioLevels = audioLevels
        }
    }
}
