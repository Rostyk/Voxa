import AVFoundation

extension AVAudioPCMBuffer {

    /// Deep copy so PCM can be used after the Core Audio process-tap IO callback returns.
    func voxaOwnedCopy() -> AVAudioPCMBuffer? {
        let frames = frameLength
        guard frames > 0 else { return nil }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        copy.frameLength = frames

        let frameCount = Int(frames)
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let src = floatChannelData, let dst = copy.floatChannelData else { return nil }
            if format.isInterleaved {
                memcpy(dst[0], src[0], frameCount * channelCount * MemoryLayout<Float>.size)
            } else {
                for channel in 0..<channelCount {
                    memcpy(dst[channel], src[channel], frameCount * MemoryLayout<Float>.size)
                }
            }
        case .pcmFormatInt16:
            guard let src = int16ChannelData, let dst = copy.int16ChannelData else { return nil }
            if format.isInterleaved {
                memcpy(dst[0], src[0], frameCount * channelCount * MemoryLayout<Int16>.size)
            } else {
                for channel in 0..<channelCount {
                    memcpy(dst[channel], src[channel], frameCount * MemoryLayout<Int16>.size)
                }
            }
        default:
            return nil
        }

        return copy
    }
}
