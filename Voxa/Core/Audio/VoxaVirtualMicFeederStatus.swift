import Foundation
import Observation

@MainActor
@Observable
final class VoxaVirtualMicFeederStatus {
    static let shared = VoxaVirtualMicFeederStatus()

    private(set) var isRunning = false
    private(set) var captureDeviceName: String?
    private(set) var detailMessage: String?
    /// `true` = live mic not sent to virtual mic (muted output).
    private(set) var isOutputMuted = false
    private(set) var muteToggleAvailable = false
    private(set) var lastActionError: String?

    var isHealthy: Bool { isRunning && detailMessage == nil && lastActionError == nil }

    private init() {}

    func apply(
        running: Bool,
        captureDeviceName: String?,
        detailMessage: String?,
        isOutputMuted: Bool,
        muteToggleAvailable: Bool
    ) {
        isRunning = running
        self.captureDeviceName = captureDeviceName
        self.detailMessage = detailMessage
        self.isOutputMuted = isOutputMuted
        self.muteToggleAvailable = muteToggleAvailable
    }

    func setOutputMuted(_ muted: Bool) {
        isOutputMuted = muted
    }

    func setLastActionError(_ message: String?) {
        lastActionError = message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : message
    }

    func clearLastActionError() {
        lastActionError = nil
    }
}
