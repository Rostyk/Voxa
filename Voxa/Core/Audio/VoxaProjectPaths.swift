import Foundation

/// Paths relative to the Voxa git repo (not the inner `Voxa/Voxa` source folder).
enum VoxaProjectPaths {
    /// `/Users/…/Work/mac/Voxa` — parent of the inner `Voxa` app sources.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func fileInRepoRoot(_ name: String) -> URL {
        repoRoot.appendingPathComponent(name)
    }
}
