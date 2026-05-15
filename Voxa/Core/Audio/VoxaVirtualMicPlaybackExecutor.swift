import Foundation

/// Dedicated serial queue for TTS / WAV — **no Swift `Task` / `await`** on this path (avoids MainActor hops).
enum VoxaVirtualMicPlaybackExecutor {
    static let queue = DispatchQueue(
        label: "com.aurigin.test.Voxa.virtualMicPlayback",
        qos: .userInitiated
    )

    /// Enqueue work; returns immediately (safe to call from the main thread).
    static func dispatch(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    static func assertNotOnMainThread(_ context: String) {
        if Thread.isMainThread {
            print("[VoxaMic] WARNING: \(context) running on main thread — UI may freeze")
        }
    }
}
