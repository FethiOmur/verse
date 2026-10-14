import Foundation

/// One word of a transcript with the punctuation that came right before it in the raw text.
struct Word: Equatable {
    var text: String            // lower-cased, letters/digits/apostrophes only
    var afterBoundary: Bool     // a clause boundary (. ? ! , ; : or a dash) sits between this word and the one before
}

enum Text {
    static func locale(_ lang: String) -> Locale {
        switch lang {
        case "tr": return Locale(identifier: "tr_TR")
        case "it": return Locale(identifier: "it_IT")
        default: return Locale(identifier: "en_US")
        }
    }

    private static let boundaryChars: Set<Character> = [".", "?", "!", ",", ";", ":", "\u{2014}", "\u{2013}", "\u{2026}"]

    /// Splits into words; apostrophes inside a word stay ("what's"), everything else that is not a letter or digit
    /// separates words.
    static func words(_ s: String, lang: String = "en") -> [Word] {
        let lowered = s.lowercased(with: locale(lang))
        var out: [Word] = []
        var cur = ""
        var boundary = true
        var pendingBoundary = true
        func flush() {
            if !cur.isEmpty {
                out.append(Word(text: cur, afterBoundary: boundary))
                cur = ""
                pendingBoundary = false
            }
        }
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                if cur.isEmpty { boundary = pendingBoundary }
                cur.append(ch)
            } else if (ch == "'" || ch == "\u{2019}") && !cur.isEmpty {
                cur.append("'")
            } else {
                flush()
                if boundaryChars.contains(ch) { pendingBoundary = true }
            }
        }
        flush()
        // A trailing apostrophe is not part of the word.
        return out.map { w in
            var t = w.text
            while t.hasSuffix("'") { t.removeLast() }
            return Word(text: t, afterBoundary: w.afterBoundary)
        }.filter { !$0.text.isEmpty }
    }

    static func tokens(_ s: String, lang: String = "en") -> [String] {
        words(s, lang: lang).map(\.text)
    }

    /// Lower-case, diacritics folded, for name and term comparison.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    static func foldedTokens(_ s: String) -> [String] {
        words(fold(s)).map(\.text)
    }

    /// Token-level Levenshtein distance.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1]
            for (j, y) in b.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Rounds to milliseconds so JSON lines stay short and stable.
    static func ms(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
