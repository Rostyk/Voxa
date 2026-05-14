import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

public struct AUAudioProcess: Identifiable, Hashable, Sendable {

    public enum Kind: String, Sendable {
        case process
        case app
    }

    public var id: pid_t
    public var kind: Kind
    public var name: String
    public var audioActive: Bool
    public var bundleID: String?
    public var bundleURL: URL?
    public var objectID: AudioObjectID

    public init(id: pid_t, kind: Kind, name: String, audioActive: Bool, bundleID: String?, bundleURL: URL?, objectID: AudioObjectID) {
        self.id = id
        self.kind = kind
        self.name = name
        self.audioActive = audioActive
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.objectID = objectID
    }
}

extension AUAudioProcess.Kind {
    public var defaultIcon: NSImage {
        switch self {
        case .process: NSWorkspace.shared.icon(for: .unixExecutable)
        case .app: NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    public var groupTitle: String {
        switch self {
        case .process: "Processes"
        case .app: "Apps"
        }
    }
}

extension AUAudioProcess {
    public var icon: NSImage {
        guard let bundleURL else { return kind.defaultIcon }
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}

extension AUAudioProcess {

    init(app: NSRunningApplication, objectID: AudioObjectID) {
        let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier?.components(separatedBy: ".").last ?? "Unknown \(app.processIdentifier)"

        self.init(
            id: app.processIdentifier,
            kind: .app,
            name: name,
            audioActive: AUAudioUtils.readProcessIsRunning(objectID: objectID),
            bundleID: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            objectID: objectID
        )
    }

    init(objectID: AudioObjectID, runningApplications apps: [NSRunningApplication]) throws {
        let pid: pid_t = try AUAudioUtils.readPID(objectID: objectID)

        if let app = apps.first(where: { $0.processIdentifier == pid }) {
            self.init(app: app, objectID: objectID)
        } else {
            try self.init(objectID: objectID, pid: pid)
        }
    }

    init(objectID: AudioObjectID, pid: pid_t) throws {
        let bundleID = AUAudioUtils.readProcessBundleID(objectID: objectID)
        let bundleURL: URL?
        let name: String

        if let info = AUAudioUtils.processInfo(for: pid) {
            name = info.name
            bundleURL = URL(fileURLWithPath: info.path).parentBundleURL()
        } else if let id = bundleID?.lastReverseDNSComponent {
            name = id
            bundleURL = nil
        } else {
            name = "Unknown (\(pid))"
            bundleURL = nil
        }

        self.init(
            id: pid,
            kind: bundleURL?.isApp == true ? .app : .process,
            name: name,
            audioActive: AUAudioUtils.readProcessIsRunning(objectID: objectID),
            bundleID: bundleID.flatMap { $0.isEmpty ? nil : $0 },
            bundleURL: bundleURL,
            objectID: objectID
        )
    }
}

private extension URL {
    func parentBundleURL(maxDepth: Int = 8) -> URL? {
        var depth = 0
        var url = deletingLastPathComponent()
        while depth < maxDepth, !url.isBundle {
            url = url.deletingLastPathComponent()
            depth += 1
        }
        return url.isBundle ? url : nil
    }

    var isBundle: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .bundle) == true
    }

    var isApp: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }
}

private extension String {
    var lastReverseDNSComponent: String? {
        components(separatedBy: ".").last.flatMap { $0.isEmpty ? nil : $0 }
    }
}
