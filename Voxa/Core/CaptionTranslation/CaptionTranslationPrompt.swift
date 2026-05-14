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
        You are assisting with a **live phone or video call** that is being **transcribed in real time** on the user’s Mac (Apple / system speech-to-text). The user reads your output while the call is still happening.

        INPUT NATURE — The `rawTranscript` line is **live call audio → ASR**: it may include wrong words, dropped words, homophones, mid-sentence cuts, filler, or short spans that are **clearly not what a human on the call would have said** in context (random tokens, UI noise, hallucinated fragments). Use CALL CONTEXT + common sense; when something is **obviously** bad ASR or out-of-place with no plausible meaning for this call, **omit or replace** those fragments in `corrected` so the line reads like coherent speech. Do **not** invent facts or names that are not supported by the transcript or call context.

        MAIN TASK — **Translate** the intended meaning into **\(targetLanguageLabel)**. Prefer natural, concise spoken-register phrasing suitable for reading during a call.

        OUTPUT — Reply with **only** one JSON object (no markdown, no prose outside JSON, no extra keys). Exactly these two string fields:
        `corrected` — same source language as the transcript; a **readable** version of what was likely said (fix obvious ASR errors; remove obvious nonsense when confident).
        `translation` — the translation into **\(targetLanguageLabel)** aligned with `corrected`.

        CALL CONTEXT (optional notes from the user — participants, product names, jargon, topic):
        \(contextLine)
        """

        let user = """
        Live call transcript line (real-time ASR — may be partial or noisy):
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
