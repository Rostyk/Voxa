import AVFoundation
import CoreAudio
import Foundation

final class VOProcessTap {

    typealias InvalidationHandler = (VOProcessTap) -> Void

    let process: VOAudioProcess?
    private let objectIDs: [AudioObjectID]
    private let aggregateName: String
    let muteWhenRunning: Bool

    private(set) var errorMessage: String? = nil
    private(set) var activated = false

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private var invalidationHandler: InvalidationHandler?
    /// Stops IO callbacks as soon as `invalidate()` begins (avoids `bufferListNoCopy` UAF at call end).
    private var acceptsIOBuffers = true
    private let ioStateLock = NSLock()

    init(process: VOAudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.objectIDs = [process.objectID]
        self.aggregateName = "Tap-\(process.id)"
        self.muteWhenRunning = muteWhenRunning
    }

    init(objectIDs: [AudioObjectID], aggregateName: String, muteWhenRunning: Bool = false) {
        self.process = nil
        self.objectIDs = objectIDs
        self.aggregateName = aggregateName
        self.muteWhenRunning = muteWhenRunning
    }

    func activate() {
        guard !activated else { return }
        activated = true

        errorMessage = nil

        do {
            try prepare()
        } catch {
            print("Error activating tap: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        guard activated else { return }

        ioStateLock.lock()
        acceptsIOBuffers = false
        ioStateLock.unlock()

        defer { activated = false }

        invalidationHandler?(self)
        invalidationHandler = nil

        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { print("Warning: Failed to stop aggregate device: \(err)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { print("Warning: Failed to destroy device I/O proc: \(err)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { print("Warning: Failed to destroy aggregate device: \(err)") }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr { print("Warning: Failed to destroy audio tap: \(err)") }
            processTapID = .unknown
        }
    }

    private func prepare() throws {
        errorMessage = nil

        guard !objectIDs.isEmpty else {
            errorMessage = "No process object IDs to tap"
            throw VOAudioError.processTapCreationFailed("No process object IDs")
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            errorMessage = "Process tap creation failed with error \(err)"
            throw VOAudioError.processTapCreationFailed("Error code: \(err)")
        }

        processTapID = tapID

        let systemOutputID = try VOAudioUtils.readDefaultSystemOutputDevice()
        let outputUID = try VOAudioUtils.readDeviceUID(deviceID: systemOutputID)
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        tapStreamDescription = try VOAudioUtils.readAudioTapStreamDescription(tapID: tapID)

        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)

        guard err == noErr else {
            throw VOAudioError.aggregateDeviceCreationFailed("Error code: \(err)")
        }
    }

    func run(on queue: DispatchQueue, bufferCallback: @escaping (AVAudioPCMBuffer) -> Void, invalidationHandler: @escaping InvalidationHandler) throws {
        guard activated else { throw VOAudioError.tapNotActivated }
        guard self.invalidationHandler == nil else { throw VOAudioError.tapAlreadyRunning }

        errorMessage = nil
        self.invalidationHandler = invalidationHandler

        guard var streamDescription = tapStreamDescription else {
            throw VOAudioError.invalidStreamDescription
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw VOAudioError.failedToCreateAudioFormat
        }

        ioStateLock.lock()
        acceptsIOBuffers = true
        ioStateLock.unlock()

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }

            self.ioStateLock.lock()
            let accept = self.acceptsIOBuffers
            self.ioStateLock.unlock()
            guard accept else { return }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                return
            }

            // Copy before leaving the IO proc — `inInputData` is invalid after return (FaceTime hang-up, tap restart).
            guard let owned = buffer.voxaOwnedCopy() else { return }
            bufferCallback(owned)
        }

        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else {
            throw VOAudioError.deviceIOProcCreationFailed("Error code: \(err)")
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw VOAudioError.deviceStartFailed("Error code: \(err)")
        }
    }

    deinit {
        invalidate()
    }
}
