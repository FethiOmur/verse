import Foundation

struct QuestionMetrics: Codable, Sendable {
    let index: Int
    let voice: String
    let script: String
    let finalText: String
    let acousticEndSec: Double
    let refWords: Int
    let wordsSeenInVolatile: Int       // words whose first correct appearance preceded their final
    let wordsMatched: Int              // words found at the same index in some hypothesis
    let wordLagsSec: [Double]          // strict: same word at the same index of the hypothesis
    let wordLagsLooseSec: [Double]     // loose: word (count-aware) present anywhere in the hypothesis
    let lastWordLagLooseSec: Double?
    let lastWordLagSec: Double?        // first correct appearance of the last word - acoustic end
    let lastWordFromVolatile: Bool
    let firstFinalLagSec: Double?      // arrival of first final covering this question - acoustic end
    let finalLagSec: Double?           // arrival of the last final (completes the text) - acoustic end
    let finalAfterFeedEnd: Bool        // final only arrived when the stream was flushed
    let werEdits: Int
    let qMarkInFinal: Bool
    let qMarkVolatileRelSec: Double?   // first '?' in any hypothesis (volatile or final) - acoustic end
    let qMarkFromVolatile: Bool
}

struct Stat: Codable, Sendable {
    let n: Int
    let p50: Double?
    let p90: Double?
    let min: Double?
    let max: Double?
}

struct RunSummary: Codable, Sendable {
    let questions: Int
    let refWordsTotal: Int
    let wordLag: Stat                  // strict
    let wordLagLoose: Stat
    let lastWordLagLoose: Stat
    let lastWordLag: Stat
    let firstFinalLag: Stat
    let finalLag: Stat
    let wer: Double
    let volatileCoverage: Double       // share of words seen in volatile before their final
    let qMarkInFinalShare: Double
    let qMarkInVolatileShare: Double
    let qMarkRelBeforeEndShare: Double // '?' visible at or before the acoustic end
    let qMarkRel: Stat
    let finalsAfterFeedEnd: Int
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    if s.count == 1 { return s[0] }
    let pos = p * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

func stat(_ xs: [Double]) -> Stat {
    Stat(n: xs.count, p50: percentile(xs, 0.5), p90: percentile(xs, 0.9), min: xs.min(), max: xs.max())
}

enum Analyze {
    static func tokens(_ s: String, localeID: String) -> [String] {
        let lowered = s.lowercased(with: Locale(identifier: localeID)).precomposedStringWithCanonicalMapping
        var out: [String] = []
        var cur = ""
        for ch in lowered.unicodeScalars {
            if CharacterSet.letters.contains(ch) || CharacterSet.decimalDigits.contains(ch) || CharacterSet.nonBaseCharacters.contains(ch) {
                cur.unicodeScalars.append(ch)
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Question windows on the stream clock: from 1.25 s before the file starts to 1.25 s before the next file.
    static func windows(_ utts: [Utterance]) -> [(Double, Double)] {
        utts.enumerated().map { i, u in
            let lo = i == 0 ? -Double.infinity : u.placedAtSec - 1.25
            let hi = i + 1 < utts.count ? utts[i + 1].placedAtSec - 1.25 : Double.infinity
            return (lo, hi)
        }
    }

    /// Words (tokens) of an event whose run midpoint lies in the window, with run end times and raw run text.
    static func windowRuns(_ e: Event, _ w: (Double, Double), localeID: String) -> [(tok: String, end: Double, raw: String)] {
        var out: [(String, Double, String)] = []
        for r in e.runs {
            let mid = (r.start + r.end) / 2
            guard mid >= w.0 && mid < w.1 else { continue }
            for tk in tokens(r.text, localeID: localeID) { out.append((tk, r.end, r.text)) }
            if tokens(r.text, localeID: localeID).isEmpty { out.append(("", r.end, r.text)) }  // bare punctuation run
        }
        return out.map { (tok: $0.0, end: $0.1, raw: $0.2) }
    }

    static func questionMetrics(utt: Utterance, window w: (Double, Double), events: [Event], localeID: String, feedEnd: Double) -> QuestionMetrics {
        // Reference = the finalized words in this window, each with its end time from the result's audio time range.
        var ref: [(tok: String, end: Double, finalT: Double)] = []
        var finalRaw = ""
        var finalArrivals: [Double] = []
        for e in events where e.isFinal {
            let wr = windowRuns(e, w, localeID: localeID)
            if wr.isEmpty { continue }
            finalArrivals.append(e.t)
            finalRaw += wr.map { $0.raw }.joined()
            for r in wr where !r.tok.isEmpty { ref.append((r.tok, r.end, e.t)) }
        }
        // Replay the hypothesis (finalized words + latest volatile words) in arrival order.
        var firstSeen = [Double?](repeating: nil, count: ref.count)
        var firstSeenLoose = [Double?](repeating: nil, count: ref.count)
        var occ: [Int] = []
        var seenCount: [String: Int] = [:]
        for r in ref { seenCount[r.tok, default: 0] += 1; occ.append(seenCount[r.tok]!) }
        var finalToks: [String] = []
        var volToks: [String] = []
        var finalRawLive = ""
        var volRawLive = ""
        var qFirstT: Double?
        var qFromVolatile = false
        for e in events {
            let overlaps = e.end > w.0 && e.start < w.1
            guard overlaps else { continue }
            let wr = windowRuns(e, w, localeID: localeID)
            if e.isFinal {
                finalToks += wr.map { $0.tok }.filter { !$0.isEmpty }
                finalRawLive += wr.map { $0.raw }.joined()
                volToks = []; volRawLive = ""
            } else {
                volToks = wr.map { $0.tok }.filter { !$0.isEmpty }
                volRawLive = wr.map { $0.raw }.joined()
            }
            let hyp = finalToks + volToks
            for k in 0..<min(hyp.count, ref.count) where firstSeen[k] == nil && hyp[k] == ref[k].tok {
                firstSeen[k] = e.t
            }
            var hc: [String: Int] = [:]
            for tk in hyp { hc[tk, default: 0] += 1 }
            for k in 0..<ref.count where firstSeenLoose[k] == nil && (hc[ref[k].tok] ?? 0) >= occ[k] {
                firstSeenLoose[k] = e.t
            }
            if qFirstT == nil, (finalRawLive + volRawLive).contains("?") {
                qFirstT = e.t
                qFromVolatile = !e.isFinal
            }
        }
        var lags: [Double] = []
        var seenVol = 0
        for (k, r) in ref.enumerated() {
            guard let t = firstSeen[k] else { continue }
            lags.append(t - r.end)
            if t < r.finalT - 0.001 { seenVol += 1 }
        }
        var lagsLoose: [Double] = []
        for (k, r) in ref.enumerated() { if let t = firstSeenLoose[k] { lagsLoose.append(t - r.end) } }
        let lastWLoose = ref.indices.last.flatMap { firstSeenLoose[$0] }
        let lastW = ref.indices.last.flatMap { firstSeen[$0] }
        let lastFromVol = ref.indices.last.map { k in firstSeen[k].map { $0 < ref[k].finalT - 0.001 } ?? false } ?? false
        let scriptToks = tokens(utt.text, localeID: localeID)
        let hypToks = ref.map { $0.tok }
        return QuestionMetrics(
            index: utt.index, voice: utt.voice, script: utt.text, finalText: finalRaw.trimmingCharacters(in: .whitespaces),
            acousticEndSec: utt.speechEndSec, refWords: ref.count,
            wordsSeenInVolatile: seenVol, wordsMatched: lags.count, wordLagsSec: lags, wordLagsLooseSec: lagsLoose,
            lastWordLagLooseSec: lastWLoose.map { $0 - utt.speechEndSec },
            lastWordLagSec: lastW.map { $0 - utt.speechEndSec },
            lastWordFromVolatile: lastFromVol,
            firstFinalLagSec: finalArrivals.first.map { $0 - utt.speechEndSec },
            finalLagSec: finalArrivals.last.map { $0 - utt.speechEndSec },
            finalAfterFeedEnd: (finalArrivals.last ?? 0) > feedEnd,
            werEdits: editDistance(scriptToks, hypToks),
            qMarkInFinal: finalRaw.contains("?"),
            qMarkVolatileRelSec: qFirstT.map { $0 - utt.speechEndSec },
            qMarkFromVolatile: qFromVolatile)
    }

    /// Corpus WER over the whole stream: all finalized words in arrival order vs. all script words.
    static func globalWER(events: [Event], utts: [Utterance], localeID: String) -> (edits: Int, refWords: Int, hypWords: Int) {
        let script = utts.flatMap { tokens($0.text, localeID: localeID) }
        let hyp = events.filter { $0.isFinal }.flatMap { $0.runs.flatMap { tokens($0.text, localeID: localeID) } }
        return (editDistance(script, hyp), script.count, hyp.count)
    }

    static func summarize(_ qs: [QuestionMetrics], wer: (edits: Int, refWords: Int, hypWords: Int)) -> RunSummary {
        let words = qs.flatMap { $0.wordLagsSec }
        let totalRef = qs.reduce(0) { $0 + $1.refWords }
        let seen = qs.reduce(0) { $0 + $1.wordsSeenInVolatile }
        let qm = qs.compactMap { $0.qMarkVolatileRelSec }
        let n = Double(max(qs.count, 1))
        return RunSummary(
            questions: qs.count, refWordsTotal: totalRef,
            wordLag: stat(words),
            wordLagLoose: stat(qs.flatMap { $0.wordLagsLooseSec }),
            lastWordLagLoose: stat(qs.compactMap { $0.lastWordLagLooseSec }),
            lastWordLag: stat(qs.compactMap { $0.lastWordLagSec }),
            firstFinalLag: stat(qs.compactMap { $0.firstFinalLagSec }),
            finalLag: stat(qs.compactMap { $0.finalLagSec }),
            wer: wer.refWords > 0 ? Double(wer.edits) / Double(wer.refWords) : 0,
            volatileCoverage: totalRef > 0 ? Double(seen) / Double(totalRef) : 0,
            qMarkInFinalShare: Double(qs.filter { $0.qMarkInFinal }.count) / n,
            qMarkInVolatileShare: Double(qs.filter { $0.qMarkFromVolatile }.count) / n,
            qMarkRelBeforeEndShare: Double(qm.filter { $0 <= 0 }.count) / n,
            qMarkRel: stat(qm),
            finalsAfterFeedEnd: qs.filter { $0.finalAfterFeedEnd }.count)
    }
}
