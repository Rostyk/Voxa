import AVFoundation
import Foundation
import Speech

/// Streams tap `AVAudioPCMBuffer` into `SFSpeechAudioBufferRecognitionRequest` (Apple’s live pattern:
/// `append(_:)` + partial results). Bubble boundaries use **real audio silence** plus partial quiet,
/// then `endAudio` and wait for a **final** result while **queueing** PCM so nothing is dropped
/// at segment rotation. Stale task callbacks are ignored via `recognitionGeneration`.
final class VoiceToTextManager: @unchecked Sendable {

    private let speechQueue = DispatchQueue(label: "com.voxa.voicetotext", qos: .userInitiated)
    private let pauseToCommit: TimeInterval
    private let minAudioSilenceForCommit: TimeInterval
    private let silenceFinalTimeout: TimeInterval
    private let rmsSpeakingThreshold: Float
    private let maxPendingConvertedChunks: Int

    /// Locale for `SFSpeechRecognizer`; updated when user picks another language while live.
    private var recognitionLocale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var isRunning = false
    private var segmentText = ""
    private var lastPartialAt: CFAbsoluteTime = 0
    private var lastLoudAudioAt: CFAbsoluteTime = 0
    private var pollTimer: DispatchSourceTimer?
    private var finalWaitTimer: DispatchSourceTimer?

    private var recognitionGeneration = 0

    private var awaitingFinalAfterSilence = false
    private var silenceFallbackText = ""
    private var pendingConvertedChunks: [AVAudioPCMBuffer] = []

    private var onPartial: (@Sendable (String) -> Void)?
    private var onCommit: (@Sendable (String) -> Void)?
    private var onEnergy: (@Sendable (Bool) -> Void)?

    private var appendCount = 0
    private var lastAppendLogAt: CFAbsoluteTime = 0
    private var lastPartialLogAt: CFAbsoluteTime = 0
    private var lastPartialLogCharCount = 0

    init(
        pauseToCommit: TimeInterval = 0.95,
        minAudioSilenceForCommit: TimeInterval = 0.55,
        silenceFinalTimeout: TimeInterval = 2.8,
        rmsSpeakingThreshold: Float = 0.014,
        maxPendingConvertedChunks: Int = 280
    ) {
        self.pauseToCommit = pauseToCommit
        self.minAudioSilenceForCommit = minAudioSilenceForCommit
        self.silenceFinalTimeout = silenceFinalTimeout
        self.rmsSpeakingThreshold = rmsSpeakingThreshold
        self.maxPendingConvertedChunks = maxPendingConvertedChunks
        self.recognitionLocale = Locale.current
    }

    /// Updates the session locale. If recognition is running, tears down the current task and starts a fresh chain
    /// so the tap keeps feeding audio without calling `stop` / `start` at the view-model layer.
    func applyRecognitionLocale(_ locale: Locale) {
        speechQueue.async { [weak self] in
            guard let self else { return }
            self.recognitionLocale = locale
            self.recognizer = SFSpeechRecognizer(locale: locale)
            guard self.isRunning else {
                print("[VoiceToTextManager] applyRecognitionLocale \(locale.identifier) (not running; will use on next start)")
                return
            }
            print("[VoiceToTextManager] applyRecognitionLocale \(locale.identifier) — rotating recognition chain")
            self.cancelFinalWaitTimer()
            self.awaitingFinalAfterSilence = false
            self.pendingConvertedChunks.removeAll(keepingCapacity: false)
            self.segmentText = ""
            self.silenceFallbackText = ""
            self.teardownRecognition()
            self.beginRecognitionChain()
            self.onPartial?("")
        }
    }

    func start(
        recognitionLocale: Locale,
        onPartial: @escaping @Sendable (String) -> Void,
        onCommit: @escaping @Sendable (String) -> Void,
        onEnergy: @escaping @Sendable (Bool) -> Void
    ) {
        speechQueue.async { [weak self] in
            guard let self else { return }
            self.recognitionLocale = recognitionLocale
            self.appendCount = 0
            self.lastAppendLogAt = CFAbsoluteTimeGetCurrent()
            self.lastPartialLogAt = 0
            self.lastPartialLogCharCount = 0
            self.onPartial = onPartial
            self.onCommit = onCommit
            self.onEnergy = onEnergy
            self.isRunning = true
            self.segmentText = ""
            let now = CFAbsoluteTimeGetCurrent()
            self.lastPartialAt = now
            self.lastLoudAudioAt = now
            self.awaitingFinalAfterSilence = false
            self.silenceFallbackText = ""
            self.pendingConvertedChunks.removeAll(keepingCapacity: true)
            self.recognizer = SFSpeechRecognizer(locale: self.recognitionLocale)
            let localeID = self.recognitionLocale.identifier
            let available = self.recognizer?.isAvailable ?? false
            print(
                "[VoiceToTextManager] start locale=\(localeID) recognizerAvailable=\(available) pauseToCommit=\(self.pauseToCommit)s minAudioSilence=\(self.minAudioSilenceForCommit)s finalTimeout=\(self.silenceFinalTimeout)s rmsThreshold=\(self.rmsSpeakingThreshold)"
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
                "[VoiceToTextManager] stop appendCount=\(self.appendCount) awaitingFinal=\(self.awaitingFinalAfterSilence) pendingSegmentChars=\(pending.count)"
            )
            self.isRunning = false
            self.stopSilencePoller()
            self.cancelFinalWaitTimer()
            if self.awaitingFinalAfterSilence {
                self.awaitingFinalAfterSilence = false
                let seg = self.segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fb = self.silenceFallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                let best = Self.bestCommitText(preferredFinal: "", fallbacks: [seg, fb])
                if !best.isEmpty {
                    self.commitSegment(best, reason: "stop during silence await")
                }
                self.pendingConvertedChunks.removeAll(keepingCapacity: false)
            } else if !pending.isEmpty {
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
        guard buffer.frameLength > 0 else { return }
        guard let owned = buffer.voxaOwnedCopy() else { return }
        speechQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }

            let srcSig = Self.formatSignature(owned.format)
            guard let chunk = self.convertToSpeechFormat(owned) else {
                print("[VoiceToTextManager] append convert failed srcFormat=\(srcSig) frames=\(owned.frameLength)")
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let rms = Self.monoRMS(chunk)
            let speaking = rms > self.rmsSpeakingThreshold
            if speaking {
                self.lastLoudAudioAt = now
            }
            self.onEnergy?(speaking)

            if self.awaitingFinalAfterSilence {
                if self.pendingConvertedChunks.count >= self.maxPendingConvertedChunks {
                    self.pendingConvertedChunks.removeFirst(self.pendingConvertedChunks.count / 4)
                    print("[VoiceToTextManager] pending chunk ring dropped 25% (cap=\(self.maxPendingConvertedChunks))")
                }
                self.pendingConvertedChunks.append(chunk)
                self.appendCount += 1
                return
            }

            guard let request = self.request else { return }
            request.append(chunk)

            self.appendCount += 1
            if self.appendCount == 1 {
                print(
                    "[VoiceToTextManager] first buffer appended srcFormat=\(srcSig) -> 16k mono float framesIn=\(owned.frameLength) framesOut=\(chunk.frameLength) rms=\(String(format: "%.5f", rms)) speaking=\(speaking)"
                )
            } else if self.appendCount % 200 == 0 || now - self.lastAppendLogAt >= 5 {
                self.lastAppendLogAt = now
                print(
                    "[VoiceToTextManager] append heartbeat count=\(self.appendCount) framesIn=\(owned.frameLength) rms=\(String(format: "%.5f", rms)) speaking=\(speaking)"
                )
            }
        }
    }

    // MARK: - Private

    private func beginRecognitionChain() {
        teardownRecognition()
        guard let rec = recognizer else {
            print("[VoiceToTextManager] beginRecognitionChain aborted — no SFSpeechRecognizer")
            if !pendingConvertedChunks.isEmpty {
                print("[VoiceToTextManager] dropping \(pendingConvertedChunks.count) pending chunk(s)")
                pendingConvertedChunks.removeAll(keepingCapacity: false)
            }
            return
        }
        guard rec.isAvailable else {
            print("[VoiceToTextManager] beginRecognitionChain aborted — recognizer not available (locale=\(rec.locale.identifier))")
            if !pendingConvertedChunks.isEmpty {
                print("[VoiceToTextManager] dropping \(pendingConvertedChunks.count) pending chunk(s)")
                pendingConvertedChunks.removeAll(keepingCapacity: false)
            }
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            req.addsPunctuation = true
        }
        request = req
        recognitionGeneration += 1
        let myGeneration = recognitionGeneration
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.speechQueue.async {
                guard myGeneration == self.recognitionGeneration else {
                    print(
                        "[VoiceToTextManager] stale recognition callback ignored myGen=\(myGeneration) activeGen=\(self.recognitionGeneration)"
                    )
                    return
                }
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
            "[VoiceToTextManager] beginRecognitionChain gen=\(myGeneration) partialResults=true addsPunctuation=\(addsPunctuation)"
        )
        flushPendingConvertedChunksToRequest()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if awaitingFinalAfterSilence {
            handleRecognitionWhileAwaitingFinal(result: result, error: error)
            return
        }

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
            logPartialThrottled(result: result, text: text)
            if result.isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitSegment(text, reason: "isFinal")
                beginRecognitionChain()
            }
        } else if error == nil {
            print("[VoiceToTextManager] recognition callback nil result, nil error (stream end?)")
        }
    }

    private func handleRecognitionWhileAwaitingFinal(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count > silenceFallbackText.count {
                silenceFallbackText = trimmed
            }
            segmentText = text
            lastPartialAt = CFAbsoluteTimeGetCurrent()
            onPartial?(text)
            logPartialThrottled(result: result, text: text)

            if result.isFinal {
                let fromApple = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let best = Self.bestCommitText(preferredFinal: fromApple, fallbacks: [silenceFallbackText, segmentText])
                print(
                    "[VoiceToTextManager] silence await got isFinal appleChars=\(fromApple.count) chosenChars=\(best.count) pendingChunks=\(pendingConvertedChunks.count)"
                )
                exitSilenceAwaitAndRotate(chosenText: best, reason: "final")
            }
            return
        }

        if let error = error as NSError? {
            if Self.shouldIgnoreRecognitionError(error) {
                return
            }
            print(
                "[VoiceToTextManager] silence await error domain=\(error.domain) code=\(error.code) \(error.localizedDescription) — rotating with fallbacks"
            )
            let best = Self.bestCommitText(preferredFinal: "", fallbacks: [silenceFallbackText, segmentText])
            exitSilenceAwaitAndRotate(chosenText: best, reason: "error")
            return
        }
    }

    private func exitSilenceAwaitAndRotate(chosenText: String, reason: String) {
        guard awaitingFinalAfterSilence else { return }
        awaitingFinalAfterSilence = false
        cancelFinalWaitTimer()

        let trimmed = chosenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            commitSegment(trimmed, reason: "silence+\(reason)")
        } else {
            onPartial?("")
        }
        segmentText = ""
        teardownRecognition()
        beginRecognitionChain()
    }

    private func enterSilenceEndAudioPhase() {
        guard let req = request else { return }
        guard !awaitingFinalAfterSilence else { return }
        let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        awaitingFinalAfterSilence = true
        silenceFallbackText = trimmed
        print(
            "[VoiceToTextManager] silence -> endAudio awaiting final fallbackChars=\(silenceFallbackText.count) \(Self.logPreview(silenceFallbackText))"
        )
        req.endAudio()
        request = nil
        scheduleFinalWaitTimeout()
    }

    private func scheduleFinalWaitTimeout() {
        cancelFinalWaitTimer()
        let t = DispatchSource.makeTimerSource(queue: speechQueue)
        t.schedule(deadline: .now() + silenceFinalTimeout)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.awaitingFinalAfterSilence else { return }
            let best = Self.bestCommitText(preferredFinal: "", fallbacks: [self.silenceFallbackText, self.segmentText])
            print(
                "[VoiceToTextManager] silence await timeout pendingChunks=\(self.pendingConvertedChunks.count) chosenChars=\(best.count)"
            )
            self.exitSilenceAwaitAndRotate(chosenText: best, reason: "timeout")
        }
        t.resume()
        finalWaitTimer = t
    }

    private func cancelFinalWaitTimer() {
        finalWaitTimer?.cancel()
        finalWaitTimer = nil
    }

    private func flushPendingConvertedChunksToRequest() {
        guard let req = request, !pendingConvertedChunks.isEmpty else { return }
        let n = pendingConvertedChunks.count
        for chunk in pendingConvertedChunks {
            req.append(chunk)
        }
        pendingConvertedChunks.removeAll(keepingCapacity: true)
        print("[VoiceToTextManager] flushed \(n) pending converted chunk(s) into new request")
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
        if awaitingFinalAfterSilence { return }
        let now = CFAbsoluteTimeGetCurrent()
        let quietFor = now - lastPartialAt
        let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioQuietFor = now - lastLoudAudioAt
        guard quietFor >= pauseToCommit, !trimmed.isEmpty else { return }
        guard audioQuietFor >= minAudioSilenceForCommit else {
            return
        }
        print(
            "[VoiceToTextManager] silence gate passed quietPartial=\(String(format: "%.2f", quietFor))s audioSilent=\(String(format: "%.2f", audioQuietFor))s segmentChars=\(trimmed.count)"
        )
        enterSilenceEndAudioPhase()
    }

    private func teardownRecognition() {
        let hadTask = task != nil
        // End the buffer request before canceling the task. Cancel-first tends to invalidate the
        // localspeechrecognition XPC session and surfaces kAFAssistantErrorDomain 1101 in Console.
        if let r = request {
            r.endAudio()
            request = nil
        }
        task?.cancel()
        task = nil
        if hadTask {
            print("[VoiceToTextManager] teardownRecognition endAudio then cancel")
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

    private func logPartialThrottled(result: SFSpeechRecognitionResult, text: String) {
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
    }

    private static func bestCommitText(preferredFinal: String, fallbacks: [String]) -> String {
        let p = preferredFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        return fallbacks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .max(by: { $0.count < $1.count }) ?? ""
    }

    private static func shouldIgnoreRecognitionError(_ error: NSError) -> Bool {
        // 1101: connection to local speech service invalidated — common when rotating/canceling tasks;
        // Apple still logs "Received an error while accessing localspeechrecognition" to Console.
        if error.domain == "kAFAssistantErrorDomain", error.code == 1101 { return true }
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
