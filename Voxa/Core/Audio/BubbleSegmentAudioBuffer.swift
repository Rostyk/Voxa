import AVFoundation
import Foundation

/// Accumulates 16 kHz mono Float32 tap audio for the current live “bubble” (last commit → next commit).
/// Resampling happens incrementally on each tap so commit is an O(1) handoff to FluidAudio.
final class BubbleSegmentAudioBuffer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.voxa.bubbleSegmentAudio", qos: .userInitiated)
    private let tapConverter = TapTo16kMonoConverter()
    private var samples: [Float] = []
    private var appendFailures = 0

    func reset() {
        queue.sync {
            samples.removeAll(keepingCapacity: true)
            tapConverter.reset()
            appendFailures = 0
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // Tap IO uses bufferListNoCopy — copy before async work or convert UAFs when the call ends.
        guard let owned = buffer.voxaOwnedCopy() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.samples.isEmpty {
                let estimated = Int(Double(owned.frameLength) * 16_000.0 / owned.format.sampleRate) + 4096
                self.samples.reserveCapacity(estimated)
            }
            if !self.tapConverter.appendTapBuffer(owned, into: &self.samples) {
                self.appendFailures += 1
                if self.appendFailures == 1 || self.appendFailures % 50 == 0 {
                    print(
                        "[BubbleAudio] append convert failed count=\(self.appendFailures) framesIn=\(owned.frameLength) format=\(owned.format.sampleRate)Hz ch=\(owned.format.channelCount)"
                    )
                }
            }
        }
    }

    /// Hands off accumulated 16 kHz mono samples and clears storage for the next bubble.
    func takeSnapshotAndReset() -> [Float] {
        queue.sync {
            let snapshot = samples
            samples = []
            samples.reserveCapacity(snapshot.count)
            tapConverter.reset()
            let failures = appendFailures
            appendFailures = 0
            let durationSec = Double(snapshot.count) / 16_000.0
            print(
                "[BubbleAudio] snapshot samples=\(snapshot.count) ≈\(String(format: "%.2f", durationSec))s convertFailures=\(failures)"
            )
            return snapshot
        }
    }
}
