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
    private var ring: VoxaMicSharedMemory?
    private var liveCaptureDeviceName: String?
    private var isRunning = false
    private var ringInjectionCount = 0
    private var lastLoggedHALWritesToRing: Bool?
    /// When `true`, HAL capture runs but does not write to the ring (user muted the virtual-mic output).
    private(set) var isOutputMuted = false

    private init() {}

    /// Mute/unmute live voice to the virtual mic. Default at call start: **unmuted** (`false`).
    func setOutputMuted(_ muted: Bool) {
        stateLock.lock()
        let was = isOutputMuted
        isOutputMuted = muted
        syncHALWritesToRingLocked()
        stateLock.unlock()
        print("[VoxaMic] setOutputMuted \(was) → \(muted) feederRunning=\(isRunning)")
        publishOutputMuteState()
    }

    func startIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }
        isOutputMuted = false
        tryStartLocked()
    }

    func restartIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isRunning { stopLocked() }
        isOutputMuted = false
        tryStartLocked()
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    /// Pauses HAL→ring while `body` runs (e.g. TTS), then restores prior mute state.
    func performRingInjection(_ body: @escaping (VoxaMicSharedMemory) async throws -> Void) async throws {
        stateLock.lock()
        if !isRunning {
            print("[VoxaMic] performRingInjection: ring-only (HAL not started — TTS without mic capture)")
            guard ensureRingMappedLocked(resetIfNew: false) != nil else {
                stateLock.unlock()
                print("[VoxaMic] performRingInjection FAILED — could not open ring at \(VoxaMicRingLayout.ringPath)")
                throw VoxaVirtualMicFeederError.ringUnavailable
            }
        }
        guard let ring else {
            stateLock.unlock()
            print("[VoxaMic] performRingInjection FAILED — ring unavailable isRunning=\(isRunning)")
            throw VoxaVirtualMicFeederError.ringUnavailable
        }
        ringInjectionCount += 1
        if ringInjectionCount == 1 {
            VoxaMicRingWriter.reset(ring)
            print("[VoxaMic] performRingInjection reset ring (sync driver read cursor)")
        }
        syncHALWritesToRingLocked()
        let injectionIndex = ringInjectionCount
        let feederWasRunning = isRunning
        let writeIndexBefore = ring.header.pointee.writeFrameIndex
        stateLock.unlock()

        print(
            "[VoxaMic] performRingInjection START #\(injectionIndex) ringPath=\(VoxaMicRingLayout.ringPath) writeIndex=\(writeIndexBefore) feederRunning=\(feederWasRunning)"
        )

        defer {
            stateLock.lock()
            ringInjectionCount = max(0, ringInjectionCount - 1)
            syncHALWritesToRingLocked()
            let writeIndexAfter = ring.header.pointee.writeFrameIndex
            let remaining = ringInjectionCount
            stateLock.unlock()
            print(
                "[VoxaMic] performRingInjection END #\(injectionIndex) remainingInjections=\(remaining) writeIndex=\(writeIndexAfter)"
            )
        }

        do {
            try await body(ring)
            print("[VoxaMic] performRingInjection body completed OK #\(injectionIndex)")
        } catch {
            print("[VoxaMic] performRingInjection body FAILED #\(injectionIndex): \(error)")
            throw error
        }
    }

    @discardableResult
    private func ensureRingMappedLocked(resetIfNew: Bool) -> VoxaMicSharedMemory? {
        if let ring { return ring }
        guard let ring = VoxaMicSharedMemory() else {
            print("[VoxaMic] Failed to open ring file \(VoxaMicRingLayout.ringPath)")
            return nil
        }
        self.ring = ring
        if resetIfNew {
            VoxaMicRingWriter.reset(ring)
            print("[VoxaMic] Ring reset for new capture session")
        }
        return ring
    }

    private func syncHALWritesToRingLocked() {
        let shouldWrite = !isOutputMuted && ringInjectionCount == 0
        halCapture?.setWritesToRing(shouldWrite)
        if lastLoggedHALWritesToRing != shouldWrite {
            lastLoggedHALWritesToRing = shouldWrite
            print("[VoxaMic] HAL writesToRing=\(shouldWrite) (outputMuted=\(isOutputMuted) ringInjections=\(ringInjectionCount))")
        }
    }

    private func tryStartLocked() {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            print("[VoxaMic] Feeder not started — grant microphone access for Voxa")
            publishStatus(running: false, captureName: nil, detail: "Allow microphone access for Voxa.")
            return
        }

        guard ensureRingMappedLocked(resetIfNew: true) != nil, let ring else {
            print("[VoxaMic] Failed to open ring file \(VoxaMicRingLayout.ringPath)")
            publishStatus(running: false, captureName: nil, detail: "Reinstall VoxaMic.driver (AudioDriver/install.sh).")
            return
        }
        startLiveCaptureLocked(ring: ring)
        syncHALWritesToRingLocked()
        publishOutputMuteState()
    }

    private func startLiveCaptureLocked(ring: VoxaMicSharedMemory) {
        let defaultInput = currentDefaultInputDevice()
        guard let captureDevice = resolvePhysicalCaptureDevice(preferredOver: defaultInput) else {
            isRunning = false
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
            liveCaptureDeviceName = captureDevice.name
            isRunning = true
            log.info("Voxa virtual mic feeder started (HAL)")
            let detail = statusDetail ?? "Your microphone is sent to the virtual mic when unmuted."
            publishStatus(running: true, captureName: captureDevice.name, detail: detail)
        } catch {
            log.error("HAL capture failed: \(String(describing: error))")
            print("[VoxaMic] HAL capture failed: \(error)")
            isRunning = false
            publishStatus(running: false, captureName: captureDevice.name, detail: "Microphone capture failed.")
        }
    }

    private func stopLocked() {
        halCapture?.stop()
        halCapture = nil
        ring = nil
        liveCaptureDeviceName = nil
        isRunning = false
        ringInjectionCount = 0
        isOutputMuted = false
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
                detailMessage: detail,
                isOutputMuted: isOutputMuted,
                muteToggleAvailable: running
            )
        }
    }

    private func publishOutputMuteState() {
        Task { @MainActor in
            VoxaVirtualMicFeederStatus.shared.setOutputMuted(isOutputMuted)
        }
    }
}
