import AudioToolbox
import Darwin
import Foundation

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !isUnknown }
}

struct AUAudioUtils {

    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID.system, &address, 0, nil, &dataSize)

        guard err == noErr else {
            throw AUAudioError.processTapCreationFailed("Error reading process list data size: \(err)")
        }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &dataSize, &value)

        guard err == noErr else {
            throw AUAudioError.processTapCreationFailed("Error reading process list: \(err)")
        }

        return value
    }

    static func readPID(objectID: AudioObjectID) throws -> pid_t {
        try readProperty(objectID: objectID, selector: kAudioProcessPropertyPID, defaultValue: pid_t(-1))
    }

    static func readProcessBundleID(objectID: AudioObjectID) -> String? {
        if let result = try? readStringProperty(objectID: objectID, selector: kAudioProcessPropertyBundleID) {
            return result.isEmpty ? nil : result
        }
        return nil
    }

    static func readProcessIsRunning(objectID: AudioObjectID) -> Bool {
        (try? readBoolProperty(objectID: objectID, selector: kAudioProcessPropertyIsRunning)) ?? false
    }

    static func readProcessIsRunningInput(objectID: AudioObjectID) -> Bool {
        let value: Int = (try? readProperty(objectID: objectID, selector: kAudioProcessPropertyIsRunningInput, defaultValue: 0)) ?? 0
        return value == 1
    }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try readProperty(objectID: AudioObjectID.system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    static func readDeviceUID(deviceID: AudioDeviceID) throws -> String {
        try readStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func readAudioTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try readProperty(objectID: tapID, selector: kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    static func processInfo(for pid: pid_t) -> (name: String, path: String)? {
        let nameBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))

        defer {
            nameBuffer.deallocate()
            pathBuffer.deallocate()
        }

        let nameLength = proc_name(pid, nameBuffer, UInt32(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))

        guard nameLength > 0, pathLength > 0 else {
            return nil
        }

        let name = String(cString: nameBuffer)
        let path = String(cString: pathBuffer)

        return (name, path)
    }

    private static func readProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw AUAudioError.processTapCreationFailed("Error reading data size for \(selector): \(err)")
        }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }

        guard err == noErr else {
            throw AUAudioError.processTapCreationFailed("Error reading data for \(selector): \(err)")
        }

        return value
    }

    private static func readStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        let cfString: CFString = try readProperty(objectID: objectID, selector: selector, scope: scope, element: element, defaultValue: "" as CFString)
        return cfString as String
    }

    private static func readBoolProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Bool {
        let value: Int = try readProperty(objectID: objectID, selector: selector, scope: scope, element: element, defaultValue: 0)
        return value == 1
    }
}
