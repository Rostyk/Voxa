import Foundation

// MARK: - TEMPORARY Zoom exclusion
// Remove this file and all `ZoomCallDetectionExclusion` / `excludeZoomFromCallDetection` wiring
// when Zoom should trigger call detection and be included in the system audio tap again.
// App setting: CallViewModel.excludeZoomFromCallDetection (Settings checkbox, default ON).

/// Identifies Zoom so Voxa can ignore it as a “call app” and omit its audio from the aggregate tap.
public enum ZoomCallDetectionExclusion {

    public static let bundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.zoom.client.mac",
    ]

    public static func matches(bundleID: String?, processName: String) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID) {
            return true
        }
        let normalized = processName.lowercased()
        if normalized.contains("zoom") {
            return true
        }
        return false
    }

    public static func matches(_ process: VOAudioProcess) -> Bool {
        matches(bundleID: process.bundleID, processName: process.name)
    }
}
