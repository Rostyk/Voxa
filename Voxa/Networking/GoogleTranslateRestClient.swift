import Foundation

protocol GoogleTranslateRestClienting: Sendable {
    func translate(text: String, targetLanguageCode: String) async throws -> String
}

enum GoogleTranslateRestError: Error, LocalizedError {
    case nonHTTPResponse
    case httpStatus(code: Int, body: String)
    case emptyTranslations
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Non-HTTP response from Google Translate."
        case let .httpStatus(code, body):
            return "Google Translate HTTP \(code): \(body.prefix(500))"
        case .emptyTranslations:
            return "Google Translate returned no translations."
        case let .decodeFailed(s):
            return "Google Translate response decode failed: \(s.prefix(300))"
        }
    }
}

/// HTTP client for Cloud Translation API v2 (`language.translate`).
final class GoogleTranslateRestClient: GoogleTranslateRestClienting, @unchecked Sendable {

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
        print("[GoogleTranslate] GoogleTranslateRestClient init (API key length=\(apiKey.count))")
    }

    func translate(text: String, targetLanguageCode: String) async throws -> String {
        guard var components = URLComponents(url: GoogleTranslateConfiguration.translateV2URL, resolvingAgainstBaseURL: false)
        else {
            throw GoogleTranslateRestError.decodeFailed("Invalid translate URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw GoogleTranslateRestError.decodeFailed("Could not build request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = GoogleTranslateV2RequestBody(q: [text], target: targetLanguageCode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)

        let wallStart = CFAbsoluteTimeGetCurrent()
        print(
            "[GoogleTranslate] POST v2 target=\(targetLanguageCode) source=auto chars=\(text.count)"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleTranslateRestError.nonHTTPResponse
        }

        let bodySnippet = String(data: data, encoding: .utf8) ?? "(binary)"
        if !(200 ..< 300).contains(http.statusCode) {
            print("[GoogleTranslate] HTTP \(http.statusCode) bodyPrefix=\(bodySnippet.prefix(500))")
            throw GoogleTranslateRestError.httpStatus(code: http.statusCode, body: bodySnippet)
        }

        if let errEnv = try? JSONDecoder().decode(GoogleTranslateAPIErrorEnvelope.self, from: data), errEnv.error != nil {
            let msg = errEnv.error?.message ?? "unknown"
            print("[GoogleTranslate] API error envelope message=\(msg)")
            throw GoogleTranslateRestError.httpStatus(code: http.statusCode, body: msg)
        }

        do {
            let decoded = try JSONDecoder().decode(GoogleTranslateV2Response.self, from: data)
            guard let first = decoded.data.translations.first else {
                throw GoogleTranslateRestError.emptyTranslations
            }
            let out = first.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let wall = CFAbsoluteTimeGetCurrent() - wallStart
            print("[GoogleTranslate] OK chars=\(out.count) wall=\(String(format: "%.3f", wall))s")
            return out
        } catch {
            print("[GoogleTranslate] decode failed error=\(error.localizedDescription) snippet=\(bodySnippet.prefix(400))")
            throw GoogleTranslateRestError.decodeFailed(bodySnippet)
        }
    }
}
