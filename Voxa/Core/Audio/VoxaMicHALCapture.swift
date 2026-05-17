import AVFoundation
import CoreAudio
import Foundation

/// Captures a physical input device via `kAudioUnitSubType_HALOutput` (Apple TN2091).
/// Used instead of `AVAudioEngine`, which conflicts with system-audio HAL taps.
final class VoxaMicHALCapture: @unchecked Sendable {
    private var audioUnit: AudioUnit?
    private var inputBus: UInt32 = 1
    private var captureFormat: AVAudioFormat?
    private var ring: VoxaMicSharedMemory?
    private let queue = DispatchQueue(label: "com.aurigin.test.Voxa.VoxaMicHALCapture", qos: .userInitiated)
    private var isCapturing = false
    private let writeLock = NSLock()
    /// When `false`, HAL still captures (mic stays active) but PCM is not written to the virtual-mic ring.
    private var writesToRing = true

    func setWritesToRing(_ enabled: Bool) {
        writeLock.lock()
        writesToRing = enabled
        writeLock.unlock()
    }

    func start(captureDeviceID: AudioDeviceID, ring: VoxaMicSharedMemory) throws {
        try queue.sync {
            try startOnQueue(captureDeviceID: captureDeviceID, ring: ring)
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue(captureDeviceID: AudioDeviceID, ring: VoxaMicSharedMemory) throws {
        stopOnQueue()
        self.ring = ring
        setWritesToRing(true)

        guard var streamDescription = Self.deviceStreamDescription(deviceID: captureDeviceID) else {
            throw CaptureError.noStreamFormat
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.noStreamFormat
        }
        captureFormat = format

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw CaptureError.componentNotFound
        }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            throw CaptureError.instanceFailed
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else { throw CaptureError.enableInputFailed }

        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else { throw CaptureError.disableOutputFailed }

        var deviceID = captureDeviceID
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { throw CaptureError.setDeviceFailed }

        inputBus = 1
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus,
            &streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else { throw CaptureError.setFormatFailed }

        var callback = AURenderCallbackStruct(
            inputProc: VoxaMicHALCapture.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else { throw CaptureError.setCallbackFailed }

        guard AudioUnitInitialize(unit) == noErr else { throw CaptureError.initializeFailed }
        guard AudioOutputUnitStart(unit) == noErr else { throw CaptureError.startFailed }

        audioUnit = unit
        isCapturing = true
        print("[VoxaMic] HAL capture \(Int(format.sampleRate)) Hz \(format.channelCount)ch → ring \(VoxaMicRingLayout.sampleRate) Hz stereo")
    }

    private func stopOnQueue() {
        guard let unit = audioUnit else {
            ring = nil
            isCapturing = false
            return
        }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        ring = nil
        captureFormat = nil
        isCapturing = false
    }

    private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, _, frameCount, _ in
        let capture = Unmanaged<VoxaMicHALCapture>.fromOpaque(refCon).takeUnretainedValue()
        return capture.handleInput(
            ioActionFlags: ioActionFlags,
            timeStamp: timeStamp,
            frameCount: frameCount
        )
    }

    private func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard isCapturing, let unit = audioUnit, let ring, let format = captureFormat else {
            return noErr
        }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.channelCount,
                mDataByteSize: 0,
                mData: nil
            )
        )

        let status = AudioUnitRender(
            unit,
            ioActionFlags,
            timeStamp,
            inputBus,
            frameCount,
            &bufferList
        )
        guard status == noErr else { return status }

        guard let pcm = Self.makePCMBuffer(from: &bufferList, format: format, frameCount: frameCount) else {
            return noErr
        }
        writeToRing(pcm: pcm)
        return noErr
    }

    private func writeToRing(pcm: AVAudioPCMBuffer) {
        writeLock.lock()
        let shouldWrite = writesToRing
        writeLock.unlock()
        guard shouldWrite, let ring else { return }
        VoxaMicRingWriter.write(pcm: pcm, to: ring)
    }

    private static func makePCMBuffer(
        from bufferList: inout AudioBufferList,
        format: AVAudioFormat,
        frameCount: UInt32
    ) -> AVAudioPCMBuffer? {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let src = UnsafeMutableAudioBufferListPointer(&bufferList)
        let dst = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for index in 0..<min(src.count, dst.count) {
            guard let srcData = src[index].mData, let dstData = dst[index].mData else { continue }
            memcpy(dstData, srcData, Int(src[index].mDataByteSize))
        }
        return pcmBuffer
    }

    private static func deviceStreamDescription(deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return asbd
    }

    enum CaptureError: Error {
        case noStreamFormat
        case componentNotFound
        case instanceFailed
        case enableInputFailed
        case disableOutputFailed
        case setDeviceFailed
        case setFormatFailed
        case setCallbackFailed
        case initializeFailed
        case startFailed
    }
}
