import AVFoundation
import CoreAudio

public extension AVAudioPCMBuffer {

    /// Deep copy so PCM can be used after the Core Audio process-tap IO callback returns.
    /// Uses `AudioBufferList` byte sizes (not only `floatChannelData`) so teardown buffers do not fault.
    func voxaOwnedCopy() -> AVAudioPCMBuffer? {
        let frames = frameLength
        guard frames > 0 else { return nil }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }

        let frameCount = Int(frames)
        guard frameCount > 0, Self.copySafePCM(from: self, into: copy, frameCount: frameCount) else {
            return nil
        }

        copy.frameLength = frames
        return copy
    }
}

private extension AVAudioPCMBuffer {

    static func copySafePCM(
        from source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer,
        frameCount: Int
    ) -> Bool {
        let format = source.format
        let channelCount = Int(format.channelCount)
        guard channelCount > 0, frameCount > 0 else { return false }

        var dstList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard !dstList.isEmpty else { return false }

        let srcList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        guard !srcList.isEmpty else { return false }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            let sampleSize = MemoryLayout<Float>.size
            if format.isInterleaved {
                return copyInterleavedFloat(
                    src: srcList[0],
                    dst: dstList[0],
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleSize: sampleSize
                )
            }
            return copyNonInterleavedFloat(
                srcList: srcList,
                dstList: dstList,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleSize: sampleSize
            )

        case .pcmFormatInt16:
            let sampleSize = MemoryLayout<Int16>.size
            if format.isInterleaved {
                return copyInterleavedInt16(
                    src: srcList[0],
                    dst: dstList[0],
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleSize: sampleSize
                )
            }
            return copyNonInterleavedInt16(
                srcList: srcList,
                dstList: dstList,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleSize: sampleSize
            )

        default:
            return false
        }
    }

    static func copyInterleavedFloat(
        src: AudioBuffer,
        dst: AudioBuffer,
        frameCount: Int,
        channelCount: Int,
        sampleSize: Int
    ) -> Bool {
        guard let srcData = src.mData, let dstData = dst.mData else { return false }
        let expected = frameCount * channelCount * sampleSize
        let srcBytes = Int(src.mDataByteSize)
        guard srcBytes > 0, expected > 0 else { return false }
        let copyBytes = min(expected, srcBytes)
        guard copyBytes >= channelCount * sampleSize else { return false }
        memcpy(dstData, srcData, copyBytes)
        return true
    }

    static func copyNonInterleavedFloat(
        srcList: UnsafeMutableAudioBufferListPointer,
        dstList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        sampleSize: Int
    ) -> Bool {
        let buffersToUse = min(channelCount, srcList.count, dstList.count)
        guard buffersToUse > 0 else { return false }

        let frameBytes = frameCount * sampleSize
        for channel in 0..<buffersToUse {
            let src = srcList[channel]
            guard let srcData = src.mData else { return false }
            let srcBytes = Int(src.mDataByteSize)
            guard srcBytes > 0 else { return false }
            let copyBytes = min(frameBytes, srcBytes)
            guard copyBytes >= sampleSize else { return false }
            guard let dstData = dstList[channel].mData else { return false }
            memcpy(dstData, srcData, copyBytes)
        }
        return true
    }

    static func copyInterleavedInt16(
        src: AudioBuffer,
        dst: AudioBuffer,
        frameCount: Int,
        channelCount: Int,
        sampleSize: Int
    ) -> Bool {
        guard let srcData = src.mData, let dstData = dst.mData else { return false }
        let expected = frameCount * channelCount * sampleSize
        let srcBytes = Int(src.mDataByteSize)
        guard srcBytes > 0, expected > 0 else { return false }
        let copyBytes = min(expected, srcBytes)
        guard copyBytes >= channelCount * sampleSize else { return false }
        memcpy(dstData, srcData, copyBytes)
        return true
    }

    static func copyNonInterleavedInt16(
        srcList: UnsafeMutableAudioBufferListPointer,
        dstList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        sampleSize: Int
    ) -> Bool {
        let buffersToUse = min(channelCount, srcList.count, dstList.count)
        guard buffersToUse > 0 else { return false }

        let frameBytes = frameCount * sampleSize
        for channel in 0..<buffersToUse {
            let src = srcList[channel]
            guard let srcData = src.mData else { return false }
            let srcBytes = Int(src.mDataByteSize)
            guard srcBytes > 0 else { return false }
            let copyBytes = min(frameBytes, srcBytes)
            guard copyBytes >= sampleSize else { return false }
            guard let dstData = dstList[channel].mData else { return false }
            memcpy(dstData, srcData, copyBytes)
        }
        return true
    }
}
