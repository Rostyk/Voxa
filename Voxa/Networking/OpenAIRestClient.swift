import Foundation

protocol OpenAIRestClienting: Sendable {
    func sendChatCompletion(request: OpenAIChatCompletionsRequest) async throws -> OpenAIChatCompletionsResponse
}

/// HTTP + decode only. No prompt logic.
final class OpenAIRestClient: OpenAIRestClienting, @unchecked Sendable {

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
        print("[GPT] OpenAIRestClient init (API key length=\(apiKey.count))")
    }

    func sendChatCompletion(request: OpenAIChatCompletionsRequest) async throws -> OpenAIChatCompletionsResponse {
        let wallStart = CFAbsoluteTimeGetCurrent()
        print(
            "[GPT] chat/completions HTTP layer: model=\(request.model) max_completion_tokens=\(request.maxCompletionTokens) reasoning_effort=\(request.reasoningEffort ?? "(omitted)") messages=\(request.messages.count) (correction + translation)"
        )
        var urlRequest = URLRequest(url: OpenAIConfiguration.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(request)
        } catch {
            print("[GPT] encode request failed error=\(error.localizedDescription)")
            throw error
        }
        urlRequest.httpBody = bodyData
        print("[GPT] chat/completions POST bodyBytes=\(bodyData.count)")

        let data: Data
        let response: URLResponse
        let networkStart = CFAbsoluteTimeGetCurrent()
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            print("[GPT] chat/completions transport error=\(error.localizedDescription)")
            throw error
        }
        let networkSeconds = CFAbsoluteTimeGetCurrent() - networkStart
        print(
            "[GPT] chat/completions timing network=\(String(format: "%.3f", networkSeconds))s (URLSession.data until full response body)"
        )
        guard let http = response as? HTTPURLResponse else {
            print("[GPT] chat/completions non-HTTP response")
            throw OpenAIRestError.nonHTTPResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[GPT] chat/completions HTTP error status=\(http.statusCode) bodyPrefix=\(body.prefix(400))")
            print("[GPT] chat/completions RAW ERROR RESPONSE BODY:\n\(body)")
            throw OpenAIRestError.httpStatus(code: http.statusCode, body: body)
        }

        print("[GPT] chat/completions HTTP \(http.statusCode) responseBytes=\(data.count)")

        if let rawBody = String(data: data, encoding: .utf8) {
            print("[GPT] chat/completions RAW RESPONSE BODY:\n\(rawBody)")
        } else {
            print("[GPT] chat/completions RAW RESPONSE: (not valid UTF-8, \(data.count) bytes)")
        }

        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode(OpenAIChatCompletionsResponse.self, from: data)
            let choiceCount = decoded.choices?.count ?? 0
            print("[GPT] chat/completions decoded choices=\(choiceCount)")
            let totalSeconds = CFAbsoluteTimeGetCurrent() - wallStart
            print(
                "[GPT] chat/completions timing total sendChatCompletion=\(String(format: "%.3f", totalSeconds))s (encode+network+HTTP decode envelope)"
            )
            return decoded
        } catch {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? "(binary)"
            print("[GPT] chat/completions decode envelope failed error=\(error.localizedDescription) snippet=\(snippet)")
            throw error
        }
    }
}

enum OpenAIRestError: Error, LocalizedError {
    case nonHTTPResponse
    case httpStatus(code: Int, body: String)
    case missingAssistantContent
    case innerJSONParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Non-HTTP response from OpenAI."
        case let .httpStatus(code, body):
            return "OpenAI HTTP \(code): \(body.prefix(500))"
        case .missingAssistantContent:
            return "OpenAI response had no assistant message content."
        case let .innerJSONParseFailed(s):
            return "Could not parse model JSON: \(s.prefix(300))"
        }
    }
}

extension OpenAIRestClient {
    /// Extracts and decodes the inner `CorrectionTranslationPayload` from a chat completion envelope.
    nonisolated static func parseCorrectionTranslation(from response: OpenAIChatCompletionsResponse) throws
        -> CorrectionTranslationPayload
    {
        guard let raw = response.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            let finish = response.choices?.first?.finishReason ?? "nil"
            print(
                "[GPT] parse inner JSON missing assistant content choices=\(response.choices?.count ?? 0) finish_reason=\(finish) — if finish_reason=length with empty content, reasoning likely used the whole max_completion_tokens budget; we now use a higher budget + reasoning_effort minimal for gpt-5"
            )
            throw OpenAIRestError.missingAssistantContent
        }

        print("[GPT] parse inner JSON assistant rawChars=\(raw.count)")

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            print("[GPT] parse inner JSON utf8 data failed rawPrefix=\(raw.prefix(200))")
            throw OpenAIRestError.innerJSONParseFailed(raw)
        }

        do {
            let payload = try JSONDecoder().decode(CorrectionTranslationPayload.self, from: data)
            print(
                "[GPT] parse inner JSON OK correctedChars=\(payload.corrected.count) translationChars=\(payload.translation.count) actions=\(payload.actions.count)"
            )
            CallGoalActionLog.logList(payload.actions, context: "parsed from GPT JSON")
            return payload
        } catch {
            print("[GPT] parse inner JSON decode failed error=\(error.localizedDescription) rawPrefix=\(raw.prefix(300))")
            throw OpenAIRestError.innerJSONParseFailed(raw)
        }
    }
}
