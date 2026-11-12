import Foundation

/// One prepared question from `bank.jsonl` (the fields the matcher needs; the rest is the brain's business).
public struct BankEntry: Sendable, Equatable {
    public var id: String
    public var lang: String
    public var question: String
    public var paraphrases: [String: [String]]
    /// The first source ref of the entry (`prep:L14`); "" when it has none. Shown on topic chips.
    public var sourceRef: String

    public init(id: String, lang: String = "en", question: String, paraphrases: [String: [String]] = [:], sourceRef: String = "") {
        self.id = id
        self.lang = lang
        self.question = question
        self.paraphrases = paraphrases
        self.sourceRef = sourceRef
    }

    /// The question plus the paraphrases in `lang` (all languages when `lang` has none).
    func phrases(for lang: String) -> [String] {
        var out = [question]
        if let p = paraphrases[lang], !p.isEmpty {
            out += p
        } else {
            out += paraphrases.keys.sorted().flatMap { paraphrases[$0] ?? [] }
        }
        return out
    }
}

public struct Bank: Sendable {
    public var entries: [BankEntry]

    public init(entries: [BankEntry]) { self.entries = entries }

    public static let empty = Bank(entries: [])

    /// Reads `<session>/bank.jsonl` (the P1-1 session folder contract). A missing file is an empty bank.
    public static func load(sessionDir: URL) throws -> Bank {
        let url = sessionDir.appendingPathComponent("bank.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        var entries: [BankEntry] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let q = obj["question"] as? String else { continue }
            var para: [String: [String]] = [:]
            if let p = obj["paraphrases"] as? [String: Any] {
                for (k, v) in p { para[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
            }
            let ref = ((obj["sources"] as? [[String: Any]])?.first?["ref"] as? String) ?? ""
            entries.append(BankEntry(id: id, lang: obj["lang"] as? String ?? "en", question: q, paraphrases: para, sourceRef: ref))
        }
        return Bank(entries: entries.sorted { $0.id < $1.id })
    }
}

/// Character 3-5-gram TF-IDF over every question and paraphrase, cosine similarity, one score per bank entry
/// (the best of its phrases). Copes with Turkish morphology and with half-spoken questions better than word matching.
public struct BankMatcher: Sendable {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var score: Double
    }

    private static let ngramSizes = [3, 4, 5]

    private struct Posting { var doc: Int32; var weight: Float }

    private let entryIDs: [String]
    private let docEntry: [Int32]                    // doc -> entry index
    private let postings: [UInt64: [Posting]]        // n-gram hash -> docs containing it
    private let idf: [UInt64: Float]
    private let unknownIDF: Float
    /// Word level view of the same phrases, for `coverage`: entry -> phrases.
    private let entryPhraseWords: [[PhraseWords]]
    /// Content words of every phrase of an entry, phrase by phrase (question and paraphrases, every language: what
    /// `SessionTerms` treats as the entry's words).
    private let entryPhraseSets: [[Set<String>]]
    /// Entry-level inverse document frequency of each content word of the bank.
    private let wordIDF: [String: Double]
    private let unknownWordIDF: Double

    public init(bank: Bank, lang: String) {
        var entryIDs: [String] = []
        var docNgrams: [[UInt64: Int]] = []
        var docEntry: [Int32] = []
        var phraseWords: [[PhraseWords]] = []
        var wordSets: [Set<String>] = []
        var phraseSets: [[Set<String>]] = []
        for (ei, entry) in bank.entries.enumerated() {
            entryIDs.append(entry.id)
            var words: [PhraseWords] = []
            for phrase in entry.phrases(for: lang) {
                let counts = Self.ngramCounts(phrase)
                if counts.isEmpty { continue }
                docNgrams.append(counts)
                docEntry.append(Int32(ei))
                words.append(PhraseWords(phrase))
            }
            phraseWords.append(words)
            let all = [entry.question] + entry.paraphrases.keys.sorted().flatMap { entry.paraphrases[$0] ?? [] }
            wordSets.append(Set(all.flatMap(Self.contentWords)))
            phraseSets.append(all.map { Set(Self.contentWords($0)) }.filter { !$0.isEmpty })
        }
        var wdf: [String: Int] = [:]
        for s in wordSets { for w in s { wdf[w, default: 0] += 1 } }
        let entries = Double(max(bank.entries.count, 1))
        entryPhraseWords = phraseWords
        entryPhraseSets = phraseSets
        wordIDF = wdf.mapValues { log((entries + 1) / (Double($0) + 1)) + 1 }
        unknownWordIDF = log(entries + 1) + 1
        let n = Float(max(docNgrams.count, 1))
        var df: [UInt64: Int] = [:]
        for d in docNgrams { for k in d.keys { df[k, default: 0] += 1 } }
        var idf: [UInt64: Float] = [:]
        for (k, c) in df { idf[k] = Float(log((Double(n) + 1) / (Double(c) + 1))) + 1 }
        var postings: [UInt64: [Posting]] = [:]
        for (di, d) in docNgrams.enumerated() {
            var vec: [(UInt64, Float)] = []
            var norm: Float = 0
            for (k, tf) in d {
                let w = (1 + Float(log(Double(tf)))) * (idf[k] ?? 1)
                vec.append((k, w))
                norm += w * w
            }
            let inv = norm > 0 ? 1 / norm.squareRoot() : 0
            for (k, w) in vec { postings[k, default: []].append(Posting(doc: Int32(di), weight: w * inv)) }
        }
        self.entryIDs = entryIDs
        self.docEntry = docEntry
        self.postings = postings
        self.idf = idf
        self.unknownIDF = Float(log(Double(n) + 1)) + 1
    }

    public var isEmpty: Bool { postings.isEmpty }

    /// Lower-case, punctuation stripped, whitespace collapsed, padded with one space on each side.
    static func normalize(_ s: String) -> [UInt32] {
        var out: [UInt32] = [32]
        var lastSpace = true
        for u in s.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) {
                out.append(u.value)
                lastSpace = false
            } else if !lastSpace {
                out.append(32)
                lastSpace = true
            }
        }
        if !lastSpace { out.append(32) }
        else if out.count == 1 { return [] }
        return out
    }

    private static func ngramCounts(_ s: String) -> [UInt64: Int] {
        let a = normalize(s)
        var counts: [UInt64: Int] = [:]
        for n in ngramSizes where a.count >= n {
            for i in 0...(a.count - n) {
                // FNV-1a over the scalars, with the size mixed in so "ab" at n=3 and n=4 cannot collide systematically.
                var h: UInt64 = 0xcbf29ce484222325 ^ UInt64(n)
                for j in i..<(i + n) { h = (h ^ UInt64(a[j])) &* 0x100000001b3 }
                counts[h, default: 0] += 1
            }
        }
        return counts
    }

    /// The two best entries for `text`, best first (fewer when the bank is small). Scores are cosine similarities.
    public func top2(_ text: String) -> [Candidate] {
        let q = Self.ngramCounts(text)
        guard !q.isEmpty, !postings.isEmpty else { return [] }
        var qvec: [(UInt64, Float)] = []
        var norm: Float = 0
        for (k, tf) in q {
            let w = (1 + Float(log(Double(tf)))) * (idf[k] ?? unknownIDF)
            qvec.append((k, w))
            norm += w * w
        }
        guard norm > 0 else { return [] }
        let inv = 1 / norm.squareRoot()
        var docScore = [Float](repeating: 0, count: docEntry.count)
        for (k, w) in qvec {
            guard let plist = postings[k] else { continue }
            let qw = w * inv
            for p in plist { docScore[Int(p.doc)] += qw * p.weight }
        }
        var entryScore = [Float](repeating: 0, count: entryIDs.count)
        for (d, s) in docScore.enumerated() {
            let e = Int(docEntry[d])
            if s > entryScore[e] { entryScore[e] = s }
        }
        var best = -1, second = -1
        for (e, s) in entryScore.enumerated() where s > 0 {
            if best < 0 || s > entryScore[best] { second = best; best = e }
            else if second < 0 || s > entryScore[second] { second = e }
        }
        var out: [Candidate] = []
        if best >= 0 { out.append(Candidate(id: entryIDs[best], score: Double(entryScore[best]))) }
        if second >= 0 { out.append(Candidate(id: entryIDs[second], score: Double(entryScore[second]))) }
        return out
    }

    /// The best entry when it clears `threshold` and leads the runner-up by `margin`.
    public func match(_ text: String, threshold: Double, margin: Double) -> Candidate? {
        let top = top2(text)
        guard let first = top.first, first.score >= threshold else { return nil }
        if top.count > 1, first.score - top[1].score < margin { return nil }
        return first
    }

    // MARK: word-level check

    /// How well the words of `text` stand for entry `id` (0...1, the best of its phrases), the check behind a lexical
    /// `bank_hit` on top of the n-gram score.
    ///
    /// Character n-grams score shared spelling, not shared meaning, and two kinds of wrong cards came from that (replay
    /// f3-fresh, 2026-11-12): an off-bank question that shares a rare word or a phrase with an entry ("How would you measure
    /// success for the dispatcher pilot?" scored 0.66 on "How did you measure success on Lantern?"; "What did the courier
    /// pilot teach you ..." 0.61 on the courier pilot entry), and a short prefix that several entries begin with ("Can you
    /// tell me about" scored 0.68 on "... the Lantern project?" before "yourself" arrived). Here each content word (not a
    /// function word, three letters or more) weighs its entry-level IDF; a phrase word counts as heard when a query word
    /// equals it, is a prefix of it of four letters or more (a word still being spoken) or is within one edit (two from
    /// eight letters) of it (the recognizer's spelling: "optimizer", "adrift").
    ///
    /// coverage = weight of the phrase words heard / (weight of the phrase words up to the last one heard + weight of the
    /// query's words the bank knows but this phrase does not have). The phrase words after the last one heard are excused
    /// while the query ends there (a question still being spoken); once the query goes on past it with other content words,
    /// they count too (the speaker went somewhere else). A phrase with no content words is not judged (1).
    ///
    /// Unless the query covers the whole phrase (and brings no other word the bank knows), it is 0 when
    /// - it has heard fewer than two of the phrase's content words ("What did the courier");
    /// - it has heard no word of a name in the phrase (a capitalized word inside the sentence: "How would you measure success"
    ///   does not confirm "How did you measure success on Lantern?" until "Lantern" is heard), with two exceptions below;
    /// - every word it has heard is also in one phrase of another entry ("Can you tell me about" waits for "yourself" or
    ///   "Lantern"). Phrase by phrase, not the entry's words pooled: "What results did Lantern" is not ambiguous because
    ///   one paraphrase of b011 says "results" and another "Lantern".
    ///
    /// A missing name does not block the phrase
    /// - while the query reads the phrase word for word up to where it stopped (`readsVerbatim`: "Quanto era curata la
    ///   pipel" against "Quanto era accurata la pipeline di Lantern?"). The name is what tells two questions of the same
    ///   shape apart, but a question that is different from the prepared one has a different word somewhere before the name
    ///   ("How would you measure success" against "How did you measure success on Lantern?"). Italian puts the name last
    ///   more often than English; waiting for it cost every such card a recognizer burst (about one second, replay
    ///   fake-it-after: median card time +0.55 s after the question ended, against -0.40 s without the word check);
    /// - at the end of the turn (`turnEnded`) when every other content word of the phrase was heard, the turn holds no
    ///   content word the phrase does not have and it ends in a scrap of a lost word (`endsInLostWord`): the name was said but
    ///   destroyed ("Che risultati ha portato l'H", Lantern heard as "l'H", replay it03). A turn that simply stops before
    ///   the name ("How would you measure success?") is not taken for the prepared question.
    ///
    /// The engine sends the hit at the first event whose words confirm it (`TurnConfig.matchCoverage`, 0.6).
    public func coverage(_ text: String, id: String, turnEnded: Bool = false) -> Double {
        guard let e = entryIDs.firstIndex(of: id) else { return 0 }
        let phrases = entryPhraseWords[e].filter { !$0.words.isEmpty }
        guard !phrases.isEmpty else { return 1 }
        let q = Self.contentWords(text)
        guard !q.isEmpty else { return 0 }
        let tokens = Self.foldedWords(text)
        return phrases.map { phraseCoverage(q, tokens: tokens, $0, entry: e, turnEnded: turnEnded) }.max() ?? 0
    }

    private func phraseCoverage(_ q: [String], tokens: [String], _ phrase: PhraseWords, entry e: Int, turnEnded: Bool) -> Double {
        let p = phrase.words
        var pHeard = [Bool](repeating: false, count: p.count)
        var qUsed = [Bool](repeating: false, count: q.count)
        for (j, pw) in p.enumerated() {
            for (i, qw) in q.enumerated() where Self.wordsMatch(qw, pw) {
                pHeard[j] = true
                qUsed[i] = true
            }
        }
        guard let lastP = pHeard.lastIndex(of: true), let lastQ = qUsed.lastIndex(of: true) else { return 0 }
        let whole = !pHeard.contains(false) && !q.indices.contains { !qUsed[$0] && wordIDF[q[$0]] != nil }
        if !whole {
            // One word is not enough to tell where a question goes ("What did the courier ..."), unless it is all the
            // phrase has.
            if pHeard.filter({ $0 }).count < min(2, p.count) { return 0 }
            // A name in the phrase (a capitalized word inside a sentence: "Lantern", "Halden Freight Systems") is what tells
            // two questions of the same shape apart ("How did you measure success on Lantern?" against "... for the
            // dispatcher pilot?"): at least one word of every name must be heard, unless the query reads the phrase word for
            // word, or the turn is over with the name lost and nothing else said (see `coverage`).
            let missingName = phrase.names.contains { group in !group.contains(where: { pHeard[$0] }) }
            if missingName, !Self.readsVerbatim(tokens, phrase.tokens) {
                let nameWords = Set(phrase.names.joined())
                let restHeard = p.indices.allSatisfy { nameWords.contains($0) || pHeard[$0] }
                guard turnEnded, restHeard, !qUsed.contains(false), Self.endsInLostWord(tokens) else { return 0 }
            }
        }
        let queryGoesOn = lastQ + 1 < q.count
        let upTo = queryGoesOn ? p.count - 1 : lastP
        var heard = 0.0, total = 0.0
        for j in 0...upTo {
            let w = wordIDF[p[j]] ?? unknownWordIDF
            total += w
            if pHeard[j] { heard += w }
        }
        for (i, qw) in q.enumerated() where !qUsed[i] { total += wordIDF[qw] ?? 0 }
        guard total > 0 else { return 0 }
        if !whole {
            let heardWords = p.indices.filter { pHeard[$0] }.map { p[$0] }
            for (k, sets) in entryPhraseSets.enumerated() where k != e {
                for words in sets where heardWords.allSatisfy({ hw in words.contains(hw) || words.contains { Self.wordsMatch($0, hw) } }) {
                    return 0
                }
            }
        }
        return heard / total
    }

    /// True when the query, from its start (or after one or two leading words that carry no content: "you Puoi parlarmi
    /// ..."), is the phrase's beginning token by token, function words included, over at least four tokens: a content word as
    /// `wordsMatch` hears it ("curata" for "accurata"), any other token exactly, and the query's last token may be the first
    /// letters of the phrase token it stands at (the word being spoken: "Why do you want to join H").
    static func readsVerbatim(_ q: [String], _ p: [String]) -> Bool {
        guard q.count >= 4 else { return false }
        for lead in 0...min(2, q.count - 4) {
            if q[0..<lead].contains(where: isContent) { break }
            let n = q.count - lead
            guard n <= p.count else { continue }
            var ok = true
            for j in 0..<n {
                let a = q[lead + j], b = p[j]
                if a == b { continue }
                if isContent(a) || isContent(b), wordsMatch(a, b) { continue }
                if j == n - 1, b.hasPrefix(a) { continue }
                ok = false
                break
            }
            if ok { return true }
        }
        return false
    }

    /// True when the query ends, after its last content word, in a scrap that is neither a content word nor a function word:
    /// what the recognizer leaves of a word it lost ("Che risultati ha portato l'H": "h"). "How would you measure success"
    /// and "... success for the" end in no such scrap.
    static func endsInLostWord(_ tokens: [String]) -> Bool {
        let tail = tokens.reversed().prefix { !isContent($0) }
        return tail.contains { !functionWords.contains($0) }
    }

    private static func isContent(_ w: String) -> Bool {
        (w.count >= 3 || w.contains(where: \.isNumber)) && !functionWords.contains(w)
    }

    /// The content words of one phrase in order, and which of them form names (`coverage`).
    struct PhraseWords: Sendable {
        var words: [String] = []
        /// Index groups into `words`: runs of capitalized words inside a sentence ("Halden Freight Systems"). Acronyms
        /// ("LLM", "ETA") are not names here: the recognizer rarely spells them back ("Elm", "eat").
        var names: [[Int]] = []
        /// Every word of the phrase, function words included, as `foldedWords` splits them (`readsVerbatim`).
        var tokens: [String] = []

        init(_ phrase: String) {
            tokens = BankMatcher.foldedWords(phrase)
            var raw: [(text: String, sentenceStart: Bool)] = []
            var cur = ""
            var pendingStart = true
            var curStart = true
            for ch in phrase {
                if ch.isLetter || ch.isNumber {
                    if cur.isEmpty { curStart = pendingStart; pendingStart = false }
                    cur.append(ch)
                } else {
                    if !cur.isEmpty { raw.append((cur, curStart)); cur = "" }
                    if ".?!".contains(ch) { pendingStart = true }
                }
            }
            if !cur.isEmpty { raw.append((cur, curStart)) }
            var group: [Int] = []
            for r in raw {
                let folded = Text.fold(r.text).lowercased()
                let isContent = BankMatcher.isContent(folded)
                let isName = !r.sentenceStart && (r.text.first?.isUppercase ?? false) && r.text.dropFirst().contains(where: \.isLowercase)
                if isContent {
                    if isName { group.append(words.count) } else if !group.isEmpty { names.append(group); group = [] }
                    words.append(folded)
                } else if !group.isEmpty, !isName {
                    names.append(group)
                    group = []
                }
            }
            if !group.isEmpty { names.append(group) }
        }
    }

    /// Words that carry no topic: the cue lists' function words of the three languages, plus the commonest question and
    /// auxiliary words of Italian and Turkish (they are in many prepared questions and say nothing about which one).
    static let functionWords: Set<String> = {
        var s = Cues.functionWords(lang: "en").union(Cues.functionWords(lang: "it")).union(Cues.functionWords(lang: "tr"))
        s.formUnion(["che", "chi", "cosa", "come", "quale", "qual", "quali", "quando", "dove", "perche", "quanto", "quanta", "quanti",
                     "quante", "puoi", "puo", "potresti", "potrebbe", "hai", "sei", "stato", "stata", "stati", "tuo", "tua", "tuoi",
                     "tue", "suo", "sua", "nostro", "nostra", "vostro", "vostra", "non", "piu", "questo", "questa", "quello", "quella",
                     "sono", "era", "del", "al", "alla", "allo", "dal", "dalla", "sul", "sulla", "nello", "degli",
                     "bir", "bu", "su", "ne", "nasil", "neden", "hangi", "icin", "sen", "siz", "ben", "biz", "senin", "sizin", "bana",
                     "bize", "mi", "mu", "misiniz", "misin", "musunuz"])
        return Set(s.map { Text.fold($0) })
    }()

    /// Folded, lower-cased words of `s`, apostrophes split ("dell'impatto" is "dell" "impatto").
    static func foldedWords(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in Text.fold(s).lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// `foldedWords` without function words and without words shorter than three letters (unless they hold a digit).
    static func contentWords(_ s: String) -> [String] {
        foldedWords(s).filter(isContent)
    }

    /// Same word as the recognizer may write it: equal, a prefix of four letters or more, or within one edit (two from
    /// eight letters).
    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        if s.count >= 4, l.hasPrefix(s) { return true }
        let maxD = l.count >= 8 ? 2 : (l.count >= 5 ? 1 : 0)
        guard maxD > 0, l.count - s.count <= maxD else { return false }
        return charDistance(Array(a), Array(b), limit: maxD) <= maxD
    }

    /// Character Levenshtein distance, stopping early once every path is past `limit`.
    static func charDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1]
            var rowMin = i + 1
            for (j, y) in b.enumerated() {
                let v = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1))
                cur.append(v)
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return rowMin }
            prev = cur
        }
        return prev[b.count]
    }
}
