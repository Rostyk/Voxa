import Darwin
import Foundation

#if canImport(AppKit)
import AppKit
#endif

public final class AudioRecordingPermission {

    public enum Status: String {
        case unknown
        case denied
        case authorized
    }

    public private(set) var status: Status = .unknown

    public typealias StatusChangeCallback = (Status) -> Void
    private var statusChangeCallback: StatusChangeCallback?

    public init() {
        print("[AudioRecordingPermission] init bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        updateStatus()

        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateStatus()
        }
        #endif
    }

    public func onStatusChange(_ callback: @escaping StatusChangeCallback) {
        statusChangeCallback = callback
    }

    public func forceRefresh() {
        updateStatus()
    }

    public func request() {
        print("[AudioRecordingPermission] request() enter status=\(status.rawValue)")
        updateStatus()
        print("[AudioRecordingPermission] request() after preflight status=\(status.rawValue)")

        if status == .authorized {
            print("[AudioRecordingPermission] request() short-circuit: already authorized")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("SystemAudioPermissionGranted"),
                    object: nil
                )
            }
            return
        }

        guard let request = Self.requestSPI else {
            print("[AudioRecordingPermission] Request SPI missing (dlopen/dlsym)")
            return
        }

        if Self.apiHandle == nil {
            print("[AudioRecordingPermission] TCC apiHandle nil")
        } else {
            print("[AudioRecordingPermission] calling TCCAccessRequest(kTCCServiceAudioCapture)")
        }

        request("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
            guard let self else { return }

            print("[AudioRecordingPermission] TCCAccessRequest callback granted=\(granted)")

            DispatchQueue.main.async {
                if granted {
                    self.status = .authorized
                    print("[AudioRecordingPermission] status -> authorized")
                    NotificationCenter.default.post(
                        name: Notification.Name("SystemAudioPermissionGranted"),
                        object: nil
                    )
                } else {
                    self.status = .denied
                    print("[AudioRecordingPermission] status -> denied")
                }

                self.statusChangeCallback?(self.status)
            }
        }
    }

    private func updateStatus() {
        guard let preflight = Self.preflightSPI else {
            print("[AudioRecordingPermission] Preflight SPI missing")
            return
        }

        let result = preflight("kTCCServiceAudioCapture" as CFString, nil)

        let oldStatus = status

        if result == 1 {
            status = .denied
        } else if result == 0 {
            status = .authorized
        } else {
            status = .unknown
        }

        if oldStatus != status {
            print("[AudioRecordingPermission] preflight raw=\(result) status \(oldStatus.rawValue) -> \(status.rawValue) (map: 0=auth 1=deny other=unknown)")
        }

        if oldStatus != status {
            if status == .authorized && oldStatus != .authorized {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("SystemAudioPermissionGranted"),
                        object: nil
                    )
                }
            }
            statusChangeCallback?(status)
        }
    }

    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        guard let handle = dlopen(tccPath, RTLD_NOW) else {
            print("[AudioRecordingPermission] dlopen TCC failed")
            return nil
        }
        return handle
    }()

    private static let preflightSPI: PreflightFuncType? = {
        guard let apiHandle else { return nil }
        guard let funcSym = dlsym(apiHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(funcSym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
        guard let apiHandle else { return nil }
        guard let funcSym = dlsym(apiHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(funcSym, to: RequestFuncType.self)
    }()
}
