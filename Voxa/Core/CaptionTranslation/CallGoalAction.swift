import Foundation

/// Suggested step toward the user-defined call goal (from ChatGPT JSON).
struct CallGoalAction: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum ActionType: String, Codable, Sendable {
        case dtmf
        case text
        case voice
    }

    let type: ActionType
    let content: String

    var id: String { "\(type.rawValue):\(content)" }

    private static let dtmfCharacterSet = CharacterSet(charactersIn: "0123456789*#")

    init(type: ActionType, content: String) {
        self.type = type
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type).lowercased()
        var resolvedType = Self.resolveType(rawType)
        var resolvedContent = try container.decodeIfPresent(String.self, forKey: .content) ?? ""

        if resolvedContent.isEmpty,
           rawType.count == 1,
           let digit = rawType.first,
           Self.dtmfCharacterSet.contains(UnicodeScalar(String(digit))!)
        {
            resolvedContent = rawType
            resolvedType = .dtmf
            print("[CallGoal] decode: digit in type field → dtmf content=\"\(resolvedContent)\"")
        }

        let normalized = Self.normalizedForExecution(type: resolvedType, content: resolvedContent)
        type = normalized.type
        content = normalized.content

        if rawType != type.rawValue && !(rawType == "play" || rawType == "say" || rawType == "speak") {
            print("[CallGoal] decode: rawType=\"\(rawType)\" → \(type.rawValue) contentChars=\(content.count)")
        }
    }

    static func normalizedDTMFDigits(from string: String) -> String {
        FaceTimeDTMFAccessibility.normalizedDigits(from: string)
    }

    /// Coerces mislabeled GPT actions (e.g. `text` with content `"1"`) before execution.
    static func normalizedForExecution(type: ActionType, content: String) -> (type: ActionType, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = normalizedDTMFDigits(from: trimmed)

        switch type {
        case .voice:
            return (type, trimmed)
        case .dtmf:
            let sequence = digitsOnly.isEmpty ? trimmed : digitsOnly
            return (.dtmf, sequence)
        case .text:
            if !digitsOnly.isEmpty, digitsOnly.count == trimmed.filter({ !$0.isWhitespace }).count, trimmed.count <= 24 {
                print("[CallGoal] normalize: text → dtmf content=\"\(digitsOnly)\"")
                return (.dtmf, digitsOnly)
            }
            return (.text, trimmed)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case content
    }

    private static func resolveType(_ raw: String) -> ActionType {
        switch raw {
        case "dtmf", "press", "key", "keypad", "digit", "button", "tone": return .dtmf
        case "text", "play", "say", "speak": return .text
        case "voice", "write", "mic", "listen": return .voice
        default:
            print("[CallGoal] decode: unknown type \"\(raw)\" → mapped to text")
            return .text
        }
    }
}

enum CallGoalActionLog {
    static func logList(_ actions: [CallGoalAction], context: String) {
        if actions.isEmpty {
            print("[CallGoal] \(context): (no actions)")
            return
        }
        print("[CallGoal] \(context): \(actions.count) action(s)")
        for (index, action) in actions.enumerated() {
            let contentDisplay = action.content.isEmpty ? "(empty)" : "\"\(action.content)\""
            print("[CallGoal]   [\(index)] type=\(action.type.rawValue) content=\(contentDisplay)")
        }
    }

    static func logOne(_ action: CallGoalAction, context: String) {
        let contentDisplay = action.content.isEmpty ? "(empty)" : "\"\(action.content)\""
        print("[CallGoal] \(context): type=\(action.type.rawValue) content=\(contentDisplay)")
    }
}
