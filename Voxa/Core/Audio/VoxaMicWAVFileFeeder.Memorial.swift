// Archived reference — previous looped WAV virtual-mic feeder (replaced by DTMF + speech injection).
// Kept so the streaming pattern stays documented in-repo.
//
// ```swift
// final class VoxaMicWAVFileFeeder: @unchecked Sendable {
//     private let queue = DispatchQueue(label: "com.aurigin.test.Voxa.VoxaMicWAVFileFeeder", qos: .userInitiated)
//     private var timer: DispatchSourceTimer?
//     private var ring: VoxaMicSharedMemory?
//     private var playbackBuffer: AVAudioPCMBuffer?
//     private var playFramePosition: Int = 0
//
//     func start(url: URL, ring: VoxaMicSharedMemory) throws {
//         playbackBuffer = try VoxaMicPCMFileLoader.loadAndConvert(url: url, targetFormat: ringFormat)
//         timer.schedule(repeating: interval) { self.tick() }  // copy framesPerTick → VoxaMicRingWriter.write
//     }
// }
// ```
//
// Live file playback is now: `VoxaMicRingPCMStreamer` + `VoxaVirtualMicSpeech` (TTS).
