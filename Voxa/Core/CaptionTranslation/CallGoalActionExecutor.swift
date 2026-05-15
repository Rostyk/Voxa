import Foundation

/// Runs a suggested call-goal action (DTMF via Accessibility, TTS, or live mic).
enum CallGoalActionExecutor {
    static func perform(_ action: CallGoalAction, speechLocaleIdentifier: String) {
        let normalized = CallGoalAction.normalizedForExecution(type: action.type, content: action.content)
        CallGoalActionLog.logOne(
            CallGoalAction(type: normalized.type, content: normalized.content),
            context: "CallGoalActionExecutor.perform — UI tap received"
        )
        print("[CallGoal] perform locale=\(speechLocaleIdentifier)")

        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                VoxaVirtualMicFeederStatus.shared.clearLastActionError()
            }
            print("[CallGoal] perform Task started type=\(normalized.type.rawValue)")
            do {
                switch normalized.type {
                case .dtmf:
                    try await performDTMF(normalized.content)
                    print("[CallGoal] perform dtmf SUCCESS")
                case .text:
                    print("[CallGoal] perform text → VoxaVirtualMicSpeech.speak chars=\(normalized.content.count)")
                    try await VoxaVirtualMicSpeech.shared.speak(
                        normalized.content,
                        localeIdentifier: speechLocaleIdentifier
                    )
                    print("[CallGoal] perform text SUCCESS")
                case .voice:
                    print("[CallGoal] perform voice → unmute virtual mic (live HAL)")
                    await MainActor.run {
                        VoxaVirtualMicFeeder.shared.startIfNeeded()
                        VoxaVirtualMicFeeder.shared.setOutputMuted(false)
                    }
                    print("[CallGoal] perform voice SUCCESS isOutputMuted=false")
                }
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[CallGoal] perform FAILED type=\(normalized.type.rawValue) error=\(error)")
                print("[CallGoal] perform FAILED detail: \(detail)")
                await MainActor.run {
                    VoxaVirtualMicFeederStatus.shared.setLastActionError(detail)
                }
            }
            print("[CallGoal] perform Task finished type=\(normalized.type.rawValue)")
        }
    }

    private static func performDTMF(_ digits: String) async throws {
        try await FaceTimeDTMFAccessibility.sendDigits(digits)
        print("[CallGoal] perform dtmf path=FaceTime Accessibility")
    }
}
