import AppKit
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

typealias VOAudioProcessesScanCompletion = ([VOAudioProcess], VOAudioError?) -> Void
typealias VOAudioProcessesTapCallback = (AVAudioPCMBuffer) -> Void
typealias VOAudioProcessesChangeCallback = ([VOAudioProcess]) -> Void

final class VOAudioTapManager {

    private var activeTaps: [pid_t: VOProcessTap] = [:]
    private let audioQueue = DispatchQueue(label: "com.voxa.audiotap", qos: .userInitiated)

    private var scanTimer: Timer?
    private let scanInterval: TimeInterval = 8.0
    private var changeCallback: VOAudioProcessesChangeCallback?

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
        "com.apple.FaceTime",
        "com.apple.facetime",
        "com.apple.avconferenced",
        "com.apple.TelephonyUtilities",
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
        "facetime", "avconference", "callservices", "zoom", "teams", "skype", "webex", "meet", "slack", "discord", "whatsapp", "whats app", "messenger", "atlas"
    ]

    private let browserNames = [
        "chrome", "safari", "firefox", "edge", "arc", "brave", "opera"
    ]

    init() {}

    func scan(onlyWithMicrophoneInput: Bool = true, completion: @escaping VOAudioProcessesScanCompletion) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let objectIdentifiers = try VOAudioUtils.readProcessList()
                let runningApps = NSWorkspace.shared.runningApplications
                let myPID = ProcessInfo.processInfo.processIdentifier

                var processes: [VOAudioProcess] = []
                var skippedSelf = 0
                var skippedSystem = 0
                var skippedNonConferencing = 0
                var skippedNoMicInput = 0

                for objectID in objectIdentifiers {
                    let pid = try VOAudioUtils.readPID(objectID: objectID)

                    if pid == myPID {
                        skippedSelf += 1
                        continue
                    }

                    let process = try VOAudioProcess(objectID: objectID, runningApplications: runningApps)
                    let isRunningInput = VOAudioUtils.readProcessIsRunningInput(objectID: objectID)
                    let isSystem = self.isSystemAudioProcess(process)
                    let isAllowlisted = self.isWebBrowserOrVideoConferencing(process)

                    if isSystem {
                        skippedSystem += 1
                        continue
                    }

                    if !isAllowlisted {
                        skippedNonConferencing += 1
                        continue
                    }

                    if onlyWithMicrophoneInput {
                        if !isRunningInput {
                            skippedNoMicInput += 1
                            continue
                        }
                    }

                    _ = VOAudioUtils.readProcessIsRunning(objectID: objectID)
                    processes.append(process)
                }

                DispatchQueue.main.async {
                    completion(processes, nil)
                }

            } catch let error as VOAudioError {
                print("[VOAudioTapManager] Scan error: \(error)")
                DispatchQueue.main.async {
                    completion([], error)
                }
            } catch {
                print("[VOAudioTapManager] Scan error: \(error)")
                DispatchQueue.main.async {
                    completion([], .processTapCreationFailed(error.localizedDescription))
                }
            }
        }
    }

    private static let entireSystemTapKey: pid_t = 0

    @discardableResult
    func tap(_ scope: ScanScope, _ tapCallback: @escaping VOAudioProcessesTapCallback) -> VOAudioError? {
        switch scope {
        case .all:
            return tapEntireSystem(tapCallback)
        case .processes(let processes):
            return tapProcesses(processes, tapCallback)
        }
    }

    private func tapEntireSystem(_ tapCallback: @escaping VOAudioProcessesTapCallback) -> VOAudioError? {
        if activeTaps[Self.entireSystemTapKey] != nil {
            return .tapAlreadyRunning
        }

        do {
            var objectIDs = try VOAudioUtils.readProcessList()
            let myPID = ProcessInfo.processInfo.processIdentifier
            objectIDs = objectIDs.filter { id in
                (try? VOAudioUtils.readPID(objectID: id)) != myPID
            }
            if objectIDs.isEmpty {
                return .processTapCreationFailed("No audio processes available for entire-system tap")
            }

            let tap = VOProcessTap(objectIDs: objectIDs, aggregateName: "Tap-Entire")
            tap.activate()
            if let errorMessage = tap.errorMessage {
                return .processTapCreationFailed(errorMessage)
            }
            try tap.run(on: audioQueue, bufferCallback: tapCallback) { [weak self] _ in
                self?.activeTaps.removeValue(forKey: Self.entireSystemTapKey)
            }
            activeTaps[Self.entireSystemTapKey] = tap
            return nil
        } catch let error as VOAudioError {
            return error
        } catch {
            return .processTapCreationFailed(error.localizedDescription)
        }
    }

    private func tapProcesses(_ processes: [VOAudioProcess], _ tapCallback: @escaping VOAudioProcessesTapCallback) -> VOAudioError? {
        if processes.isEmpty {
            return .processTapCreationFailed("No processes in scope")
        }
        for process in processes {
            if activeTaps[process.id] != nil {
                return .tapAlreadyRunning
            }
        }

        for process in processes {
            let tap = VOProcessTap(process: process)
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
            } catch let error as VOAudioError {
                removeTaps(for: processes)
                return error
            } catch {
                removeTaps(for: processes)
                return .processTapCreationFailed(error.localizedDescription)
            }
        }
        return nil
    }

    private func removeTaps(for processes: [VOAudioProcess]) {
        for process in processes {
            removeTap(process)
        }
    }

    func removeTap(_ process: VOAudioProcess) {
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

    func startMonitoring(onlyWithMicrophoneInput: Bool = true, onChange: @escaping VOAudioProcessesChangeCallback) {
        guard scanTimer == nil else {
            print("[VOAudioTapManager] Already monitoring")
            return
        }

        monitoringOnlyWithMicrophoneInput = onlyWithMicrophoneInput
        print("[VOAudioTapManager] Starting process monitoring (8s polling, onlyWithMicrophoneInput: \(onlyWithMicrophoneInput))")

        changeCallback = onChange
        performScan()

        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.performScan()
        }

        if let timer = scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[VOAudioTapManager] Process monitoring started")
    }

    func stopMonitoring() {
        guard scanTimer != nil else {
            return
        }

        print("[VOAudioTapManager] Stopping process monitoring")

        scanTimer?.invalidate()
        scanTimer = nil
        changeCallback = nil

        print("[VOAudioTapManager] Process monitoring stopped")
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
                print("[VOAudioTapManager] Scan error: \(error)")
            }
            callback(processes)
        }
    }

    private func isWebBrowserOrVideoConferencing(_ process: VOAudioProcess) -> Bool {
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

    private func isSystemAudioProcess(_ process: VOAudioProcess) -> Bool {
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
