import Foundation

/// Live correction + translation via OpenAI Chat Completions (JSON `corrected` / `translation`).
final class GPTCaptionTranslationService: LiveCaptionTranslationServicing, @unchecked Sendable {

    private let client: OpenAIRestClienting

    init(client: OpenAIRestClienting) {
        self.client = client
    }

    func translateLine(
        transcript: String,
        targetLocaleIdentifier: String,
        callContextNotes: String
    ) async throws -> CorrectionTranslationPayload {
        let targetLabel =
            Locale.current.localizedString(forIdentifier: targetLocaleIdentifier)
            ?? targetLocaleIdentifier

        let chatRequest = CaptionTranslationPrompt.chatRequest(
            model: OpenAIConfiguration.chatCaptionModel(),
            rawTranscript: transcript,
            callGoal: callContextNotes,
            targetLanguageLabel: targetLabel
        )

        print(
            "[GPT] live_call_transcription request model=\(chatRequest.model) target=\"\(targetLabel)\" goalChars=\(callContextNotes.count) transcriptChars=\(transcript.count)"
        )
        print("[GPT] GPTCaptionTranslationService messages=\(chatRequest.messages.count)")
        for (index, message) in chatRequest.messages.enumerated() {
            print(
                "[GPT] prompt message[\(index)] role=\(message.role) (\(message.content.count) chars)\n---BEGIN \(message.role.uppercased())---\n\(message.content)\n---END \(message.role.uppercased())---"
            )
        }

        let envelope = try await client.sendChatCompletion(request: chatRequest)
        return try OpenAIRestClient.parseCorrectionTranslation(from: envelope)
    }
}
