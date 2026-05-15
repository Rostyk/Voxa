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

    var activeMicrophoneProcesses: [AudioProcess] { audioProcessManager.activeMicrophoneProcesses }

    private init() {
        setupNotificationObservers()
    }

    func activate() {
        guard !isMonitoringActivated else { return }
        isMonitoringActivated = true
        audioProcessManager.activate()
        startRefreshTimer()
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
        scheduleVirtualMicFeederStart()
    }

    /// Start virtual-mic capture after system-audio taps are up (early start races and never receives callbacks).
    private func scheduleVirtualMicFeederStart() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            VoxaVirtualMicFeeder.shared.startIfNeeded()
        }
    }

    func stopRecording(userInitiated: Bool = false) {
        print("[CallViewModel] stopRecording (userInitiated=\(userInitiated))")
        recorder?.stop(userInitiated: userInitiated)
        isRecording = false
        isManuallyStartedRecording = false
        isSettingUpRecording = false
        lastMicProcessSnapshot = nil
    }

    private func setupNotificationObservers() {
        notificationEvents.onMicrophoneProcessesChanged = { [weak self] processes in
            self?.handleMicrophoneProcessesChanged(processes)
        }
        notificationEvents.start()
    }

    private func handleMicrophoneProcessesChanged(_ newProcesses: [AudioProcess]) {
        let autoScanBool = true
        print("[CallViewModel] micChanged count=\(newProcesses.count) autoScan=\(autoScanBool) isRecording=\(isRecording) activated=\(isMonitoringActivated)")

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
