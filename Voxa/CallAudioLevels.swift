import AVFoundation
import Foundation
import SwiftUI

struct AudioLevel: Identifiable {
    let id = UUID()
    let value: Float
    let chunkId: Int
}

enum CallAudioLevels {
    static func extractAudioLevels(from buffer: AVAudioPCMBuffer, segments: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [0.0] }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [0.0] }

        var levels: [Float] = []
        levels.reserveCapacity(segments)

        let segmentSize = frameCount / segments
        let sampleStride = max(1, segmentSize / 20)

        for segment in 0..<segments {
            let startFrame = segment * segmentSize
            let endFrame = min(startFrame + segmentSize, frameCount)

            var maxLevel: Float = 0.0
            let channel = 0
            var frame = startFrame
            while frame < endFrame {
                let sample = abs(channelData[channel][frame])
                maxLevel = max(maxLevel, sample)
                frame += sampleStride
            }

            let scaledLevel = min(1.0, maxLevel * 1.2)
            levels.append(scaledLevel)
        }

        return levels
    }
}
