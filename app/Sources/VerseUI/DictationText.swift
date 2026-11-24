import Foundation

// The text a dictation inserts, between the engine and the paste: transcript -> corrections (gap G11) -> smart insertion
// (gap G13) -> paste. The recent-dictations list keeps the corrected text, before smart insertion (that depends on where it
// is pasted). The language a dictation listens in (gap G12) is resolved here too. All pure.

/// One "heard -> wanted" replacement of the corrections list (gap G11).
public struct DictationCorrection: Sendable, Equatable {
    public var heard: String
    public var wanted: String
    public init(heard: String, wanted: String) {
        self.heard = heard
        self.wanted = wanted
    }
}

/// The corrections list: parsed from Settings' text (one "heard -> wanted" per line) and applied to the final transcript.
///
/// Matching (after TypeWhisper's dictionary corrections, without its regex and case-sensitive options): whole words and
/// whole phrases only (a boundary is required on each side whose edge character is a letter or digit), case-insensitive with
/// the dictation language's case folding (Turkish: I/ı and İ/i are pairs; other languages: I/i, and İ folds to i), the
/// longest phrase first at each position, in one left-to-right pass, so a replacement is never matched again (no chains).
/// A space in "heard" matches a run of whitespace (spaces, tabs, line breaks) in the text. An empty "wanted" removes the
/// phrase together with one neighbouring space, and with one of two punctuation marks it would leave in a row (or a mark it
/// would leave at the start).
public enum DictationCorrections {
    /// At most this many lines are used.
    public static let cap = 200
    /// The separators between "heard" and "wanted" (the first one on the line counts).
    static let separators = ["->", "→"]
    /// Punctuation that ends a clause or a sentence: a removed phrase does not leave two of them in a row.
    static let clauseMarks: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]
    /// The weaker ones: between a weak and a strong mark, the strong one stays.
    static let weakMarks: Set<Character> = [",", ";", ":"]

    /// One correction per line: "heard -> wanted" (or "heard → wanted"), both sides trimmed. Lines without a separator or
    /// with nothing heard are skipped; for a repeated "heard" (case-insensitive) the first line wins; at most `cap`.
    public static func parse(_ text: String) -> [DictationCorrection] {
        var seen = Set<String>()
        var out: [DictationCorrection] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            let hits = separators.compactMap { sep in s.range(of: sep).map { ($0, sep) } }
            guard let range = hits.min(by: { $0.0.lowerBound < $1.0.lowerBound })?.0 else { continue }
            let heard = s[..<range.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let wanted = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, seen.insert(DictationCase.folded(heard, turkish: false)).inserted else { continue }
            out.append(DictationCorrection(heard: heard, wanted: wanted))
            if out.count == cap { break }
        }
        return out
    }

    /// `text` with every correction applied (see the type's rules). `language`: "tr" folds case the Turkish way.
    public static func apply(_ corrections: [DictationCorrection], to text: String, language: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }
        let turkish = language == "tr"
        let chars = Array(text)
        let folded = chars.map { $0.isWhitespace ? " " : DictationCase.fold($0, turkish: turkish) }
        struct Pattern { var folded: [String]; var wanted: String; var leftEdge: Bool; var rightEdge: Bool }
        let patterns: [Pattern] = corrections.enumerated().compactMap { index, c -> (Int, Pattern)? in
            let p = Array(c.heard.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            guard let first = p.first, let last = p.last else { return nil }
            return (index, Pattern(folded: p.map { $0 == " " ? " " : DictationCase.fold($0, turkish: turkish) }, wanted: c.wanted,
                                   leftEdge: DictationCase.isWordCharacter(first), rightEdge: DictationCase.isWordCharacter(last)))
        }
        // Longest first; equal lengths keep the list's order.
        .sorted { $0.1.folded.count != $1.1.folded.count ? $0.1.folded.count > $1.1.folded.count : $0.0 < $1.0 }
        .map(\.1)

        /// Where a match of `p` starting at `start` ends, or nil. A space in the pattern takes a whole run of whitespace.
        func matchEnd(_ p: [String], at start: Int) -> Int? {
            var j = start
            for unit in p {
                guard j < chars.count else { return nil }
                if unit == " " {
                    guard chars[j].isWhitespace else { return nil }
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                } else {
                    guard folded[j] == unit else { return nil }
                    j += 1
                }
            }
            return j
        }

        var out = ""
        var removed = false
        var i = 0
        scan: while i < chars.count {
            for p in patterns {
                if p.leftEdge, i > 0, DictationCase.isWordCharacter(chars[i - 1]) { continue }
                guard var next = matchEnd(p.folded, at: i) else { continue }
                if p.rightEdge, next < chars.count, DictationCase.isWordCharacter(chars[next]) { continue }
                if p.wanted.isEmpty {
                    removed = true
                    // "so um I think" -> "so I think"; "so um." -> "so."
                    if out.isEmpty || out.last?.isWhitespace == true {
                        while next < chars.count, chars[next] == " " { next += 1 }
                    }
                    // A filler between punctuation, or at the start before punctuation, takes one of the marks with it:
                    // "so, um, I think" -> "so, I think"; "Um, so" -> "so"; "so, um. I think" -> "so. I think".
                    if next < chars.count, clauseMarks.contains(chars[next]) {
                        let prev = out.last(where: { !$0.isWhitespace })
                        if let prev, weakMarks.contains(prev), !weakMarks.contains(chars[next]) {
                            while out.last?.isWhitespace == true { out.removeLast() }
                            out.removeLast()
                        } else if prev == nil || clauseMarks.contains(prev!) {
                            next += 1
                            while next < chars.count, chars[next] == " " { next += 1 }
                        }
                    }
                    if next == chars.count || (!DictationCase.isWordCharacter(chars[next]) && !chars[next].isWhitespace),
                       out.last == " " {
                        out.removeLast()
                    }
                } else {
                    out += p.wanted
                }
                i = next
                continue scan
            }
            out.append(chars[i])
            i += 1
        }
        return removed ? out.trimmingCharacters(in: .whitespacesAndNewlines) : out
    }
}

/// Smart spacing and capitalisation (gap G13): the text adjusted to the text around the caret, after TypeWhisper's
/// `DictationInsertionTextFormatter`, kept to its conservative side. With either side of the caret unknown (the field could
/// not be read: browsers, terminals, Electron apps, secure fields) the text is inserted exactly as it is.
///
/// - A leading space when the character before the caret is a letter, a digit or closing punctuation and the text does not
///   itself start with punctuation that attaches to the left.
/// - A trailing space when the character right after the caret is a letter or a digit.
/// - Mid-sentence (the last character before the caret, spaces and tabs skipped but no line break, is a letter, a digit, a
///   comma or a semicolon) the first letter is lower-cased: only for a word that starts with a capital and has no other
///   capital (never "I" or "I'm", an all-capitals word such as "NASA", "GitHub", or a vocabulary term), the Turkish way
///   (I -> ı, İ -> i) when the dictation language is Turkish. In Turkish a word with a suffix after an apostrophe
///   ("Ankara'ya") is a proper noun and keeps its capital. Other names the engine capitalised are lower-cased unless they
///   are in the vocabulary: there is no signal to tell "John" from "Then".
/// - The text's single final period is dropped when the text right after the caret starts with punctuation, or when it is
///   inserted mid-sentence before more text on the same line. An ellipsis is never touched.
public enum DictationSmartInsertion {
    /// Punctuation that attaches to the word before it: no space before it, and a period before it goes.
    static let attaching: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "”", "’", "»", "%"]
    /// What a word may end with and still be followed by a space.
    static let closing: Set<Character> = attaching

    public static func format(_ text: String, before: String?, after: String?, language: String,
                              keepCase: [String] = []) -> String {
        guard let before, let after, !text.isEmpty else { return text }
        var t = text
        let mid = isMidSentence(before: before)
        if mid { t = lowercasingFirstWord(t, turkish: language == "tr", keepCase: keepCase) }
        if dropsFinalPeriod(after: after, midSentence: mid) { t = droppingFinalPeriod(t) }
        if needsLeadingSpace(before: before, text: t) { t = " " + t }
        if needsTrailingSpace(after: after, text: t) { t += " " }
        return t
    }

    /// The caret is clearly inside a sentence.
    static func isMidSentence(before: String) -> Bool {
        var trimmed = Substring(before)
        while let last = trimmed.last, last.isWhitespace {
            if last.isNewline { return false }
            trimmed.removeLast()
        }
        guard let last = trimmed.last else { return false }
        return last.isLetter || last.isNumber || last == "," || last == ";"
    }

    static func lowercasingFirstWord(_ text: String, turkish: Bool, keepCase: [String]) -> String {
        guard let first = text.first, first.isLetter, first.isUppercase else { return text }
        let word = text.prefix { !$0.isWhitespace }
        let core = String(word.prefix { $0.isLetter || $0.isNumber })
        let letters = word.filter(\.isLetter)
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || core == "I" { return text }
        if letters.count >= 2 && letters.allSatisfy(\.isUppercase) { return text }
        if letters.dropFirst().contains(where: \.isUppercase) { return text }
        if keepCase.contains(where: { $0 == core || $0.hasPrefix(core + " ") }) { return text }
        // Turkish writes an apostrophe only between a proper noun and its suffix: "Ankara'ya", "Ahmet’e".
        let rest = word.dropFirst(core.count)
        if turkish, let mark = rest.first, mark == "'" || mark == "’", rest.dropFirst().first?.isLetter == true { return text }
        return DictationCase.lowercased(first, turkish: turkish) + text.dropFirst()
    }

    static func dropsFinalPeriod(after: String, midSentence: Bool) -> Bool {
        guard let next = after.first else { return false }
        if attaching.contains(next) { return true }
        guard midSentence else { return false }
        guard let word = after.first(where: { !($0 == " " || $0 == "\t") }), !word.isNewline else { return false }
        return word.isLetter || word.isNumber
    }

    /// One final "." removed; "..", "..." and "…" stay, and so does a text that is only a period.
    static func droppingFinalPeriod(_ text: String) -> String {
        guard text.count > 1, text.last == ".", text.dropLast().last != "." else { return text }
        return String(text.dropLast())
    }

    static func needsLeadingSpace(before: String, text: String) -> Bool {
        guard let last = before.last, let first = text.first else { return false }
        if last.isWhitespace || first.isWhitespace || attaching.contains(first) { return false }
        return last.isLetter || last.isNumber || closing.contains(last)
    }

    static func needsTrailingSpace(after: String, text: String) -> Bool {
        guard let next = after.first, let last = text.last else { return false }
        guard next.isLetter || next.isNumber else { return false }
        return last.isLetter || last.isNumber || closing.contains(last)
    }
}

/// Case folding and lower-casing with the Turkish dotted and dotless i.
enum DictationCase {
    /// One character folded for a case-insensitive comparison. Turkish: I -> ı, İ -> i. Otherwise I -> i and İ -> i (not
    /// "i̇", so a Turkish name typed with a plain i still matches).
    static func fold(_ c: Character, turkish: Bool) -> String {
        switch c {
        case "İ": return "i"
        case "I": return turkish ? "ı" : "i"
        default: return String(c).lowercased()
        }
    }

    static func folded(_ s: String, turkish: Bool) -> String { s.map { fold($0, turkish: turkish) }.joined() }

    /// One character lower-cased the way the language writes it.
    static func lowercased(_ c: Character, turkish: Bool) -> String {
        if turkish { return String(c).lowercased(with: Locale(identifier: "tr")) }
        return c == "İ" ? "i" : String(c).lowercased()
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}

/// The language a dictation listens in (gap G12): the one chosen for the app in front, else the default.
public enum DictationLanguageChoice {
    /// `perApp` maps bundle ids to language codes. A code dictation cannot listen in is ignored; an unknown default falls
    /// back to English.
    public static func resolve(defaultLanguage: String, perApp: [String: String], bundleID: String?) -> String {
        if let bundleID, let lang = perApp[bundleID], DictationSettings.languages.contains(lang) { return lang }
        return DictationSettings.languages.contains(defaultLanguage) ? defaultLanguage : "en"
    }

    /// "TR", "EN", "IT": the recording indicator's language label.
    public static func shortCode(_ lang: String) -> String { lang.uppercased() }
}
