import Foundation

/// Builds the OpenAI chat request. Kept out of Networking so `OpenAIRestClient` stays transport-only.
enum CaptionTranslationPrompt {

    static func chatRequest(
        model: String,
        rawTranscript: String,
        callContext: String,
        targetLanguageLabel: String
    ) -> OpenAIChatCompletionsRequest {
        let contextLine = callContext.isEmpty ? "(none provided)" : callContext

        let system = """
        You help during a live call. The input is noisy speech-to-text.

        MAIN TASK — **Translate** the line into **\(targetLanguageLabel)**. Use the CALL CONTEXT below for names, jargon, topic, and tone. Be natural and concise.

        SPEED — Prefer a **fast, short** answer: output **only** one JSON object (no markdown, no commentary, no keys other than these two strings):
        `corrected` — same language as the transcript; **only** fix obvious ASR/word errors; if the line is already clear, stay very close to the original words.
        `translation` — the translation into **\(targetLanguageLabel)**.

        CALL CONTEXT (from the app’s context / notes input field — use it for terminology and topic):
        \(contextLine)
        """

        let user = """
        Transcript line to translate:
        \(rawTranscript)
        """

        return OpenAIChatCompletionsRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            responseFormat: .init(type: "json_object"),
            maxCompletionTokens: OpenAIConfiguration.chatCaptionMaxCompletionTokens,
            reasoningEffort: OpenAIConfiguration.chatCaptionReasoningEffort()
        )
    }
}
