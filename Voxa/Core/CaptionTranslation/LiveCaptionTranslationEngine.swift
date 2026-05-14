import Foundation

/// Which backend produces live caption correction + translation.
enum LiveCaptionTranslationEngine: String, CaseIterable, Identifiable, Sendable {
    case gpt
    case googleTranslate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt: return "ChatGPT"
        case .googleTranslate: return "Google Translate"
        }
    }
}
