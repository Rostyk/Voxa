import AppKit
import Foundation

/// Display names and icons for mic-active processes in the listener card.
enum CallProcessDisplay {

    static func displayName(for process: AudioProcess) -> String {
        if isFaceTimeFamily(process) {
            return "FaceTime"
        }
        return process.name
    }

    static func icon(for process: AudioProcess) -> NSImage {
        if isFaceTimeFamily(process), let faceTimeIcon = faceTimeApplicationIcon() {
            return faceTimeIcon
        }
        return process.icon
    }

    static func isFaceTimeFamily(_ process: AudioProcess) -> Bool {
        let bundle = process.bundleID?.lowercased() ?? ""
        let name = process.name.lowercased()
        if bundle == "com.apple.facetime" || bundle.contains("facetime") { return true }
        if bundle.contains("avconferenced") || name.contains("avconference") { return true }
        if name.contains("facetime") { return true }
        return false
    }

    private static func faceTimeApplicationIcon() -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 32, height: 32)
            return image
        }
        return nil
    }
}
