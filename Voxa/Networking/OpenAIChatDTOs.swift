import Foundation

// MARK: - Chat Completions API (request / envelope)

struct OpenAIChatCompletionsRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable, Sendable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat
    /// Newer chat models reject `max_tokens`; API expects `max_completion_tokens`.
    let maxCompletionTokens: Int
    /// Reasoning models (`gpt-5-*`, …): lower effort reduces hidden reasoning tokens so JSON can appear in `content`. Omitted for non-reasoning models.
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

struct OpenAIChatCompletionsResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let role: String?
            let content: String?
        }

        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]?
}

// MARK: - Inner JSON from model (response_format json_object)

struct CorrectionTranslationPayload: Codable, Equatable, Sendable {
    let corrected: String
    let translation: String
    let actions: [CallGoalAction]

    init(corrected: String, translation: String, actions: [CallGoalAction] = []) {
        self.corrected = corrected
        self.translation = translation
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        corrected = try container.decode(String.self, forKey: .corrected)
        translation = try container.decode(String.self, forKey: .translation)
        actions = try container.decodeIfPresent([CallGoalAction].self, forKey: .actions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case corrected
        case translation
        case actions
    }
}
