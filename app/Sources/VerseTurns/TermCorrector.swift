import Foundation

/// Conservative correction of the session's own names in recognizer text (2026-11-12).
///
/// Apple's `SpeechTranscriber` (English and Italian) ignores the analyzer's contextual strings (measured: the same audio
/// gave the same text with and without them), and Nemotron has no vocabulary input at all, so a name the pack is built
/// around comes back misspelled: "Lantern" as "l'anterna", "l'anterm", "Lanter"; "Halden" as "al Den". Only names the
/// session itself knows are targets (words of its glossary terms and name facts, and capitalized words inside its bank
/// questions; five letters or more, not acronyms), and only three shapes of near miss are rewritten:
///
/// 1. Italian elision: "l'" or "d'" glued to the rest of a name ("l'anterna" -> "Lantern"; "lanterna" alone, an Italian word,
///    is never touched).
/// 2. A capitalized word inside a sentence (the recognizer took it for a name) with the same first letter as a target and
///    within one edit of it (two from eight letters): "Lanter" -> "Lantern".
/// 3. Two words next to each other, one of them capitalized inside a sentence, that together are one edit from a target:
///    "al Den" -> "Halden".
///
/// Never rewritten: a word the session itself writes in lower case (in a bank question, a fact or a glossary line), a function
/// word, a word that already is a target, a sentence-initial capital (it says nothing), and a near miss that two targets
/// claim equally.
public struct TermCorrector: Sendable {
    struct Target: Sendable {
        var canonical: String
        var folded: String
    }

    private let targets: [Target]
    private let ordinary: Set<String>

    public static let empty = TermCorrector(targets: [], ordinary: [])

    private init(targets: [Target], ordinary: Set<String>) {
        self.targets = targets
        self.ordinary = ordinary
    }

    public init(bank: Bank, facts: FactIndex) {
        var ordinary = BankMatcher.functionWords
        let bankPhrases = bank.entries.flatMap { e in [e.question] + e.paraphrases.keys.sorted().flatMap { e.paraphrases[$0] ?? [] } }
        for s in bankPhrases + facts.sentences {
            for tok in Self.tokens(s) where !(tok.text.first?.isUppercase ?? false) { ordinary.insert(Self.fold(tok.text)) }
        }
        var seen = Set<String>()
        var targets: [Target] = []
        func add(_ word: String) {
            let f = Self.fold(word)
            guard word.count >= 5, word.first?.isUppercase == true, word.dropFirst().contains(where: \.isLowercase),
                  !word.contains("'"), !ordinary.contains(f), seen.insert(f).inserted else { return }
            targets.append(Target(canonical: word, folded: f))
        }
        for name in facts.glossaryTerms + facts.nameValues {
            for tok in Self.tokens(name) { add(tok.text) }
        }
        for s in bankPhrases {
            for tok in Self.tokens(s) where !tok.sentenceStart { add(tok.text) }
        }
        self.init(targets: targets, ordinary: ordinary)
    }

    public var isEmpty: Bool { targets.isEmpty }

    /// The canonical spellings this corrector writes (for logs and tests).
    public var targetNames: [String] { targets.map(\.canonical) }

    /// `text` with near misses of the session's names replaced by the names. `lang` is the recognizer's language (the
    /// elision rule is Italian only).
    public func correct(_ text: String, lang: String) -> String {
        guard !targets.isEmpty else { return text }
        let toks = Self.tokens(text)
        guard !toks.isEmpty else { return text }
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if let name = elided(t, lang: lang) ?? capitalized(t) {
                replacements.append((t.range, name))
                i += 1
                continue
            }
            if i + 1 < toks.count, let name = split(t, toks[i + 1], in: text) {
                replacements.append((t.range.lowerBound..<toks[i + 1].range.upperBound, name))
                i += 2
                continue
            }
            i += 1
        }
        guard !replacements.isEmpty else { return text }
        var out = text
        for (r, s) in replacements.reversed() { out.replaceSubrange(r, with: s) }
        return out
    }

    // MARK: rules

    private func elided(_ t: Token, lang: String) -> String? {
        guard lang == "it", let apo = t.text.firstIndex(of: "'") else { return nil }
        let pre = Self.fold(String(t.text[..<apo])), rest = String(t.text[t.text.index(after: apo)...])
        guard pre == "l" || pre == "d", rest.count >= 3, !ordinary.contains(Self.fold(rest)) else { return nil }
        let joined = Self.fold(pre + rest)
        if let exact = targets.first(where: { $0.folded == joined }) { return exact.canonical }     // "l'antern"
        return unique(joined, sameFirstLetter: true)
    }

    private func capitalized(_ t: Token) -> String? {
        guard !t.sentenceStart, !t.text.contains("'"), t.text.first?.isUppercase == true, t.text.count >= 4 else { return nil }
        let f = Self.fold(t.text)
        guard !ordinary.contains(f), !targets.contains(where: { $0.folded == f }) else { return nil }
        return unique(f, sameFirstLetter: true)
    }

    private func split(_ a: Token, _ b: Token, in text: String) -> String? {
        guard capitalized(b) == nil, !a.text.contains("'"), !b.text.contains("'"),
              text[a.range.upperBound..<b.range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
        let capA = !a.sentenceStart && a.text.first?.isUppercase == true && !ordinary.contains(Self.fold(a.text))
        let capB = b.text.first?.isUppercase == true && !ordinary.contains(Self.fold(b.text))
        guard capA || capB else { return nil }
        let joined = Self.fold(a.text + b.text)
        guard !targets.contains(where: { $0.folded == Self.fold(a.text) || $0.folded == Self.fold(b.text) }) else { return nil }
        return unique(joined, sameFirstLetter: false, maxEdits: 1)
    }

    /// The one target within reach of `word` (closest wins; a tie is no answer).
    private func unique(_ word: String, sameFirstLetter: Bool, maxEdits: Int? = nil) -> String? {
        var best: (Target, Int)?
        var tie = false
        for t in targets where t.folded != word {
            // Same first letter; an initial "h" is silent in Italian ("Alden" for "Halden").
            if sameFirstLetter, t.folded.first != word.first, !(t.folded.first == "h" && t.folded.dropFirst().first == word.first) { continue }
            let limit = min(maxEdits ?? Int.max, t.folded.count >= 8 ? 2 : 1)
            guard abs(t.folded.count - word.count) <= limit else { continue }
            let d = BankMatcher.charDistance(Array(word), Array(t.folded), limit: limit)
            guard d <= limit else { continue }
            if let b = best {
                if d < b.1 { best = (t, d); tie = false } else if d == b.1 { tie = true }
            } else {
                best = (t, d)
            }
        }
        return tie ? nil : best?.0.canonical
    }

    // MARK: tokens

    struct Token {
        var text: String
        var range: Range<String.Index>
        /// First word of the text or of a sentence (after . ? !): its capital letter says nothing.
        var sentenceStart: Bool
    }

    /// Words with their ranges: letters and digits, an apostrophe inside a word stays ("l'anterna").
    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var pendingStart = true
        var curStart = true
        var i = s.startIndex
        func close(at end: String.Index) {
            guard let st = start else { return }
            var e = end
            while e > st, s[s.index(before: e)] == "'" || s[s.index(before: e)] == "\u{2019}" { e = s.index(before: e) }
            if e > st { out.append(Token(text: String(s[st..<e]).replacingOccurrences(of: "\u{2019}", with: "'"), range: st..<e, sentenceStart: curStart)) }
            start = nil
        }
        while i < s.endIndex {
            let ch = s[i]
            if ch.isLetter || ch.isNumber {
                if start == nil { start = i; curStart = pendingStart; pendingStart = false }
            } else if (ch == "'" || ch == "\u{2019}") && start != nil {
                // stays inside the word
            } else {
                close(at: i)
                if ".?!".contains(ch) { pendingStart = true }
            }
            i = s.index(after: i)
        }
        close(at: s.endIndex)
        return out
    }

    static func fold(_ s: String) -> String { Text.fold(s).lowercased() }
}
