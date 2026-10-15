import Foundation

/// A matcher that remembers its answers. The bank hit and the topic trigger ask the same matcher about the same text
/// (the open turn) at every partial, and the topic trigger asks again about pieces that did not change.
final class MatchCache {
    let matcher: BankMatcher
    private var memo: [String: [BankMatcher.Candidate]] = [:]
    private static let limit = 256

    init(_ matcher: BankMatcher) { self.matcher = matcher }

    var isEmpty: Bool { matcher.isEmpty }

    func top2(_ text: String) -> [BankMatcher.Candidate] {
        if let r = memo[text] { return r }
        if memo.count >= Self.limit { memo.removeAll(keepingCapacity: true) }
        let r = matcher.top2(text)
        memo[text] = r
        return r
    }

    /// The best entry when it clears `threshold` and leads the runner-up by `margin` (`BankMatcher.match` on the memo).
    func match(_ text: String, threshold: Double, margin: Double) -> BankMatcher.Candidate? {
        let top = top2(text)
        guard let first = top.first, first.score >= threshold else { return nil }
        if top.count > 1, first.score - top[1].score < margin { return nil }
        return first
    }
}

/// Topic trigger (plan F4). When the last few seconds of remote speech come close to a bank entry or a fact / glossary
/// topic and nobody asked a question, the overlay gets a slim `chip{kind:"topic"}`. Local only: the same character
/// n-gram matcher as the bank hit, no brain call.
///
/// The engine owns one value of this type. It keeps the finalized pieces of recent remote speech; the open turn's
/// pieces are passed in at every evaluation.
struct TopicTrigger {
    /// A piece of remote speech and the session time it was last heard.
    struct Piece: Equatable {
        var at: Double
        var text: String
        /// The remote turn the piece came from ("" when unknown), so a turn can be taken out again.
        var turn = ""
    }

    struct Hit: Equatable {
        var id: String
        var text: String
        var sourceRef: String
        var score: Double
    }

    private struct Label {
        var text: String
        var ref: String
    }

    private let enabled: Bool
    private let threshold: Double
    private let margin: Double
    private let window: Double
    private let cooldown: Double
    private let sameID: Double
    private let bankMatcher: MatchCache
    private let factMatcher: MatchCache
    private let bankLabels: [String: Label]
    private let factLabels: [String: Label]

    /// Finalized remote speech inside the window (questions and bank hits are not kept: they have their own card).
    private var history: [Piece] = []
    private var lastChipAt = -Double.infinity
    private var shownAt: [String: Double] = [:]
    /// The newest sentences looked at on their own, besides each piece.
    private static let sentenceUnits = 4
    private static let maxUnitWords = 24

    init(config: TurnConfig, bank: Bank, bankMatches: MatchCache, facts: FactIndex) {
        enabled = config.topicEnabled
        threshold = config.topicThreshold
        margin = config.topicMargin
        window = config.topicWindowSeconds
        cooldown = config.topicCooldownSeconds
        sameID = config.topicSameIDSeconds
        self.bankMatcher = bankMatches
        var labels: [String: Label] = [:]
        for e in bank.entries { labels[e.id] = Label(text: Self.shorten(e.question, max: config.topicLabelMax), ref: e.sourceRef) }
        bankLabels = labels
        let docs = facts.topicDocs
        // Facts and glossary terms get their own matcher: a bank entry and a fact about the same project must not
        // count as each other's runner-up.
        factMatcher = MatchCache(BankMatcher(bank: Bank(entries: docs.map { BankEntry(id: $0.id, lang: config.lang, question: $0.phrase) }), lang: config.lang))
        factLabels = Dictionary(docs.map { ($0.id, Label(text: $0.label, ref: $0.sourceRef)) }, uniquingKeysWith: { a, _ in a })
    }

    /// A closed remote turn: its pieces stay in the window until they are older than it.
    mutating func noteClosed(_ pieces: [Piece], now: Double) {
        history.append(contentsOf: pieces)
        prune(now)
    }

    /// Takes a closed turn's pieces out of the window: the brain's paraphrase matcher found a prepared question in it, so
    /// it already has its own card and must not come back as a topic later.
    mutating func forget(turn: String) {
        history.removeAll { $0.turn == turn }
    }

    private mutating func prune(_ now: Double) {
        history.removeAll { $0.at < now - window }
    }

    /// The topic chip for the window ending at `now`, or nil. `current` are the pieces of the open turn; `skip` are
    /// ids that already have a chip in this turn. The caller has checked that the open turn has no question cue and
    /// no bank hit.
    mutating func evaluate(now: Double, current: [Piece], skip: Set<String>) -> Hit? {
        guard enabled, !(bankMatcher.isEmpty && factMatcher.isEmpty) else { return nil }
        guard now - lastChipAt >= cooldown else { return nil }
        prune(now)
        let pieces = (history + current.filter { $0.at >= now - window }).filter { !$0.text.isEmpty }
        guard !pieces.isEmpty else { return nil }
        // Each piece of the window and its newest sentences are matched on their own: a topic mentioned in one sentence
        // is not diluted by the other sentences around it, and a piece that did not change is answered from the memo.
        // The whole window as one text is not matched: its query is the longest of all (the cost grows with the length of
        // the query) and it only adds topics that are split across a silence of 0.6 s or more. Every unit is cut to its
        // last `maxUnitWords` words, which bounds the cost of a long monologue.
        var units: [String] = []
        var seen: Set<String> = []
        func add(_ text: String, into list: inout [String]) {
            let t = Self.tail(text, words: Self.maxUnitWords)
            if !t.isEmpty, seen.insert(t).inserted { list.append(t) }
        }
        var sentences: [String] = []
        for p in pieces {
            add(p.text, into: &units)
            for s in p.text.split(whereSeparator: { ".?!".contains($0) }) { add(String(s), into: &sentences) }
        }
        units += sentences.suffix(Self.sentenceUnits)

        var best: Hit?
        for u in units {
            let r = (bank: bankMatcher.isEmpty ? nil : bankMatcher.match(u, threshold: threshold, margin: margin),
                     fact: factMatcher.isEmpty ? nil : factMatcher.match(u, threshold: threshold, margin: margin))
            for (cand, labels) in [(r.bank, bankLabels), (r.fact, factLabels)] {
                guard let c = cand, !skip.contains(c.id) else { continue }
                if let at = shownAt[c.id], now - at < sameID { continue }
                if c.score > (best?.score ?? -1), let l = labels[c.id] {
                    best = Hit(id: c.id, text: l.text, sourceRef: l.ref, score: c.score)
                }
            }
        }
        guard let hit = best else { return nil }
        lastChipAt = now
        shownAt[hit.id] = now
        return hit
    }

    /// The last `words` words of `s`, whitespace collapsed.
    static func tail(_ s: String, words: Int) -> String {
        s.split(whereSeparator: \.isWhitespace).suffix(words).joined(separator: " ")
    }

    /// At most `max` characters, cut at a word and closed with an ellipsis.
    static func shorten(_ s: String, max: Int) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > max, max > 1 else { return t }
        var cut = String(t.prefix(max - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= max / 2 { cut = String(cut[..<space]) }
        while let l = cut.last, l == " " || ",;:.-".contains(l) { cut.removeLast() }
        return cut + "\u{2026}"
    }
}
