import Foundation

/// Serial queue for TTS / WAV ring injection — keeps UI responsive and pacing stable.
enum VoxaVirtualMicPlaybackExecutor {
    private static let queue = DispatchQueue(label: "com.aurigin.test.Voxa.virtualMicPlayback", qos: .userInitiated)

    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do {
                        let value = try await operation()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
