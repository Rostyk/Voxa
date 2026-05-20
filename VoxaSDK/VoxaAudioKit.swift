import AVFoundation
import Foundation

public typealias VOProcessScanCompletion = ([VOAudioProcess], VOAudioError?) -> Void
public typealias VOProcessTapCallback = (AVAudioPCMBuffer) -> Void
public typealias VOProcessChangeCallback = ([VOAudioProcess]) -> Void
public typealias VOAudioBufferObserver = (AVAudioPCMBuffer) -> Void

/// Main entry point for system audio scanning and live tap streaming (`import VoxaSDK`).
public final class VoxaAudioKit {

    private let tapManager = VOAudioTapManager()
    private let audioRecordingPermission = AudioRecordingPermission()

    /// TEMPORARY: When true, Zoom is omitted from the entire-system tap. See `ZoomCallDetectionExclusion.swift`.
    public var excludeZoomFromEntireSystemTap = false {
        didSet { tapManager.excludeZoomFromEntireSystemTap = excludeZoomFromEntireSystemTap }
    }

    public init() {}

    deinit {
        stopMonitoring()
        removeAllTaps()
    }

    public func scan(onlyWithMicrophoneInput: Bool = true, completion: @escaping VOProcessScanCompletion) {
        tapManager.scan(onlyWithMicrophoneInput: onlyWithMicrophoneInput, completion: completion)
    }

    public func startMonitoring(onlyWithMicrophoneInput: Bool = true, onChange: @escaping VOProcessChangeCallback) {
        tapManager.startMonitoring(onlyWithMicrophoneInput: onlyWithMicrophoneInput, onChange: onChange)
    }

    public func updateScanFilter(onlyWithMicrophoneInput: Bool) {
        tapManager.updateScanFilter(onlyWithMicrophoneInput: onlyWithMicrophoneInput)
    }

    public func stopMonitoring() {
        tapManager.stopMonitoring()
    }

    public func removeTap(from process: VOAudioProcess) {
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
        _ scope: ScanScope = .all,
        queue: DispatchQueue,
        onBuffer: @escaping VOAudioBufferObserver
    ) -> VOAudioError? {
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
