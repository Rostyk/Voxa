import CoreAudio
import Foundation

/// Lists macOS audio input devices (Core Audio) — used for virtual-mic presence checks.
enum SystemInputDeviceCatalog {

    static let voxaVirtualMicNameHint = "voxa virtual"

    static func inputDeviceNames() -> [String] {
        audioInputDeviceIDs().compactMap { deviceName($0) }
    }

    static func containsVoxaVirtualMicrophone() -> Bool {
        inputDeviceNames().contains { isVoxaVirtualMicName($0) }
    }

    static func isVoxaVirtualMicName(_ name: String) -> Bool {
        name.lowercased().contains(voxaVirtualMicNameHint)
    }

    // MARK: - Core Audio

    private static func audioInputDeviceIDs() -> [AudioDeviceID] {
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
        return ids.filter(deviceHasInput)
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return false }
        return dataSize > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
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
}
