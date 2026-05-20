import Foundation
import NaturalLanguage

enum CallTitleGenerator {
    private struct TitlePayload: Decodable {
        let title: String
    }

    private struct TranscriptSelection {
        let excerpt: String
        let selectedCount: Int
        let namedEntityCount: Int
        let totalTurnCount: Int
    }

    static func generateTitle(for record: CallHistoryRecord) async -> String? {
        print(
            "[HistoryTitle] start id=\(record.id) turns=\(record.turns.count) timeframe=\"\(record.timeframeText)\" existingGenerated=\"\(record.generatedTitle ?? "")\""
        )
        guard let apiKey = OpenAIConfiguration.apiKey() else {
            print("[HistoryTitle] OpenAI key missing; skip generated call title")
            return nil
        }

        let selection = selectedTranscriptExcerpt(from: record)
        let transcript = selection.excerpt
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[HistoryTitle] empty transcript; skip generated call title")
            return nil
        }
        print(
            "[HistoryTitle] selected transcript id=\(record.id) totalTurns=\(selection.totalTurnCount) selected=\(selection.selectedCount) namedEntitySelected=\(selection.namedEntityCount) chars=\(transcript.count) preview=\"\(logPreview(transcript, maxLen: 260))\""
        )

        let request = OpenAIChatCompletionsRequest(
            model: OpenAIConfiguration.chatCaptionModel(),
            messages: [
                .init(
                    role: "system",
                    content: "You name phone calls from partial transcripts. Return only a JSON object."
                ),
                .init(
                    role: "user",
                    content: """
                    That's a transcript of call. Figure out the name/purpose of the call so I have a title. Check for organization name, company name, person name, or purpose of the call. Give me a few words, max 80 symbols.

                    Return JSON exactly like:
                    {"title":"short call name"}

                    Transcript bubbles:
                    \(transcript)
                    """
                )
            ],
            responseFormat: .init(type: "json_object"),
            maxCompletionTokens: 256,
            reasoningEffort: OpenAIConfiguration.chatCaptionReasoningEffort()
        )

        do {
            let start = CFAbsoluteTimeGetCurrent()
            print(
                "[HistoryTitle] GPT request id=\(record.id) model=\(request.model) maxCompletionTokens=\(request.maxCompletionTokens) reasoning=\(request.reasoningEffort ?? "(none)")"
            )
            let response = try await OpenAIRestClient(apiKey: apiKey).sendChatCompletion(request: request)
            guard let raw = response.choices?.first?.message?.content,
                  let data = raw.data(using: .utf8) else {
                print("[HistoryTitle] missing assistant content")
                return nil
            }
            print(
                "[HistoryTitle] GPT raw response id=\(record.id) chars=\(raw.count) elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - start))s raw=\"\(logPreview(raw, maxLen: 300))\""
            )
            let payload = try JSONDecoder().decode(TitlePayload.self, from: data)
            let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                print("[HistoryTitle] decoded empty title id=\(record.id)")
                return nil
            }
            let clipped = String(title.prefix(80))
            print("[HistoryTitle] title generated id=\(record.id) title=\"\(clipped)\"")
            return clipped
        } catch {
            print("[HistoryTitle] generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func selectedTranscriptExcerpt(from record: CallHistoryRecord) -> TranscriptSelection {
        var selectedIDs = Set<UUID>()
        var selected: [ConversationTurn] = []
        var namedEntitySelected = 0

        for turn in record.turns.prefix(2) {
            selectedIDs.insert(turn.id)
            selected.append(turn)
            print("[HistoryTitle] candidate first turn=\(turn.id) chars=\(turn.bestTranscriptForTitle.count)")
        }

        for turn in record.turns where !selectedIDs.contains(turn.id) {
            let text = turn.bestTranscriptForTitle
            guard containsNamedEntity(text) else { continue }
            selectedIDs.insert(turn.id)
            selected.append(turn)
            namedEntitySelected += 1
            print(
                "[HistoryTitle] candidate namedEntity turn=\(turn.id) chars=\(text.count) preview=\"\(logPreview(text, maxLen: 160))\""
            )
            if selected.count >= 8 { break }
        }

        if selected.isEmpty {
            selected = Array(record.turns.prefix(4))
            print("[HistoryTitle] fallback selected first \(selected.count) turns")
        }

        let excerpt = selected
            .enumerated()
            .map { index, turn in
                let text = turn.bestTranscriptForTitle
                let translation = turn.gptTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if translation.isEmpty {
                    return "[\(index + 1)] \(text)"
                }
                return "[\(index + 1)] \(text)\nTranslation: \(translation)"
            }
            .joined(separator: "\n\n")
            .prefixString(4_000)
        return TranscriptSelection(
            excerpt: excerpt,
            selectedCount: selected.count,
            namedEntityCount: namedEntitySelected,
            totalTurnCount: record.turns.count
        )
    }

    private static func containsNamedEntity(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = trimmed

        var found = false
        let range = trimmed.startIndex..<trimmed.endIndex
        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, _ in
            if tag == .organizationName || tag == .personalName || tag == .placeName {
                found = true
                return false
            }
            return true
        }
        return found
    }

    private static func logPreview(_ text: String, maxLen: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        guard oneLine.count > maxLen else { return oneLine }
        return String(oneLine.prefix(maxLen))
    }
}

private extension ConversationTurn {
    var bestTranscriptForTitle: String {
        let fluid = fluidAudioText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fluid.isEmpty { return fluid }

        let corrected = gptCorrected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !corrected.isEmpty { return corrected }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension StringProtocol {
    func prefixString(_ maxLength: Int) -> String {
        if count <= maxLength { return String(self) }
        return String(prefix(maxLength))
    }
}
