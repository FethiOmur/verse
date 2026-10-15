import Foundation

/// What a session knows by name: its glossary terms, the facts of its fact sheet and the phrases of its answer bank.
/// `Cues` uses it for one decision only (plan item "short noun-phrase questions", option B): a two or three word turn
/// with no question cue and no "?" ("Notice period") is a question when it names one of these, and a fragment otherwise.
public struct SessionTerms: Sendable {
    public static let empty = SessionTerms(bank: .empty, facts: .empty)

    private let glossary: [[String]]
    private let factNames: [[String]]
    private let bankPhrases: [[String]]
    private let facts: FactIndex

    public init(bank: Bank, facts: FactIndex) {
        self.facts = facts
        // A glossary term made only of everyday function words ("thanks", "so") says nothing about the topic.
        let everyday = Cues.functionWords(lang: "en").union(Cues.functionWords(lang: "it")).union(Cues.functionWords(lang: "tr"))
        glossary = facts.glossaryTokenLists.filter { !$0.allSatisfy(everyday.contains) }
        factNames = facts.nameTokenLists
        // Every question and paraphrase in every language: the recognizer's language may differ from the pack's.
        bankPhrases = bank.entries.flatMap { e in
            ([e.question] + e.paraphrases.keys.sorted().flatMap { e.paraphrases[$0] ?? [] }).map { Text.foldedTokens($0) }
        }.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { glossary.isEmpty && factNames.isEmpty && bankPhrases.isEmpty && facts.isEmpty }

    /// True when `text` names something the session knows:
    /// - a glossary term (one word is enough: the pack chose it on purpose),
    /// - a number or a date of the fact sheet ("42K budget"),
    /// - a fact name together with another content word ("Halden salary"; a name alone is just a greeting or an
    ///   address: "Thanks Marco"),
    /// - or at least two content words that sit side by side in a bank question or paraphrase ("notice period" in
    ///   "What is your notice period?"). A single bank word is too common ("Great experience.").
    public func names(_ text: String, lang: String = "en") -> Bool {
        guard !isEmpty else { return false }
        let toks = Text.foldedTokens(text)
        guard !toks.isEmpty else { return false }
        if glossary.contains(where: { FactIndex.contains(toks, $0) }) { return true }
        if facts.hasNumberOrDate(in: text) { return true }

        let function = Cues.functionWords(lang: lang)
        // Name facts: the turn needs content beyond the name itself.
        var covered = Set<Int>()
        for name in factNames where FactIndex.contains(toks, name) {
            for i in 0...(toks.count - name.count) where Array(toks[i..<(i + name.count)]) == name {
                covered.formUnion(i..<(i + name.count))
            }
        }
        if !covered.isEmpty,
           toks.indices.contains(where: { !covered.contains($0) && !function.contains(toks[$0]) }) { return true }

        // Bank phrases: the turn without its leading and trailing function words, two or more words side by side.
        guard let first = toks.firstIndex(where: { !function.contains($0) }),
              let last = toks.lastIndex(where: { !function.contains($0) }) else { return false }
        let core = Array(toks[first...last])
        guard core.count >= 2 else { return false }
        return bankPhrases.contains { FactIndex.contains($0, core) }
    }
}
