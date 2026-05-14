import AVFoundation
import Foundation

// MARK: - Copied from AuriginMac `AudioUtils` (prepareWAVData path only) for identical chunk normalization.
// Voxa: WAV length follows resampled PCM (no fixed-duration pad) so `LocalAudioChunkWriter` chunk sizes map to real audio length.

private enum ResampleError: Error {
    case converter
}

private struct ProcessedAudio {
    let normalizedFloatArray: [Float]
    let int16Array: [Int16]
}

/// Same normalization as Aurigin: float PCM `Data` + `AVAudioFormat` → 16 kHz mono int16 WAV `Data`.
enum VoxaAuriginChunkWAV {
    static let targetSampleRate = 16_000

    static func prepareWAVData(chunkData: Data, format: AVAudioFormat) -> Data {
        let processedAudio = prepareAudioForProcessing(
            pcmData: chunkData,
            sourceFormat: format,
            targetSampleRate: targetSampleRate
        )
        // Use natural length after resample so chunk wall time matches `LocalAudioChunkWriter.chunkDurationSeconds`
        // (fixed 5 s padding would add silence when chunks are shorter than 5 s).
        let finalFloatArray = processedAudio.normalizedFloatArray
        return createWavData(from: finalFloatArray, sampleRate: targetSampleRate)
    }

    private static func createWavData(from floatArray: [Float], sampleRate: Int) -> Data {
        var pcmData = Data()
        for sample in floatArray {
            let clampedSample = max(-1, min(1, sample))
            let int16Sample = Int16(clampedSample * 32767)
            pcmData.append(contentsOf: withUnsafeBytes(of: int16Sample.littleEndian) { Array($0) })
        }
        var wavData = Data()
        wavData.append(createPCMWavHeader(dataSize: pcmData.count))
        wavData.append(pcmData)
        return wavData
    }

    /// Same header as Aurigin `AudioUtils.createPCMWavHeader` (mono, 16 kHz).
    private static func createPCMWavHeader(dataSize: Int) -> Data {
        var header = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(targetSampleRate * Int(channels) * Int(bitsPerSample / 8))
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(chunkSize).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(channels.littleEndianData)
        header.append(UInt32(targetSampleRate).littleEndianData)
        header.append(byteRate.littleEndianData)
        header.append(blockAlign.littleEndianData)
        header.append(bitsPerSample.littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(dataSize).littleEndianData)
        return header
    }

    private static func prepareAudioForProcessing(pcmData: Data, sourceFormat: AVAudioFormat, targetSampleRate: Int) -> ProcessedAudio {
        let floatArray = pcmData.withUnsafeBytes { bufferPointer -> [Float] in
            let floatBuffer = bufferPointer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }

        var normalizedInputArray = floatArray
        let peak = max(abs(floatArray.min() ?? 0), abs(floatArray.max() ?? 0))
        if peak < 0.1 || peak > 1 {
            if peak > 0.00001 {
                let normFactor = 0.95 / peak
                normalizedInputArray = floatArray.map { $0 * normFactor }
            }
        }

        var processedFloatArray = normalizedInputArray
        if Int(sourceFormat.sampleRate) != targetSampleRate {
            do {
                let sourcePCMBuffer = createPCMBuffer(from: normalizedInputArray, format: sourceFormat)
                guard let targetFormat = AVAudioFormat(
                    commonFormat: sourceFormat.commonFormat,
                    sampleRate: Double(targetSampleRate),
                    channels: sourceFormat.channelCount,
                    interleaved: sourceFormat.isInterleaved
                ) else { throw ResampleError.converter }
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw ResampleError.converter }
                let ratio = Double(targetSampleRate) / sourceFormat.sampleRate
                let outputFrames = AVAudioFrameCount(Double(sourcePCMBuffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { throw ResampleError.converter }
                outputBuffer.frameLength = outputFrames
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return sourcePCMBuffer
                }
                if error != nil || status == .error { throw ResampleError.converter }
                if let floatData = outputBuffer.floatChannelData {
                    let count = Int(outputBuffer.frameLength)
                    let stride = outputBuffer.stride
                    var resampledArray = [Float]()
                    resampledArray.reserveCapacity(count)
                    for i in 0..<count {
                        resampledArray.append(floatData[0][i * stride])
                    }
                    processedFloatArray = resampledArray
                }
            } catch {
                processedFloatArray = improvedResample(
                    normalizedInputArray,
                    sourceRate: sourceFormat.sampleRate,
                    targetRate: Double(targetSampleRate)
                )
            }
        }

        let int16Array = processedFloatArray.map { value -> Int16 in
            let clampedValue = max(-1, min(1, value))
            return Int16(clampedValue * 32767)
        }
        let normalizedFloatArray = int16Array.map { Float($0) / 32768 }
        return ProcessedAudio(normalizedFloatArray: normalizedFloatArray, int16Array: int16Array)
    }

    private static func createPCMBuffer(from floatArray: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(floatArray.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let floatChannelData = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                floatChannelData[0][i] = floatArray[i]
            }
        }
        return buffer
    }

    private static func improvedResample(_ samples: [Float], sourceRate: Double, targetRate: Double) -> [Float] {
        let ratio = targetRate / sourceRate
        var resampledArray = [Float]()
        resampledArray.reserveCapacity(Int(Double(samples.count) * ratio))

        if abs(ratio - 1) < 0.001 {
            return samples
        }
        if ratio < 1 {
            let windowSize = max(1, Int(1 / ratio))
            var position = 0.0
            while Int(position) < samples.count {
                let startIdx = Int(position)
                let endIdx = min(startIdx + windowSize, samples.count)
                if startIdx < endIdx {
                    var sum: Float = 0
                    for i in startIdx..<endIdx { sum += samples[i] }
                    resampledArray.append(sum / Float(endIdx - startIdx))
                }
                position += 1 / ratio
            }
        } else {
            let step = 1 / ratio
            var position = 0.0
            while position < Double(samples.count - 1) {
                let index = Int(position)
                let fraction = position - Double(index)
                if index > 0 && index < samples.count - 2 {
                    let y0 = samples[index - 1]
                    let y1 = samples[index]
                    let y2 = samples[index + 1]
                    let y3 = samples[index + 2]
                    let a0 = y3 - y2 - y0 + y1
                    let a1 = y0 - y1 - a0
                    let a2 = y2 - y0
                    let a3 = y1
                    let t = Float(fraction)
                    let t2 = t * t
                    let t3 = t2 * t
                    resampledArray.append(a0 * t3 + a1 * t2 + a2 * t + a3)
                } else if index < samples.count - 1 {
                    let sample = samples[index] * Float(1 - fraction) + samples[index + 1] * Float(fraction)
                    resampledArray.append(sample)
                } else if index < samples.count {
                    resampledArray.append(samples[index])
                }
                position += step
            }
        }
        return resampledArray
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
}
