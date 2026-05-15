import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures a physical microphone via HAL AudioUnit and writes PCM into the ring for `VoxaMic.driver`.
final class VoxaVirtualMicFeeder: @unchecked Sendable {
    static let shared = VoxaVirtualMicFeeder()

    private let log = Logger(subsystem: "com.aurigin.test.Voxa", category: "VoxaVirtualMic")
    private let stateLock = NSLock()
    private var halCapture: VoxaMicHALCapture?
    private var wavFeeder: VoxaMicWAVFileFeeder?
    private var isRunning = false

    private init() {}

    func startIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }
        tryStartLocked()
    }

    func restartIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isRunning { stopLocked() }
        tryStartLocked()
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func tryStartLocked() {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            print("[VoxaMic] Feeder not started — grant microphone access for Voxa")
            publishStatus(running: false, captureName: nil, detail: "Allow microphone access for Voxa.")
            return
        }

        guard let ring = VoxaMicSharedMemory() else {
            print("[VoxaMic] Failed to open ring file \(VoxaMicRingLayout.ringPath)")
            publishStatus(running: false, captureName: nil, detail: "Reinstall VoxaMic.driver (AudioDriver/install.sh).")
            return
        }

        VoxaMicRingWriter.reset(ring)
        print("[VoxaMic] Ring reset for new capture session")

        if VoxaMicTemporaryTest.feedProjectAudioWAV {
            startTemporaryWAVFeeder(ring: ring)
            return
        }

        let defaultInput = currentDefaultInputDevice()
        guard let captureDevice = resolvePhysicalCaptureDevice(preferredOver: defaultInput) else {
            publishStatus(running: false, captureName: nil, detail: "No physical microphone found.")
            return
        }

        var statusDetail: String?
        if let defaultInput, isVirtualMicDevice(defaultInput) {
            statusDetail = "macOS default is “\(defaultInput.name)”. Voxa captures “\(captureDevice.name)”. Use Voxa Virtual Microphone only in Meet/Chrome."
            print("[VoxaMic] Default input is virtual — capturing '\(captureDevice.name)' instead")
        }

        let capture = VoxaMicHALCapture()
        do {
            try capture.start(captureDeviceID: captureDevice.id, ring: ring)
            halCapture = capture
            isRunning = true
            log.info("Voxa virtual mic feeder started (HAL)")
            publishStatus(running: true, captureName: captureDevice.name, detail: statusDetail)
        } catch {
            log.error("HAL capture failed: \(String(describing: error))")
            print("[VoxaMic] HAL capture failed: \(error)")
            publishStatus(running: false, captureName: captureDevice.name, detail: "Microphone capture failed.")
        }
    }

    private func startTemporaryWAVFeeder(ring: VoxaMicSharedMemory) {
        guard let url = VoxaMicTemporaryTest.projectAudioWAVURL else {
            print("[VoxaMic] TEMP: Audio.wav not found — place it in the Voxa repo root (next to Voxa.xcodeproj)")
            publishStatus(running: false, captureName: nil, detail: "TEMP: Audio.wav not found.")
            return
        }

        let feeder = VoxaMicWAVFileFeeder()
        do {
            try feeder.start(url: url, ring: ring)
            wavFeeder = feeder
            isRunning = true
            publishStatus(
                running: true,
                captureName: "Audio.wav (TEMP)",
                detail: "Looping Audio.wav into virtual mic. Set feedProjectAudioWAV = false for real mic."
            )
        } catch {
            print("[VoxaMic] TEMP WAV feeder failed: \(error)")
            publishStatus(running: false, captureName: nil, detail: "TEMP: failed to load Audio.wav.")
        }
    }

    private func stopLocked() {
        wavFeeder?.stop()
        wavFeeder = nil
        halCapture?.stop()
        halCapture = nil
        isRunning = false
        print("[VoxaMic] Feeder stopped")
        publishStatus(running: false, captureName: nil, detail: nil)
    }

    private struct AudioInputDevice {
        let id: AudioDeviceID
        let name: String
    }

    private func resolvePhysicalCaptureDevice(preferredOver defaultDevice: AudioInputDevice?) -> AudioInputDevice? {
        let candidates = enumerateInputDevices().filter { !isVirtualMicDevice($0) }
        guard !candidates.isEmpty else { return nil }
        if let defaultDevice, !isVirtualMicDevice(defaultDevice) { return defaultDevice }
        return candidates.sorted { scoreDeviceName($0.name) > scoreDeviceName($1.name) }.first
    }

    private func scoreDeviceName(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("macbook") || lower.contains("built-in") { return 100 }
        if lower.contains("headset") || lower.contains("airpods") { return 80 }
        return 10
    }

    private func enumerateInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard deviceHasInput(id), let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, name: name)
        }
    }

    private func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return false }
        return dataSize > 0
    }

    private func currentDefaultInputDevice() -> AudioInputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0,
            let name = deviceName(deviceID)
        else { return nil }
        return AudioInputDevice(id: deviceID, name: name)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name as String
    }

    private func isVirtualMicDevice(_ device: AudioInputDevice) -> Bool { isVirtualMicName(device.name) }

    private func isVirtualMicName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("voxa") || lower.contains("sinewave") || lower.contains("blackhole")
    }

    private func publishStatus(running: Bool, captureName: String?, detail: String?) {
        Task { @MainActor in
            VoxaVirtualMicFeederStatus.shared.apply(
                running: running,
                captureDeviceName: captureName,
                detailMessage: detail
            )
        }
    }
}
