import Foundation

// MARK: - Cloud Translation API v2 (REST)

struct GoogleTranslateV2RequestBody: Encodable, Sendable {
    let q: [String]
    let target: String
    let format: String

    init(q: [String], target: String, format: String = "text") {
        self.q = q
        self.target = target
        self.format = format
    }
}

struct GoogleTranslateV2Response: Decodable, Sendable {
    struct DataLayer: Decodable, Sendable {
        struct Translation: Decodable, Sendable {
            let translatedText: String
            let detectedSourceLanguage: String?
        }

        let translations: [Translation]
    }

    let data: DataLayer
}

struct GoogleTranslateAPIErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let code: Int?
        let message: String?
    }

    let error: Detail?
}
