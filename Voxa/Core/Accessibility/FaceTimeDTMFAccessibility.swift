import AppKit
import ApplicationServices
import Foundation

/// Sends DTMF by driving the in-call keypad via Accessibility (Notification Center overlay on macOS).
enum FaceTimeDTMFAccessibility {
    enum Error: LocalizedError {
        case accessibilityNotGranted
        case emptySequence
        case faceTimeNotRunning
        case keypadUnavailable
        case digitUnavailable(Character)

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Accessibility permission is required to control the FaceTime keypad."
            case .emptySequence:
                return "No DTMF digits to send (use 0–9, *, #)."
            case .faceTimeNotRunning:
                return "FaceTime is not running. Start a call in FaceTime first."
            case .keypadUnavailable:
                return "Could not find the in-call “Keypad” button (Notification Center overlay). Is a call active?"
            case .digitUnavailable(let digit):
                return "Could not find the keypad button for “\(digit)”."
            }
        }
    }

    private static let allowedDigits = CharacterSet(charactersIn: "0123456789*#")
    private static let digitTapDelaySeconds: TimeInterval = 0.04
    private static let accessibilityQueue = DispatchQueue(label: "com.aurigin.voxa.dtmf.accessibility", qos: .userInitiated)

    static func normalizedDigits(from string: String) -> String {
        String(string.unicodeScalars.filter { allowedDigits.contains($0) }.map(Character.init))
    }

    static func sendDigits(_ raw: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            accessibilityQueue.async {
                do {
                    try sendDigitsOnAccessibilityQueue(raw)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sendDigitsOnAccessibilityQueue(_ raw: String) throws {
        guard AXIsProcessTrusted() else {
            throw Error.accessibilityNotGranted
        }

        let digits = normalizedDigits(from: raw)
        guard !digits.isEmpty else {
            throw Error.emptySequence
        }

        guard callSessionAvailable() else {
            throw Error.faceTimeNotRunning
        }

        print(
            "[VoxaDTMF] sendDigits sequence=\"\(digits)\" — " +
                "AX narrow: NotificationCenter → FACETIME_NOTIFICATION → digit"
        )

        for (index, digit) in digits.enumerated() {
            var roots = try FaceTimeAccessibilityAX.buildNotificationCenterCallRoots()
            do {
                try FaceTimeAccessibilityAX.pressDigit(digit, roots: roots)
            } catch {
                guard index == 0 else { throw error }
                print("[VoxaDTMF] digit \(digit) not visible yet — opening Keypad via narrow roots")
                try FaceTimeAccessibilityAX.ensureKeypadOpen(roots: roots)
                roots = try FaceTimeAccessibilityAX.buildNotificationCenterCallRoots()
                try FaceTimeAccessibilityAX.pressDigit(digit, roots: roots)
            }
            Thread.sleep(forTimeInterval: digitTapDelaySeconds)
        }

        print("[VoxaDTMF] Accessibility sent digits=\"\(digits)\"")
    }

    private static func callSessionAvailable() -> Bool {
        let faceTimeRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: FaceTimeAccessibilityAX.faceTimeBundleID
        ).isEmpty
        let notificationCenterRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: FaceTimeAccessibilityAX.notificationCenterBundleID
        ).isEmpty
        return faceTimeRunning && notificationCenterRunning
    }
}
