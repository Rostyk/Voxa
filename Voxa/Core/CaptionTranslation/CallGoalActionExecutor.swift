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

        let locale = speechLocaleIdentifier
        let actionType = normalized.type
        let actionContent = normalized.content

        switch actionType {
        case .text:
            print(
                "[CallGoal] perform text → playback queue locale=\(locale) chars=\(actionContent.count)"
            )
            VoxaVirtualMicSpeech.enqueueSpeak(text: actionContent, localeIdentifier: locale) { error in
                if let error {
                    let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    print("[CallGoal] perform text FAILED: \(detail)")
                    Task { @MainActor in
                        VoxaVirtualMicFeederStatus.shared.setLastActionError(detail)
                    }
                } else {
                    print("[CallGoal] perform text SUCCESS")
                }
            }
        case .dtmf, .voice:
            VoxaVirtualMicPlaybackExecutor.dispatch {
                performNonSpeechAction(type: actionType, content: actionContent)
            }
        }
    }

    private static func performNonSpeechAction(type: CallGoalAction.ActionType, content: String) {
        Task.detached(priority: .userInitiated) {
            print("[CallGoal] perform Task started type=\(type.rawValue) (background)")
            do {
                switch type {
                case .dtmf:
                    try await performDTMF(content)
                    print("[CallGoal] perform dtmf SUCCESS")
                case .voice:
                    print("[CallGoal] perform voice → unmute virtual mic (live HAL)")
                    await MainActor.run {
                        VoxaVirtualMicFeeder.shared.startIfNeeded()
                        VoxaVirtualMicFeeder.shared.setOutputMuted(false)
                    }
                    print("[CallGoal] perform voice SUCCESS isOutputMuted=false")
                case .text:
                    break
                }
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[CallGoal] perform FAILED type=\(type.rawValue) error=\(error)")
                await MainActor.run {
                    VoxaVirtualMicFeederStatus.shared.setLastActionError(detail)
                }
            }
            print("[CallGoal] perform Task finished type=\(type.rawValue)")
        }
    }

    private static func performDTMF(_ digits: String) async throws {
        try await FaceTimeDTMFAccessibility.sendDigits(digits)
        print("[CallGoal] perform dtmf path=FaceTime Accessibility")
    }
}
