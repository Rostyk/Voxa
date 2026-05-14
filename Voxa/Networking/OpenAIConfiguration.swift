import Foundation

enum OpenAIConfiguration: Sendable {
    static let chatCompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Model for live caption correction + translation.
    /// - Default: `gpt-4o` (stronger reasoning for noisy live-call ASR than mini).
    /// - Override: env `GPT_MODEL` (e.g. `gpt-4o-mini` for cost/latency, or org-specific GPT‑5 ids).
    static func chatCaptionModel() -> String {
        let raw = ProcessInfo.processInfo.environment["GPT_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "gpt-4o" : raw
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

    /// OpenAI key: `OPEN_AI_KEY` (Voxa convention) or `OPENAI_API_KEY` (common tooling default).
    /// Only the **runtime** process environment is read — xcconfig values are **not** visible here unless
    /// the scheme passes them (Edit Scheme → Run → Environment) or you launch from a shell with `export`.
    static func apiKey() -> String? {
        for name in ["OPEN_AI_KEY", "OPENAI_API_KEY"] {
            guard let raw = ProcessInfo.processInfo.environment[name] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
