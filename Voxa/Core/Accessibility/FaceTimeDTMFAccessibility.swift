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
    private static let digitTapDelay: Duration = .milliseconds(120)

    static func normalizedDigits(from string: String) -> String {
        String(string.unicodeScalars.filter { allowedDigits.contains($0) }.map(Character.init))
    }

    static func sendDigits(_ raw: String) async throws {
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

        var roots = try FaceTimeAccessibilityAX.buildCallUISearchRoots()
        let keypadAlreadyOpen = FaceTimeAccessibilityAX.isDigitKeypadVisible(roots: roots)

        if keypadAlreadyOpen {
            // FaceTime activation dismisses the Notification Center call overlay when digits are showing.
            FaceTimeAccessibilityAX.activateNotificationCenterForCallUI()
            roots = try FaceTimeAccessibilityAX.buildCallUISearchRoots()
            roots = FaceTimeAccessibilityAX.rootsForActiveKeypad(roots)
            print("[VoxaDTMF] digit pad already open — focus Notification Center, skip Keypad")
        } else {
            try FaceTimeAccessibilityAX.activateFaceTimeCallApp()
            roots = try FaceTimeAccessibilityAX.buildCallUISearchRoots()
            print(
                "[VoxaDTMF] sendDigits sequence=\"\(digits)\" — " +
                    "AX: NotificationCenter → Keypad → digits"
            )
            try await FaceTimeAccessibilityAX.ensureKeypadOpen(roots: roots)
            roots = try FaceTimeAccessibilityAX.buildCallUISearchRoots()
            roots = FaceTimeAccessibilityAX.rootsForActiveKeypad(roots)
        }

        for digit in digits {
            // Fresh tree + focus before each tone (AX elements go stale after the first press).
            FaceTimeAccessibilityAX.activateNotificationCenterForCallUI()
            let pressRoots = FaceTimeAccessibilityAX.rootsForActiveKeypad(
                try FaceTimeAccessibilityAX.buildCallUISearchRoots()
            )
            try FaceTimeAccessibilityAX.pressDigit(digit, roots: pressRoots)
            try await Task.sleep(for: digitTapDelay)
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
