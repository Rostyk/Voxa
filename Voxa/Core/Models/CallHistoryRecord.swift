import Foundation

struct CallHistoryRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var manualTitle: String?
    var generatedTitle: String?
    var speechLocaleIdentifier: String
    var translationLocaleIdentifier: String
    var translationEngine: LiveCaptionTranslationEngine
    var callGoal: String
    var turns: [ConversationTurn]

    var displayTitle: String {
        let manual = manualTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !manual.isEmpty { return manual }

        let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !generated.isEmpty { return generated }

        return fallbackTitle
    }

    var fallbackTitle: String {
        "\(Self.timeFormatter.string(from: startedAt))-\(Self.timeFormatter.string(from: endedAt))"
    }

    var durationText: String {
        let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remainder)s"
        }
        return "\(remainder)s"
    }

    var timeframeText: String {
        "\(Self.dateFormatter.string(from: startedAt)) • \(Self.timeFormatter.string(from: startedAt))-\(Self.timeFormatter.string(from: endedAt)) • \(durationText)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
