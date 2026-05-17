import AppKit
import ApplicationServices
import Foundation

/// macOS Accessibility trust (System Settings → Privacy & Security → Accessibility).
@MainActor
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isGranted = false

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let granted = AXIsProcessTrusted()
        if granted != isGranted {
            print("[AccessibilityPermission] isGranted \(isGranted) → \(granted)")
        }
        isGranted = granted
    }

    /// Opens the system prompt to add Voxa to Accessibility.
    func requestGrant() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
        if !isGranted {
            refresh()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
