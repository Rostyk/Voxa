import Foundation
import CoreAudio
import AVFoundation

final class AUProcessTap {

    typealias InvalidationHandler = (AUProcessTap) -> Void

    let process: AUAudioProcess?
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

    init(process: AUAudioProcess, muteWhenRunning: Bool = false) {
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
            throw AUAudioError.processTapCreationFailed("No process object IDs")
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            errorMessage = "Process tap creation failed with error \(err)"
            throw AUAudioError.processTapCreationFailed("Error code: \(err)")
        }

        processTapID = tapID

        let systemOutputID = try AUAudioUtils.readDefaultSystemOutputDevice()
        let outputUID = try AUAudioUtils.readDeviceUID(deviceID: systemOutputID)
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

        tapStreamDescription = try AUAudioUtils.readAudioTapStreamDescription(tapID: tapID)

        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)

        guard err == noErr else {
            throw AUAudioError.aggregateDeviceCreationFailed("Error code: \(err)")
        }
    }

    func run(on queue: DispatchQueue, bufferCallback: @escaping AUAudioProcessesTapCallback, invalidationHandler: @escaping InvalidationHandler) throws {
        guard activated else { throw AUAudioError.tapNotActivated }
        guard self.invalidationHandler == nil else { throw AUAudioError.tapAlreadyRunning }

        errorMessage = nil
        self.invalidationHandler = invalidationHandler

        guard var streamDescription = tapStreamDescription else {
            throw AUAudioError.invalidStreamDescription
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AUAudioError.failedToCreateAudioFormat
        }

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard self != nil else { return }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                return
            }

            bufferCallback(buffer)
        }

        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else {
            throw AUAudioError.deviceIOProcCreationFailed("Error code: \(err)")
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw AUAudioError.deviceStartFailed("Error code: \(err)")
        }
    }

    deinit {
        invalidate()
    }
}
