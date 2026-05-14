import AVFoundation
import Foundation
import Speech

/// Streams tap `AVAudioPCMBuffer` into `SFSpeechAudioBufferRecognitionRequest` (Apple’s live pattern:
/// `append(_:)` + partial results, periodic `endAudio` + new request for phrase boundaries).
/// Thread-safe entry: `append` may be called from the tap queue.
final class VoiceToTextManager: @unchecked Sendable {

    private let speechQueue = DispatchQueue(label: "com.voxa.voicetotext", qos: .userInitiated)
    private let pauseToCommit: TimeInterval
    private let rmsSpeakingThreshold: Float

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var isRunning = false
    private var segmentText = ""
    private var lastPartialAt: CFAbsoluteTime = 0
    private var pollTimer: DispatchSourceTimer?

    private var onPartial: (@Sendable (String) -> Void)?
    private var onCommit: (@Sendable (String) -> Void)?
    private var onEnergy: (@Sendable (Bool) -> Void)?

    private var appendCount = 0
    private var lastAppendLogAt: CFAbsoluteTime = 0
    private var lastPartialLogAt: CFAbsoluteTime = 0
    private var lastPartialLogCharCount = 0

    init(pauseToCommit: TimeInterval = 0.95, rmsSpeakingThreshold: Float = 0.014) {
        self.pauseToCommit = pauseToCommit
        self.rmsSpeakingThreshold = rmsSpeakingThreshold
    }

    func start(
        onPartial: @escaping @Sendable (String) -> Void,
        onCommit: @escaping @Sendable (String) -> Void,
        onEnergy: @escaping @Sendable (Bool) -> Void
    ) {
        speechQueue.async { [weak self] in
            guard let self else { return }
            self.appendCount = 0
            self.lastAppendLogAt = CFAbsoluteTimeGetCurrent()
            self.lastPartialLogAt = 0
            self.lastPartialLogCharCount = 0
            self.onPartial = onPartial
            self.onCommit = onCommit
            self.onEnergy = onEnergy
            self.isRunning = true
            self.segmentText = ""
            self.lastPartialAt = CFAbsoluteTimeGetCurrent()
            if self.recognizer == nil {
                self.recognizer = SFSpeechRecognizer(locale: Locale.current)
            }
            let localeID = Locale.current.identifier
            let available = self.recognizer?.isAvailable ?? false
            print(
                "[VoiceToTextManager] start locale=\(localeID) recognizerAvailable=\(available) pauseToCommit=\(self.pauseToCommit)s rmsThreshold=\(self.rmsSpeakingThreshold)"
            )
            self.beginRecognitionChain()
            self.startSilencePoller()
        }
    }

    func stop() {
        speechQueue.async { [weak self] in
            guard let self else { return }
            let pending = self.segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            print(
                "[VoiceToTextManager] stop appendCount=\(self.appendCount) pendingSegmentChars=\(pending.count)"
            )
            self.isRunning = false
            self.stopSilencePoller()
            if !pending.isEmpty {
                self.commitSegment(self.segmentText, reason: "stop flush")
            }
            self.teardownRecognition()
            self.onPartial = nil
            self.onCommit = nil
            self.onEnergy = nil
            self.converter = nil
            self.converterInputFormat = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        speechQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning, let request = self.request else { return }
            let srcSig = Self.formatSignature(buffer.format)
            guard let chunk = self.convertToSpeechFormat(buffer) else {
                print("[VoiceToTextManager] append convert failed srcFormat=\(srcSig) frames=\(buffer.frameLength)")
                return
            }
            request.append(chunk)
            let rms = Self.monoRMS(chunk)
            let speaking = rms > self.rmsSpeakingThreshold
            self.onEnergy?(speaking)

            self.appendCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if self.appendCount == 1 {
                print(
                    "[VoiceToTextManager] first buffer appended srcFormat=\(srcSig) -> 16k mono float framesIn=\(buffer.frameLength) framesOut=\(chunk.frameLength) rms=\(String(format: "%.5f", rms)) speaking=\(speaking)"
                )
            } else if self.appendCount % 200 == 0 || now - self.lastAppendLogAt >= 5 {
                self.lastAppendLogAt = now
                print(
                    "[VoiceToTextManager] append heartbeat count=\(self.appendCount) framesIn=\(buffer.frameLength) rms=\(String(format: "%.5f", rms)) speaking=\(speaking)"
                )
            }
        }
    }

    // MARK: - Private

    private func beginRecognitionChain() {
        teardownRecognition()
        guard let rec = recognizer else {
            print("[VoiceToTextManager] beginRecognitionChain aborted — no SFSpeechRecognizer")
            return
        }
        guard rec.isAvailable else {
            print("[VoiceToTextManager] beginRecognitionChain aborted — recognizer not available (locale=\(rec.locale.identifier))")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            req.addsPunctuation = true
        }
        request = req
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.speechQueue.async {
                self.handleRecognition(result: result, error: error)
            }
        }
        let addsPunctuation: Bool
        if #available(macOS 13, *) {
            addsPunctuation = true
        } else {
            addsPunctuation = false
        }
        print(
            "[VoiceToTextManager] beginRecognitionChain task started partialResults=true addsPunctuation=\(addsPunctuation)"
        )
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error as NSError? {
            if Self.shouldIgnoreRecognitionError(error) {
                print(
                    "[VoiceToTextManager] recognition callback error (ignored) domain=\(error.domain) code=\(error.code) \(error.localizedDescription)"
                )
                return
            }
            if isRunning {
                print(
                    "[VoiceToTextManager] recognition callback error domain=\(error.domain) code=\(error.code) \(error.localizedDescription)"
                )
            }
            return
        }
        guard isRunning else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            segmentText = text
            lastPartialAt = CFAbsoluteTimeGetCurrent()
            onPartial?(text)
            let now = CFAbsoluteTimeGetCurrent()
            let charDelta = abs(text.count - lastPartialLogCharCount)
            let timeDelta = now - lastPartialLogAt
            let shouldLogPartial = result.isFinal || charDelta >= 12 || timeDelta >= 0.35
            if shouldLogPartial {
                lastPartialLogAt = now
                lastPartialLogCharCount = text.count
                let preview = Self.logPreview(text)
                print(
                    "[VoiceToTextManager] partial isFinal=\(result.isFinal) chars=\(text.count) \(preview)"
                )
            }
            if result.isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitSegment(text, reason: "isFinal")
                beginRecognitionChain()
            }
        } else if error == nil {
            print("[VoiceToTextManager] recognition callback nil result, nil error (stream end?)")
        }
    }

    private func commitSegment(_ text: String, reason: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("[VoiceToTextManager] commit reason=\(reason) chars=\(trimmed.count) \(Self.logPreview(trimmed))")
        onCommit?(trimmed)
        segmentText = ""
        onPartial?("")
        lastPartialAt = CFAbsoluteTimeGetCurrent()
    }

    private func startSilencePoller() {
        stopSilencePoller()
        let timer = DispatchSource.makeTimerSource(queue: speechQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.tickSilence()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopSilencePoller() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func tickSilence() {
        guard isRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let quietFor = now - lastPartialAt
        let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if quietFor >= pauseToCommit, !trimmed.isEmpty {
            print(
                "[VoiceToTextManager] silence commit quietFor=\(String(format: "%.2f", quietFor))s >= pause=\(pauseToCommit)s segmentChars=\(trimmed.count)"
            )
            commitSegment(segmentText, reason: "silence")
            beginRecognitionChain()
        }
    }

    private func teardownRecognition() {
        let hadTask = task != nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if hadTask {
            print("[VoiceToTextManager] teardownRecognition canceled task, ended audio on request")
        }
    }

    private func convertToSpeechFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buffer.format
        if converterInputFormat.map({ Self.formatSignature($0) != Self.formatSignature(src) }) ?? true {
            let oldSig = converterInputFormat.map(Self.formatSignature)
            converterInputFormat = src
            let newSig = Self.formatSignature(src)
            print("[VoiceToTextManager] converter reset inputFormat \(oldSig ?? "nil") -> \(newSig)")
            guard let dst = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                converter = nil
                print("[VoiceToTextManager] converter reset failed — could not build 16k mono float output format")
                return nil
            }
            converter = AVAudioConverter(from: src, to: dst)
        }
        guard let converter else { return nil }
        let dstFormat = converter.outputFormat
        let ratio = dstFormat.sampleRate / src.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outFrames) else { return nil }
        var err: NSError?
        var copied = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if copied {
                outStatus.pointee = .noDataNow
                return nil
            }
            copied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || err != nil {
            print("[VoiceToTextManager] AVAudioConverter.convert failed status=\(status.rawValue) err=\(err?.localizedDescription ?? "nil")")
            return nil
        }
        guard out.frameLength > 0 else { return nil }
        return out
    }

    private static func shouldIgnoreRecognitionError(_ error: NSError) -> Bool {
        if error.domain == "kAFAssistantErrorDomain", error.code == 216 { return true }
        if error.code == 301 { return true }
        if error.localizedDescription.lowercased().contains("canceled") { return true }
        return false
    }

    private static func logPreview(_ text: String, maxLen: Int = 72) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        if t.count <= maxLen { return "preview=\"\(t)\"" }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return "preview=\"\(t[..<idx])…\""
    }

    private static func formatSignature(_ f: AVAudioFormat) -> String {
        "\(f.commonFormat.rawValue)-\(f.sampleRate)-\(f.channelCount)-\(f.isInterleaved)"
    }

    private static func monoRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        let stride = buffer.stride
        var sum: Float = 0
        for i in 0..<n {
            let v = ch[0][i * stride]
            sum += v * v
        }
        return sqrt(sum / Float(n))
    }
}
