import AVFoundation
import Foundation

public typealias AUProcessScanCompletion = ([AUAudioProcess], AUAudioError?) -> Void
public typealias AUProcessTapCallback = (AVAudioPCMBuffer) -> Void
public typealias AUProcessChangeCallback = ([AUAudioProcess]) -> Void
public typealias AUAudioBufferObserver = (AVAudioPCMBuffer) -> Void

public final class VoxaSystemAudio {

    private let tapManager = AUAudioTapManager()
    private let audioRecordingPermission = AudioRecordingPermission()

    public init() {}

    deinit {
        stopMonitoring()
        removeAllTaps()
    }

    public func scan(onlyWithMicrophoneInput: Bool = true, completion: @escaping AUProcessScanCompletion) {
        tapManager.scan(onlyWithMicrophoneInput: onlyWithMicrophoneInput, completion: completion)
    }

    public func startMonitoring(onlyWithMicrophoneInput: Bool = true, onChange: @escaping AUProcessChangeCallback) {
        tapManager.startMonitoring(onlyWithMicrophoneInput: onlyWithMicrophoneInput, onChange: onChange)
    }

    public func updateScanFilter(onlyWithMicrophoneInput: Bool) {
        tapManager.updateScanFilter(onlyWithMicrophoneInput: onlyWithMicrophoneInput)
    }

    public func stopMonitoring() {
        tapManager.stopMonitoring()
    }

    public func removeTap(from process: AUAudioProcess) {
        tapManager.removeTap(process)
    }

    public func removeEntireTap() {
        tapManager.removeEntireTap()
    }

    public func removeAllTaps() {
        tapManager.removeAllTaps()
    }

    @discardableResult
    public func startLiveAudioBufferStream(
        _ scope: DetectionScope = .all,
        queue: DispatchQueue,
        onBuffer: @escaping AUAudioBufferObserver
    ) -> AUAudioError? {
        requestSystemAudioPermission()
        tapManager.removeAllTaps()
        return tapManager.tap(scope) { buffer in
            queue.async {
                onBuffer(buffer)
            }
        }
    }

    public func stopLiveAudioBufferStream() {
        tapManager.removeAllTaps()
    }

    public func requestSystemAudioPermission(onStatusChange: ((AudioRecordingPermission.Status) -> Void)? = nil) {
        if let callback = onStatusChange {
            audioRecordingPermission.onStatusChange(callback)
        }
        audioRecordingPermission.request()
    }

    public func getSystemAudioPermissionStatus() -> AudioRecordingPermission.Status {
        audioRecordingPermission.status
    }
}
