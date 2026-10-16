import Foundation

/// A fact or glossary hit worth showing as a chip. Chips are for the overlay; they are not sent to the brain.
public struct ChipMatch: Sendable, Equatable {
    public var id: String
    public var kind: String          // "number" | "date" | "name" | "term"
    public var text: String
    public var sourceRef: String
}

public struct FactIndex: Sendable {
    struct Fact: Sendable {
        var id: String, kind: String, text: String, value: String, sourceRef: String
        var tokens: [String]          // folded tokens of `value` (names)
        var number: Double?           // numeric value (numbers)
        var dateAliases: [[String]]   // token sequences (dates)
    }
    struct Term: Sendable {
        var id: String, term: String, line: String, sourceRef: String
        var tokens: [String]
    }

    private let facts: [Fact]
    private let terms: [Term]

    public static let empty = FactIndex(facts: [], glossary: [])

    public struct FactRecord: Sendable {
        public var id: String, kind: String, text: String, value: String, sourceRef: String
        public init(id: String, kind: String, text: String, value: String, sourceRef: String) {
            self.id = id; self.kind = kind; self.text = text; self.value = value; self.sourceRef = sourceRef
        }
    }
    public struct GlossaryRecord: Sendable {
        public var id: String, term: String, line: String, sourceRef: String
        public init(id: String, term: String, line: String, sourceRef: String) {
            self.id = id; self.term = term; self.line = line; self.sourceRef = sourceRef
        }
    }

    public init(facts: [FactRecord], glossary: [GlossaryRecord]) {
        self.facts = facts.map { f in
            Fact(id: f.id, kind: f.kind, text: f.text, value: f.value, sourceRef: f.sourceRef,
                 tokens: Text.foldedTokens(f.value),
                 number: f.kind == "number" ? Self.parseNumber(f.value) : nil,
                 dateAliases: f.kind == "date" ? Self.dateAliases(f.value) : [])
        }
        self.terms = glossary.map { Term(id: $0.id, term: $0.term, line: $0.line, sourceRef: $0.sourceRef, tokens: Text.foldedTokens($0.term)) }
    }

    /// Reads `facts.jsonl` and `glossary.jsonl` from a P1-1 session folder. Missing files are empty.
    ///
    /// `meFacts` (anytime calls): the NUMBERS of the permanent profile, `me.facts.jsonl`, in the same schema. They are
    /// chips and grounding like the session's own facts, labelled "my profile" (`me:<id>`). A profile fact that says what a
    /// session fact already says (same kind and value) is left out: the meeting pack wins on a conflict, and one chip is
    /// enough. A missing or unreadable profile file adds nothing.
    public static func load(sessionDir: URL, meFacts: URL?) throws -> FactIndex {
        let session = try load(sessionDir: sessionDir)
        guard let meFacts, let me = try? loadFacts(file: meFacts) else { return session }
        let seen = Set(session.facts.map { "\($0.kind)|\($0.value)" })
        let extra = me.filter { !seen.contains("\($0.kind)|\($0.value)") }
            .map { FactRecord(id: $0.id, kind: $0.kind, text: $0.text, value: $0.value, sourceRef: "me:\($0.id)") }
        return FactIndex(facts: session.facts.map { FactRecord(id: $0.id, kind: $0.kind, text: $0.text, value: $0.value, sourceRef: $0.sourceRef) } + extra,
                         glossary: session.terms.map { GlossaryRecord(id: $0.id, term: $0.term, line: $0.line, sourceRef: $0.sourceRef) })
    }

    private static func loadFacts(file url: URL) throws -> [FactRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { line -> FactRecord? in
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let kind = o["kind"] as? String else { return nil }
            let value: String
            if let s = o["value"] as? String { value = s } else if let n = o["value"] as? NSNumber { value = n.stringValue } else { value = "" }
            return FactRecord(id: id, kind: kind, text: o["text"] as? String ?? value, value: value, sourceRef: "")
        }
    }

    public static func load(sessionDir: URL) throws -> FactIndex {
        func records(_ name: String) throws -> [[String: Any]] {
            let url = sessionDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        func ref(_ o: [String: Any]) -> String {
            ((o["sources"] as? [[String: Any]])?.first?["ref"] as? String) ?? ""
        }
        let facts = try records("facts.jsonl").compactMap { o -> FactRecord? in
            guard let id = o["id"] as? String, let kind = o["kind"] as? String else { return nil }
            let value: String
            if let s = o["value"] as? String { value = s } else if let n = o["value"] as? NSNumber { value = n.stringValue } else { value = "" }
            return FactRecord(id: id, kind: kind, text: o["text"] as? String ?? value, value: value, sourceRef: ref(o))
        }
        let gloss = try records("glossary.jsonl").compactMap { o -> GlossaryRecord? in
            guard let id = o["id"] as? String, let term = o["term"] as? String else { return nil }
            return GlossaryRecord(id: id, term: term, line: o["line"] as? String ?? "", sourceRef: ref(o))
        }
        return FactIndex(facts: facts.sorted { $0.id < $1.id }, glossary: gloss.sorted { $0.id < $1.id })
    }

    public var isEmpty: Bool { facts.isEmpty && terms.isEmpty }

    /// Folded token sequences of the glossary terms and of the name facts, for `SessionTerms`.
    var glossaryTokenLists: [[String]] { terms.map(\.tokens).filter { !$0.isEmpty } }
    var nameTokenLists: [[String]] { facts.filter { $0.kind == "name" }.map(\.tokens).filter { !$0.isEmpty } }
    /// True when `text` carries a number or a date the fact sheet knows ("42K budget").
    func hasNumberOrDate(in text: String) -> Bool {
        chips(in: text).contains { $0.kind == "number" || $0.kind == "date" }
    }

    // MARK: matching

    /// Chips for everything in `text` that the fact sheet or glossary knows: names and terms as whole words
    /// (case and accent insensitive), numbers by value ("42K", "42,000" and "42000" are the same), dates by day + month.
    public func chips(in text: String) -> [ChipMatch] {
        guard !isEmpty else { return [] }
        let toks = Text.foldedTokens(text)
        let numbers = Self.numbers(in: text)
        var out: [ChipMatch] = []
        for f in facts {
            let hit: Bool
            switch f.kind {
            case "number":
                hit = f.number.map { v in numbers.contains { abs($0 - v) < 1e-9 * max(1, abs(v)) } } ?? false
            case "date":
                hit = f.dateAliases.contains { Self.contains(toks, $0) }
            default: // name
                hit = Self.contains(toks, f.tokens)
                    || (f.tokens.count > 1 && (f.tokens.first.map { $0.count >= 4 && toks.contains($0) } ?? false))
            }
            if hit { out.append(ChipMatch(id: f.id, kind: f.kind, text: f.text, sourceRef: f.sourceRef)) }
        }
        for t in terms where Self.contains(toks, t.tokens) {
            out.append(ChipMatch(id: t.id, kind: "term", text: t.line.isEmpty ? t.term : "\(t.term): \(t.line)", sourceRef: t.sourceRef))
        }
        return out
    }

    /// A fact or glossary entry as a topic the topic trigger can match by similarity (plan F4): `phrase` is what the
    /// matcher indexes, `label` is what the chip shows.
    struct TopicDoc: Sendable, Equatable {
        var id: String, phrase: String, label: String, sourceRef: String
    }

    /// Every fact (by its sentence) and every glossary term that has a definition line, when long enough to be a
    /// topic rather than a bare word. Bare names, numbers and terms are the exact chips' job.
    var topicDocs: [TopicDoc] {
        let minChars = 12
        var out: [TopicDoc] = []
        for f in facts where f.text.count >= minChars {
            out.append(TopicDoc(id: f.id, phrase: f.text, label: f.text, sourceRef: f.sourceRef))
        }
        for t in terms where !t.line.isEmpty && t.term.count + t.line.count >= minChars {
            out.append(TopicDoc(id: t.id, phrase: "\(t.term) \(t.line)", label: "\(t.term): \(t.line)", sourceRef: t.sourceRef))
        }
        return out
    }

    static func contains(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }

    // MARK: numbers

    /// "42K" -> 42000, "38,000" -> 38000, "96.4" -> 96.4, "2 million" -> 2e6. nil when `s` holds no number.
    static func parseNumber(_ s: String) -> Double? {
        numbers(in: s, keepSmall: true).first
    }

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.])(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?\s?(k|m|thousand|million|billion)?(?![\w])"#,
        options: [.caseInsensitive])

    /// Numbers written as digits. Whole numbers below 10 are skipped (too ambiguous in speech) unless `keepSmall`.
    static func numbers(in text: String, keepSmall: Bool = false) -> [Double] {
        let ns = text as NSString
        var out: [Double] = []
        for m in numberRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            var isDecimal = false
            if m.range(at: 2).location != NSNotFound { s += ns.substring(with: m.range(at: 2)); isDecimal = true }
            guard var v = Double(s) else { continue }
            if m.range(at: 3).location != NSNotFound {
                switch ns.substring(with: m.range(at: 3)).lowercased() {
                case "k", "thousand": v *= 1_000
                case "m", "million": v *= 1_000_000
                case "billion": v *= 1_000_000_000
                default: break
                }
            } else if !keepSmall && !isDecimal && v < 10 {
                continue
            }
            out.append(v)
        }
        return out
    }

    // MARK: dates

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                 "october", "november", "december"]

    /// "2026-10-22" -> [["22","october"], ["october","22"], ["22nd","october"], ["october","22nd"], ["22","of","october"]].
    static func dateAliases(_ iso: String) -> [[String]] {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return [] }
        let month = months[parts[1] - 1]
        let d = parts[2]
        let suffix: String
        switch (d % 10, d / 10 == 1) {
        case (1, false): suffix = "st"
        case (2, false): suffix = "nd"
        case (3, false): suffix = "rd"
        default: suffix = "th"
        }
        let day = String(d), ord = day + suffix
        return [[day, month], [month, day], [ord, month], [month, ord], [day, "of", month], [ord, "of", month]]
    }
}
