import AVFoundation
import Foundation

/// Accumulates mono float32 PCM on the tap queue; when `chunkDurationSeconds` of source bytes are ready, copies them off and
/// encodes/writes WAV on a dedicated serial background queue so the callback stays light.
final class LocalAudioChunkWriter {

    /// Shorter chunks → more frequent WAV files (e.g. for inspection) without changing capture tap rate.
    static let defaultChunkDurationSeconds: TimeInterval = 2.5

    static var chunksOutputFolderPath: String {
        chunksOutputDirectoryURL().path
    }

    private static func chunksOutputDirectoryURL() -> URL {
        let bundleId = Bundle.main.bundleIdentifier ?? "Voxa"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("LocalAudioChunks", isDirectory: true)
    }

    private let chunkDurationSeconds: TimeInterval
    private let outputDirectory: URL
    /// Serial queue: `prepareWAVData` + disk only; preserves chunk order.
    private let ioQueue = DispatchQueue(label: "com.voxa.LocalAudioChunkWriter.io", qos: .utility)

    private var chunkSequence: Int = 0

    private var rawMonoFloats = Data()
    private var monoSourceFormat: AVAudioFormat?

    let folderPath: String

    init(chunkDurationSeconds: TimeInterval = LocalAudioChunkWriter.defaultChunkDurationSeconds) {
        self.chunkDurationSeconds = chunkDurationSeconds
        let outputDirectory = Self.chunksOutputDirectoryURL()
        self.outputDirectory = outputDirectory
        self.folderPath = outputDirectory.path
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    /// Call only from the tap/capture queue: mutates `rawMonoFloats` and schedules IO; never blocks on encode/write.
    func append(buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if monoSourceFormat == nil {
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ) else { return }
            monoSourceFormat = fmt
        }
        Self.appendTapAsMonoFloatData(buffer: buffer, to: &rawMonoFloats)

        guard let fmt = monoSourceFormat else { return }
        let sampleRate = fmt.sampleRate
        let bytesPerChunk = Int(chunkDurationSeconds * sampleRate * Double(MemoryLayout<Float>.size))
        while rawMonoFloats.count >= bytesPerChunk {
            let chunk = Data(rawMonoFloats.prefix(bytesPerChunk))
            rawMonoFloats.removeSubrange(0..<bytesPerChunk)
            ioQueue.async { [weak self] in
                self?.encodeAndWriteMonoFloatChunk(chunk, sourceSampleRate: sampleRate)
            }
        }
    }

    /// Enqueues any tail bytes, then waits until all scheduled encodes/writes finish (same tap queue as `append` is fine).
    func flush() {
        let sampleRate = monoSourceFormat?.sampleRate
        let tail = Data(rawMonoFloats)
        rawMonoFloats.removeAll(keepingCapacity: true)
        if !tail.isEmpty, let sr = sampleRate {
            ioQueue.async { [weak self] in
                self?.encodeAndWriteMonoFloatChunk(tail, sourceSampleRate: sr)
            }
        }
        ioQueue.sync {}
    }

    private func encodeAndWriteMonoFloatChunk(_ monoFloatData: Data, sourceSampleRate: Double) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        let wavData = VoxaAuriginChunkWAV.prepareWAVData(chunkData: monoFloatData, format: fmt)
        writeWavData(wavData)
    }

    private func writeWavData(_ wavData: Data) {
        chunkSequence += 1
        let stamp = Int(Date().timeIntervalSince1970)
        let name = String(format: "chunk_%06d_%d.wav", chunkSequence, stamp)
        let url = outputDirectory.appendingPathComponent(name)
        do {
            try wavData.write(to: url, options: .atomic)
            print("[LocalAudioChunkWriter] wrote \(url.path) (\(wavData.count) bytes)")
        } catch {
            print("[LocalAudioChunkWriter] write failed: \(error.localizedDescription)")
        }
    }

    /// Aurigin `CallAuthSignatureViewModel.appendPCMBuffer`–style packing, downmixed to mono floats.
    private static func appendTapAsMonoFloatData(buffer: AVAudioPCMBuffer, to data: inout Data) {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let fcd = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride

        if buffer.format.isInterleaved {
            let p = fcd[0]
            if channelCount == 1 {
                for frame in 0..<frameLength {
                    appendLittleEndianFloat(p[frame * stride], to: &data)
                }
            } else {
                for frame in 0..<frameLength {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += p[frame * stride + c]
                    }
                    appendLittleEndianFloat(sum / Float(channelCount), to: &data)
                }
            }
            return
        }

        if channelCount == 1 {
            for frame in 0..<frameLength {
                appendLittleEndianFloat(fcd[0][frame * stride], to: &data)
            }
        } else {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for c in 0..<channelCount {
                    sum += fcd[c][frame * stride]
                }
                appendLittleEndianFloat(sum / Float(channelCount), to: &data)
            }
        }
    }

    private static func appendLittleEndianFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
