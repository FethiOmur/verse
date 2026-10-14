import Foundation

/// One prepared question from `bank.jsonl` (the fields the matcher needs; the rest is the brain's business).
public struct BankEntry: Sendable, Equatable {
    public var id: String
    public var lang: String
    public var question: String
    public var paraphrases: [String: [String]]

    public init(id: String, lang: String = "en", question: String, paraphrases: [String: [String]] = [:]) {
        self.id = id
        self.lang = lang
        self.question = question
        self.paraphrases = paraphrases
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
            entries.append(BankEntry(id: id, lang: obj["lang"] as? String ?? "en", question: q, paraphrases: para))
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

    public init(bank: Bank, lang: String) {
        var entryIDs: [String] = []
        var docNgrams: [[UInt64: Int]] = []
        var docEntry: [Int32] = []
        for (ei, entry) in bank.entries.enumerated() {
            entryIDs.append(entry.id)
            for phrase in entry.phrases(for: lang) {
                let counts = Self.ngramCounts(phrase)
                if counts.isEmpty { continue }
                docNgrams.append(counts)
                docEntry.append(Int32(ei))
            }
        }
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
}
