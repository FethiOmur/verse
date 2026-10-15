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

/// Lines a model writes to say "nothing to say": `NONE`, `SAY: NONE`, `- none`, `N/A`, `SKIP`. They must never reach a
/// card. The brain strips them (`brain/verse_brain/runtime/lines.py`); this is the same rule on the Swift side, so a
/// sentinel that slips past (an older brain, a new model habit) still renders as nothing.
public enum ModelLine {
    static let sentinels: Set<String> = ["none", "null", "n/a", "skip"]
    private static let open = CharacterSet(charactersIn: "([{<\"'`*_")
    private static let close = CharacterSet(charactersIn: ".!:;,)]}>\"'`*_ ")

    /// True when the whole line is a sentinel: behind an optional `SAY:` / `- ` marker, in brackets or quotes and with a
    /// closing full stop, in any case. "None of the pilots failed." is a sentence, not a sentinel.
    public static func isSentinel(_ line: String) -> Bool {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("say") {
            let rest = s.dropFirst(3).drop { $0 == " " || $0 == "\t" }
            if rest.first == ":" { s = String(rest.dropFirst()) }
        } else if let f = s.first, "-\u{2022}*".contains(f) {
            s = String(s.dropFirst())
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.unicodeScalars.first, open.contains(f) { s.unicodeScalars.removeFirst() }
        while let l = s.unicodeScalars.last, close.contains(l) { s.unicodeScalars.removeLast() }
        return sentinels.contains(s.lowercased())
    }
}
