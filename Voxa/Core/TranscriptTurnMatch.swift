import Foundation

/// Decides whether a **late** translation response (built from an in-flight partial) should attach to a
/// **committed** transcript turn. Loose substring checks caused false merges (short tokens matching inside unrelated words).
enum TranscriptTurnMatch {

    /// `committed` is the finalized segment text; `inflight` is the transcript string the translation request used.
    static func likelySameTurn(committed: String, inflight: String) -> Bool {
        let a = Self.normalize(committed)
        let b = Self.normalize(inflight)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }

        let (longer, shorter) = a.count >= b.count ? (a, b) : (b, a)

        // Partial live caption growing into the final committed line (most common).
        if shorter.count >= 4, longer.hasPrefix(shorter) { return true }

        // In-flight line extended the committed text slightly before commit (less common).
        if shorter.count >= 4, longer.hasSuffix(shorter) { return true }

        // Substantial overlap only: avoid "in" ⊂ "interesting", "a" ⊂ "about", etc.
        if shorter.count >= 12, longer.contains(shorter) { return true }

        // Medium substring: require the shorter span to be a large fraction of the longer line.
        if shorter.count >= 8, longer.contains(shorter) {
            let ratio = Double(shorter.count) / Double(max(longer.count, 1))
            if ratio >= 0.45 { return true }
        }

        return false
    }

    /// For late completions after a segment commit: ASR often **revises** early words on long lines, so strict
    /// `likelySameTurn` can reject a valid pairing. Use after `likelySameTurn` fails when either side is long.
    static func likelySameTurnLenient(committed: String, inflight: String) -> Bool {
        if likelySameTurn(committed: committed, inflight: inflight) { return true }
        let a = Self.normalize(committed)
        let b = Self.normalize(inflight)
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard max(a.count, b.count) >= 36 else { return false }

        let (longer, shorter) = a.count >= b.count ? (a, b) : (b, a)
        let probeLen = min(56, shorter.count)
        if probeLen >= 18 {
            let prefix = String(shorter.prefix(probeLen))
            if longer.hasPrefix(prefix) { return true }
        }

        var commonPrefix = 0
        for (x, y) in zip(a, b) {
            if x != y { break }
            commonPrefix += 1
        }
        let need = min(28, min(a.count, b.count) / 2)
        return commonPrefix >= need
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
