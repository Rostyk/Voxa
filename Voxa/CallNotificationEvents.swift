import Combine
import Foundation

@MainActor
final class CallNotificationEvents {
    static let shared = CallNotificationEvents()

    var onMicrophoneProcessesChanged: (([AudioProcess]) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default
            .publisher(for: .microphoneProcessesChanged)
            .sink { [weak self] notification in
                if let processes = notification.userInfo?["processes"] as? [AudioProcess] {
                    self?.onMicrophoneProcessesChanged?(processes)
                }
            }
            .store(in: &cancellables)
    }
}
