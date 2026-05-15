import AppKit
import AudioToolbox
import Combine
import Foundation
import VoxaSDK

@Observable
final class AudioProcessManager {

    private var cancellables = Set<AnyCancellable>()
    private let sdkDetector: VoxaAudioKit?

    private(set) var activeAudioProcesses: [AudioProcess] = []
    private(set) var activeMicrophoneProcesses: [AudioProcess] = []
    private(set) var foregroundProcess: AudioProcess?
    private var isActivated = false

    init() {
        sdkDetector = VoxaAudioKit()
        setupNotificationObservers()
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        print("[AudioProcessManager] activate")
        startMonitoring()
        updateProcessLists()
    }

    private func mapProcess(_ sdkProcess: VOAudioProcess) -> AudioProcess {
        AudioProcess(
            id: sdkProcess.id,
            kind: sdkProcess.kind == .app ? .app : .process,
            name: sdkProcess.name,
            audioActive: sdkProcess.audioActive,
            bundleID: sdkProcess.bundleID,
            bundleURL: sdkProcess.bundleURL,
            objectID: sdkProcess.objectID
        )
    }

    func refreshProcessList() {
        activeAudioProcesses = []
        activeMicrophoneProcesses = []
        foregroundProcess = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.updateProcessLists()
        }
    }

    private func setupNotificationObservers() {
        NSWorkspace.shared
            .publisher(for: \.frontmostApplication, options: [.initial, .new])
            .sink { [weak self] _ in
                self?.updateProcessLists()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .refreshProcessMonitoring)
            .sink { [weak self] _ in
                self?.updateProcessLists()
            }
            .store(in: &cancellables)
    }

    private func startMonitoring() {
        guard let sdkDetector else {
            print("[AudioProcessManager] SDK unavailable")
            return
        }

        sdkDetector.startMonitoring(onlyWithMicrophoneInput: false) { [weak self] sdkProcesses in
            guard let self else { return }
            self.applySDKAudioProcessUpdate(sdkProcesses)
        }
    }

    private func updateProcessLists() {
        guard isActivated else { return }
        guard let sdkDetector else { return }
        sdkDetector.scan(onlyWithMicrophoneInput: false) { [weak self] sdkProcesses, _ in
            self?.applySDKAudioProcessUpdate(sdkProcesses)
        }
    }

    private func applySDKAudioProcessUpdate(_ sdkProcesses: [VOAudioProcess]) {
        let mappedAudio = sdkProcesses.map(mapProcess)
        let newForegroundProcess: AudioProcess?
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            newForegroundProcess = mappedAudio.first(where: { $0.id == frontApp.processIdentifier })
        } else {
            newForegroundProcess = nil
        }

        guard let sdkDetector else { return }
        sdkDetector.scan(onlyWithMicrophoneInput: true) { [weak self] micSDKProcesses, error in
            guard let self else { return }
            let mappedMic = micSDKProcesses.map(self.mapProcess)
            let previousMicProcesses = self.activeMicrophoneProcesses

            self.activeAudioProcesses = mappedAudio
            self.activeMicrophoneProcesses = mappedMic
            self.foregroundProcess = newForegroundProcess

            Self.logMicProcessList(mappedMic, sdkError: error)

            if previousMicProcesses != mappedMic {
                print("[AudioProcessManager] mic list changed (\(previousMicProcesses.count) -> \(mappedMic.count)), posting notification")
                NotificationCenter.default.post(
                    name: .microphoneProcessesChanged,
                    object: self,
                    userInfo: ["processes": mappedMic]
                )
            } else {
                print("[AudioProcessManager] mic list unchanged (\(mappedMic.count)), no notification")
            }
        }
    }

    private static func logMicProcessList(_ processes: [AudioProcess], sdkError: VOAudioError?) {
        if let sdkError {
            print("[AudioProcessManager] mic scan SDK error: \(sdkError)")
        }
        if processes.isEmpty {
            print("[AudioProcessManager] activeMicrophoneProcesses: (empty)")
            return
        }
        print("[AudioProcessManager] activeMicrophoneProcesses (\(processes.count)):")
        for process in processes {
            let bundle = process.bundleID ?? "—"
            print("[AudioProcessManager]   pid=\(process.id) name=\"\(process.name)\" bundle=\(bundle) audioActive=\(process.audioActive)")
        }
    }

    deinit {
        sdkDetector?.stopMonitoring()
        cancellables.removeAll()
    }
}
