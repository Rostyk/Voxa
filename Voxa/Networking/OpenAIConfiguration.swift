import Foundation

enum OpenAIConfiguration: Sendable {
    static let chatCompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Model for live caption correction + translation.
    /// - Default: `gpt-5-nano` (OpenAI: fastest / most cost-efficient GPT‑5; Chat Completions supported).
    /// - OYD (`RemoteAIService`) uses `gpt-4o-mini` on the **Responses** API as a fast non‑reasoning choice.
    /// - Override: set env `GPT_MODEL` (e.g. `gpt-4o-mini`) if your key/org does not expose nano yet.
    static func chatCaptionModel() -> String {
        let raw = ProcessInfo.processInfo.environment["GPT_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "gpt-5-nano" : raw
    }

    /// GPT‑5 counts **reasoning** + visible text inside `max_completion_tokens`. Too low (e.g. 512) can spend the entire budget on reasoning, leaving `content` empty and `finish_reason: "length"`.
    static let chatCaptionMaxCompletionTokens = 4096

    /// For reasoning chat models (`gpt-5-*`, etc.). Lower effort leaves more budget for the JSON reply. Override: env `GPT_REASONING_EFFORT` (`minimal`, `low`, `medium`, `high`).
    static func chatCaptionReasoningEffort() -> String? {
        let m = chatCaptionModel().lowercased()
        guard m.contains("gpt-5") || m.contains("o3") || m.contains("o4-mini") else { return nil }
        let raw = ProcessInfo.processInfo.environment["GPT_REASONING_EFFORT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "minimal" : raw
    }

    /// OpenAI key from the process environment (e.g. Xcode Scheme → `OPEN_AI_KEY`).
    static func apiKey() -> String? {
        guard let raw = ProcessInfo.processInfo.environment["OPEN_AI_KEY"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
