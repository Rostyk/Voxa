import Foundation

/// Builds the OpenAI chat request. Kept out of Networking so `OpenAIRestClient` stays transport-only.
enum CaptionTranslationPrompt {

    static func chatRequest(
        model: String,
        rawTranscript: String,
        callGoal: String,
        targetLanguageLabel: String
    ) -> OpenAIChatCompletionsRequest {
        let goalLine = callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(none — infer reasonable actions from the line only)"
            : callGoal.trimmingCharacters(in: .whitespacesAndNewlines)

        let system = """
        You assist on a **live phone/video call** (real-time ASR). The user reads your JSON while the call continues.

        **CALL GOAL** — what the user wants to achieve on this call:
        \(goalLine)

        **INPUT** — `rawTranscript` is noisy live ASR. In `corrected`, fix obvious errors only; do not invent facts.

        **TASKS**
        1. `translation` — natural **\(targetLanguageLabel)** for the callee’s latest line (`corrected`).
        2. `actions` — 1–6 concrete steps the **caller** can take next toward the CALL GOAL, based on that line + goal. Use callee language for `text` phrases.

        **ACTION TYPES** (field `type`, string `content`):
        - `dtmf` — touch-tone digits only (e.g. `"1"`, `"*2"`).
        - `text` — short phrase for the caller to **say** to the callee (already in callee/source language, not \(targetLanguageLabel)).
        - `voice` — caller must **speak live**; `content` must be `""`. Include **at most one** `voice` when the caller must answer freely.

        Prefer specific `dtmf`/`text` when the line offers menu options or clear replies. Multiple `dtmf`/`text` allowed if several apply.

        **OUTPUT** — single JSON only (no markdown):
        `{"corrected":"…","translation":"…","actions":[{"type":"dtmf|text|voice","content":"…"}]}`
        """

        let user = """
        Latest callee line (live ASR):
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
