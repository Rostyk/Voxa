import Foundation
import Observation

@MainActor
@Observable
final class VoxaVirtualMicFeederStatus {
    static let shared = VoxaVirtualMicFeederStatus()

    private(set) var isRunning = false
    private(set) var captureDeviceName: String?
    private(set) var detailMessage: String?

    var isHealthy: Bool { isRunning && detailMessage == nil }

    private init() {}

    func apply(running: Bool, captureDeviceName: String?, detailMessage: String?) {
        isRunning = running
        self.captureDeviceName = captureDeviceName
        self.detailMessage = detailMessage
    }
}
