import Foundation
import CoreAudio
import AVFAudio
import AudioToolbox
import AppKit

typealias AUAudioProcessesScanCompletion = ([AUAudioProcess], AUAudioError?) -> Void
typealias AUAudioProcessesTapCallback = (AVAudioPCMBuffer) -> Void
typealias AUAudioProcessesChangeCallback = ([AUAudioProcess]) -> Void

final class AUAudioTapManager {

    private var activeTaps: [pid_t: AUProcessTap] = [:]
    private let audioQueue = DispatchQueue(label: "com.voxa.audiotap", qos: .userInitiated)

    private var scanTimer: Timer?
    private let scanInterval: TimeInterval = 8.0
    private var changeCallback: AUAudioProcessesChangeCallback?

    private let systemProcessNames = [
        "corespeechd", "coreaudiod", "audiomxd", "AUHostingServiceXPC_arrow",
        "systemsoundserverd", "UserEventAgent", "WindowServer", "loginwindow",
        "Dock", "NotificationCenter", "ControlCenter", "SystemUIServer",
        "VoiceOver", "SpeechSynthesisServer", "SiriNCService", "AssistantServices",
        "rapportd", "bluetoothd", "wirelessproxd"
    ]

    private let browserBundleIDs = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser"
    ]

    private let videoConferencingAppBundleIDs = [
        "us.zoom.xos",
        "com.zoom.client.mac",
        "com.microsoft.teams",
        "com.microsoft.skype",
        "com.cisco.webex",
        "com.google.meet",
        "net.whatsapp.WhatsApp",
        "com.openai.atlas"
    ]

    private let videoConferencingAppNames = [
        "zoom", "teams", "skype", "webex", "meet", "slack", "discord", "whatsapp", "whats app", "messenger", "atlas"
    ]

    private let browserNames = [
        "chrome", "safari", "firefox", "edge", "arc", "brave", "opera"
    ]

    init() {}

    func scan(onlyWithMicrophoneInput: Bool = true, completion: @escaping AUAudioProcessesScanCompletion) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let objectIdentifiers = try AUAudioUtils.readProcessList()
                let runningApps = NSWorkspace.shared.runningApplications
                let myPID = ProcessInfo.processInfo.processIdentifier

                var processes: [AUAudioProcess] = []
                var skippedSelf = 0
                var skippedSystem = 0
                var skippedNonConferencing = 0

                for objectID in objectIdentifiers {
                    let pid = try AUAudioUtils.readPID(objectID: objectID)

                    if pid == myPID {
                        skippedSelf += 1
                        continue
                    }

                    let process = try AUAudioProcess(objectID: objectID, runningApplications: runningApps)

                    if self.isSystemAudioProcess(process) {
                        skippedSystem += 1
                        continue
                    }

                    if !self.isWebBrowserOrVideoConferencing(process) {
                        skippedNonConferencing += 1
                        continue
                    }

                    if onlyWithMicrophoneInput {
                        let isRunningInput = AUAudioUtils.readProcessIsRunningInput(objectID: objectID)
                        if !isRunningInput {
                            skippedNonConferencing += 1
                            continue
                        }
                    }

                    _ = AUAudioUtils.readProcessIsRunning(objectID: objectID)
                    processes.append(process)
                }

                _ = (skippedSelf, skippedSystem, skippedNonConferencing)

                DispatchQueue.main.async {
                    completion(processes, nil)
                }

            } catch let error as AUAudioError {
                print("[AUAudioTapManager] Scan error: \(error)")
                DispatchQueue.main.async {
                    completion([], error)
                }
            } catch {
                print("[AUAudioTapManager] Scan error: \(error)")
                DispatchQueue.main.async {
                    completion([], .processTapCreationFailed(error.localizedDescription))
                }
            }
        }
    }

    private static let entireSystemTapKey: pid_t = 0

    @discardableResult
    func tap(_ scope: DetectionScope, _ tapCallback: @escaping AUAudioProcessesTapCallback) -> AUAudioError? {
        switch scope {
        case .all:
            return tapEntireSystem(tapCallback)
        case .processes(let processes):
            return tapProcesses(processes, tapCallback)
        }
    }

    private func tapEntireSystem(_ tapCallback: @escaping AUAudioProcessesTapCallback) -> AUAudioError? {
        if activeTaps[Self.entireSystemTapKey] != nil {
            return .tapAlreadyRunning
        }

        do {
            var objectIDs = try AUAudioUtils.readProcessList()
            let myPID = ProcessInfo.processInfo.processIdentifier
            objectIDs = objectIDs.filter { id in
                (try? AUAudioUtils.readPID(objectID: id)) != myPID
            }
            if objectIDs.isEmpty {
                return .processTapCreationFailed("No audio processes available for entire-system tap")
            }

            let tap = AUProcessTap(objectIDs: objectIDs, aggregateName: "Tap-Entire")
            tap.activate()
            if let errorMessage = tap.errorMessage {
                return .processTapCreationFailed(errorMessage)
            }
            try tap.run(on: audioQueue, bufferCallback: tapCallback) { [weak self] _ in
                self?.activeTaps.removeValue(forKey: Self.entireSystemTapKey)
            }
            activeTaps[Self.entireSystemTapKey] = tap
            return nil
        } catch let error as AUAudioError {
            return error
        } catch {
            return .processTapCreationFailed(error.localizedDescription)
        }
    }

    private func tapProcesses(_ processes: [AUAudioProcess], _ tapCallback: @escaping AUAudioProcessesTapCallback) -> AUAudioError? {
        if processes.isEmpty {
            return .processTapCreationFailed("No processes in scope")
        }
        for process in processes {
            if activeTaps[process.id] != nil {
                return .tapAlreadyRunning
            }
        }

        for process in processes {
            let tap = AUProcessTap(process: process)
            tap.activate()
            if let errorMessage = tap.errorMessage {
                removeTaps(for: processes)
                return .processTapCreationFailed(errorMessage)
            }
            do {
                try tap.run(on: audioQueue, bufferCallback: tapCallback) { [weak self] _ in
                    self?.activeTaps.removeValue(forKey: process.id)
                }
                activeTaps[process.id] = tap
            } catch let error as AUAudioError {
                removeTaps(for: processes)
                return error
            } catch {
                removeTaps(for: processes)
                return .processTapCreationFailed(error.localizedDescription)
            }
        }
        return nil
    }

    private func removeTaps(for processes: [AUAudioProcess]) {
        for process in processes {
            removeTap(process)
        }
    }

    func removeTap(_ process: AUAudioProcess) {
        guard let tap = activeTaps[process.id] else {
            return
        }
        tap.invalidate()
        activeTaps.removeValue(forKey: process.id)
    }

    func removeEntireTap() {
        guard let tap = activeTaps[Self.entireSystemTapKey] else {
            return
        }
        tap.invalidate()
        activeTaps.removeValue(forKey: Self.entireSystemTapKey)
    }

    func removeAllTaps() {
        for (_, tap) in activeTaps {
            tap.invalidate()
        }
        activeTaps.removeAll()
    }

    func startMonitoring(onlyWithMicrophoneInput: Bool = true, onChange: @escaping AUAudioProcessesChangeCallback) {
        guard scanTimer == nil else {
            print("[AUAudioTapManager] Already monitoring")
            return
        }

        monitoringOnlyWithMicrophoneInput = onlyWithMicrophoneInput
        print("[AUAudioTapManager] Starting process monitoring (8s polling, onlyWithMicrophoneInput: \(onlyWithMicrophoneInput))")

        changeCallback = onChange
        performScan()

        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.performScan()
        }

        if let timer = scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[AUAudioTapManager] Process monitoring started")
    }

    func stopMonitoring() {
        guard scanTimer != nil else {
            return
        }

        print("[AUAudioTapManager] Stopping process monitoring")

        scanTimer?.invalidate()
        scanTimer = nil
        changeCallback = nil

        print("[AUAudioTapManager] Process monitoring stopped")
    }

    func updateScanFilter(onlyWithMicrophoneInput: Bool) {
        monitoringOnlyWithMicrophoneInput = onlyWithMicrophoneInput
        if changeCallback != nil {
            performScan()
        }
    }

    private var monitoringOnlyWithMicrophoneInput: Bool = true

    private func performScan() {
        guard let callback = changeCallback else { return }

        scan(onlyWithMicrophoneInput: monitoringOnlyWithMicrophoneInput) { processes, error in
            if let error = error {
                print("[AUAudioTapManager] Scan error: \(error)")
            }
            callback(processes)
        }
    }

    private func isWebBrowserOrVideoConferencing(_ process: AUAudioProcess) -> Bool {
        let name = process.name.lowercased()

        for videoConfName in videoConferencingAppNames {
            if name.contains(videoConfName.lowercased()) {
                return true
            }
        }

        for browserName in browserNames {
            if name.contains(browserName) {
                return true
            }
        }

        if let bundleID = process.bundleID {
            let bundleIDLower = bundleID.lowercased()

            for browserBundleID in browserBundleIDs {
                if bundleIDLower.contains(browserBundleID.lowercased()) {
                    return true
                }
            }

            for confBundleID in videoConferencingAppBundleIDs {
                if bundleIDLower.contains(confBundleID.lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    private func isSystemAudioProcess(_ process: AUAudioProcess) -> Bool {
        let processNameLower = process.name.lowercased()

        for systemName in systemProcessNames {
            if processNameLower == systemName.lowercased() {
                return true
            }
        }

        if processNameLower.contains("audio") ||
            processNameLower.contains("coremedia") ||
            processNameLower.contains("airplay") ||
            processNameLower.contains("siri") ||
            processNameLower.contains("speech") ||
            processNameLower.contains("voiceover") ||
            processNameLower.contains("tcc") ||
            processNameLower.contains("mediaremote") ||
            processNameLower.contains("avaudio") {
            return true
        }

        return false
    }

    deinit {
        stopMonitoring()
        removeAllTaps()
    }
}
