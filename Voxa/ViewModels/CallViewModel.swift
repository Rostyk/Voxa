import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CallViewModel {
    static let shared = CallViewModel()

    private let audioProcessManager = AudioProcessManager()
    private let notificationEvents = CallNotificationEvents.shared

    private(set) var recorder: CallAudioRecorder?
    private(set) var isRecording = false
    private(set) var isManuallyStartedRecording = false

    private var lastMicProcessChangeTime: Date = .distantPast
    private let micProcessChangeDebounce: TimeInterval = 1.0
    private var isSettingUpRecording = false
    private var lastMicProcessSnapshot: Set<AudioProcess.ID>?
    private var refreshTimer: Timer?
    private var isMonitoringActivated = false

    /// TEMPORARY (default ON): Ignore Zoom for mic-based auto-record and exclude Zoom audio from the system tap.
    /// Remove with `ZoomCallDetectionExclusion` when no longer needed.
    var excludeZoomFromCallDetection: Bool = true {
        didSet {
            guard excludeZoomFromCallDetection != oldValue else { return }
            applyExcludeZoomFromCallDetectionSetting()
        }
    }

    var activeMicrophoneProcesses: [AudioProcess] { audioProcessManager.activeMicrophoneProcesses }

    private init() {
        applyExcludeZoomFromCallDetectionSetting()
        setupNotificationObservers()
    }

    func activate() {
        guard !isMonitoringActivated else { return }
        isMonitoringActivated = true
        applyExcludeZoomFromCallDetectionSetting()
        audioProcessManager.activate()
        startRefreshTimer()
        VoxaVirtualMicFeeder.shared.startIfNeeded()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            NotificationCenter.default.post(name: .refreshProcessMonitoring, object: nil)
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    func startSystemWideRecording(manuallyTriggered: Bool = false) {
        if isRecording {
            print("[CallViewModel] startSystemWideRecording skipped: already recording")
            return
        }
        if isSettingUpRecording {
            print("[CallViewModel] startSystemWideRecording skipped: setup in progress")
            return
        }
        if let existingRecorder = recorder, existingRecorder.isRecording {
            print("[CallViewModel] startSystemWideRecording skipped: recorder running")
            return
        }

        isSettingUpRecording = true
        isRecording = true
        isManuallyStartedRecording = manuallyTriggered

        if recorder == nil {
            recorder = CallAudioRecorder()
        }

        recorder?.start()
        print("[CallViewModel] startSystemWideRecording started (manual=\(manuallyTriggered))")
        lastMicProcessSnapshot = Set(audioProcessManager.activeMicrophoneProcesses.map(\.id))

        isSettingUpRecording = false
    }

    func stopRecording(userInitiated: Bool = false) {
        print("[CallViewModel] stopRecording (userInitiated=\(userInitiated))")
        recorder?.stop(userInitiated: userInitiated)
        isRecording = false
        isManuallyStartedRecording = false
        isSettingUpRecording = false
        lastMicProcessSnapshot = nil
    }

    /// TEMPORARY: Sync Zoom exclusion to process list + live tap. Called from Settings and on activate.
    func applyExcludeZoomFromCallDetectionSetting() {
        audioProcessManager.excludeZoomFromMicProcessList = excludeZoomFromCallDetection
        recorder?.setExcludeZoomFromEntireSystemTap(excludeZoomFromCallDetection)
        if isMonitoringActivated {
            NotificationCenter.default.post(name: .refreshProcessMonitoring, object: nil)
        }
        if isRecording {
            recorder?.restartTapsForUpdatedProcessList()
        }
    }

    private func setupNotificationObservers() {
        notificationEvents.onMicrophoneProcessesChanged = { [weak self] processes in
            self?.handleMicrophoneProcessesChanged(processes)
        }
        notificationEvents.start()
    }

    private func handleMicrophoneProcessesChanged(_ newProcesses: [AudioProcess]) {
        let autoScanBool = true
        if newProcesses.isEmpty {
            print("[CallViewModel] micChanged → none isRecording=\(isRecording)")
        } else {
            let names = newProcesses.map { "\($0.name) pid=\($0.id)" }.joined(separator: ", ")
            print("[CallViewModel] micChanged → \(newProcesses.count): \(names) isRecording=\(isRecording)")
        }

        guard isMonitoringActivated else { return }
        guard autoScanBool else { return }

        let micIsActive = !newProcesses.isEmpty
        let newMicSnapshot = Set(newProcesses.map(\.id))

        if micIsActive {
            let now = Date()
            if !isRecording {
                let elapsed = now.timeIntervalSince(lastMicProcessChangeTime)
                guard elapsed >= micProcessChangeDebounce else {
                    print("[CallViewModel] micChanged debounce skip")
                    return
                }
            }
            lastMicProcessChangeTime = now
        }

        if isRecording && micIsActive {
            if let previous = lastMicProcessSnapshot, previous != newMicSnapshot {
                recorder?.restartTapsForUpdatedProcessList()
            }
            lastMicProcessSnapshot = newMicSnapshot
        } else if !micIsActive {
            lastMicProcessSnapshot = nil
        }

        if isRecording && !micIsActive && !isManuallyStartedRecording {
            print("[CallViewModel] mic inactive -> stop")
            stopRecording()
            return
        }

        if isManuallyStartedRecording { return }
        if isRecording { return }
        if let existingRecorder = recorder, existingRecorder.isRecording { return }

        if micIsActive {
            print("[CallViewModel] mic active -> start recording")
            startSystemWideRecording(manuallyTriggered: false)
        }
    }
}
