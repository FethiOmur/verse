import Foundation

// The Sessions page's transcript (spec 2.1): rows, timestamps, speakers and the cards that fired at that moment, built from the
// session folder's `transcript.jsonl` and `events.jsonl`. This is the single source of truth for rows and stamps; Ask (F2b)
// receives its rows from here and never recomputes them. Pure Foundation: no view code, nothing is written.

// MARK: - Model

/// Who a row belongs to. `me` is the owner, `other` the remote side, `room` a voice on the one mic that could be either.
enum TranscriptSpeaker: String, Sendable, Equatable {
    case me, other, room
}

/// The card Verse showed for a turn: the tiers that wrote it ("F", "D"), the last SAY line and every point line.
struct TranscriptCard: Equatable, Sendable {
    var tiers: [String]
    var say: String?
    var points: [String]

    /// "F · D".
    var tierLabel: String { tiers.joined(separator: " · ") }
}

struct TranscriptRow: Identifiable, Equatable, Sendable {
    /// Unique inside the document: run, position, and `a`/`b` for the two halves of a split room row.
    var id: String
    var turnID: String
    /// 0-based run (one start of the session's recording).
    var run: Int
    /// Seconds since the first run started.
    var elapsed: Double
    /// Unix seconds when known (forward files, or legacy files with aligned starts).
    var wall: Double?
    var speaker: TranscriptSpeaker
    var text: String
    var card: TranscriptCard?

    var stamp: String { TranscriptDocument.stamp(elapsed) }
}

/// One line of `transcript.jsonl`.
struct TranscriptLine: Equatable, Sendable {
    var turnID: String
    var speaker: String
    var text: String
    var tAudioEnd: Double
    var runStart: Double?
    var tWall: Double?
}

/// One line of `events.jsonl`, with the fields the transcript reads. Unknown keys and events are ignored.
struct SessionEvent: Equatable, Sendable {
    var t: Double
    var ev: String
    var turn: String?
    var tier: String?
    var id: String?
    var kind: String?
    var text: String?
    var say: String?
    var points: [String] = []
    var final: Bool?
    var label: String?
    var meWords: Int?
}

// MARK: - Document

struct TranscriptDocument: Equatable, Sendable {
    var rows: [TranscriptRow]
    var ownerName: String
    /// `events.jsonl` exists and has at least one line.
    var hasEvents: Bool
    var runCount: Int

    /// At least one row carries a card (the Cards toggle is shown only then).
    var hasCards: Bool { rows.contains { $0.card != nil } }
    var isEmpty: Bool { rows.isEmpty }

    static let empty = TranscriptDocument(lines: [], events: [], ownerName: "Alex")

    // MARK: Loading

    /// Reads `transcript.jsonl` and `events.jsonl` of a session folder; a missing or unreadable file is an empty list.
    static func load(sessionDir: URL, ownerName: String) -> TranscriptDocument {
        let lines = readTranscript(sessionDir.appendingPathComponent("transcript.jsonl"))
        let events = readEvents(sessionDir.appendingPathComponent("events.jsonl"))
        return TranscriptDocument(lines: lines, events: events, ownerName: ownerName)
    }

    static func readTranscript(_ url: URL) -> [TranscriptLine] {
        objects(in: url).compactMap { o in
            guard let id = o["turn_id"] as? String, let text = o["text"] as? String else { return nil }
            return TranscriptLine(turnID: id, speaker: (o["speaker"] as? String) ?? "remote",
                                  text: text.trimmingCharacters(in: .whitespacesAndNewlines), tAudioEnd: number(o["t_audio_end"]) ?? 0,
                                  runStart: number(o["run_start"]), tWall: number(o["t_wall"]))
        }.filter { !$0.text.isEmpty }
    }

    static func readEvents(_ url: URL) -> [SessionEvent] {
        objects(in: url).compactMap { o in
            guard let ev = o["ev"] as? String, let t = number(o["t"]) else { return nil }
            var e = SessionEvent(t: t, ev: ev)
            e.turn = o["turn"] as? String
            e.tier = o["tier"] as? String
            e.id = o["id"] as? String
            e.kind = o["kind"] as? String
            e.text = o["text"] as? String
            e.say = o["say"] as? String
            e.points = (o["points"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let f = o["final"] as? Bool { e.final = f }
            e.label = o["label"] as? String
            if let n = number(o["me_words"]) { e.meWords = Int(n) }
            return e
        }
    }

    private static func objects(in url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    // MARK: Building

    /// A recording of the session between one start and its end. `wallStart` is known for forward runs and aligned legacy runs.
    private struct Run {
        var lines: [TranscriptLine]
        var forwardStart: Double?
        var wallStart: Double?
    }

    init(lines: [TranscriptLine], events: [SessionEvent], ownerName: String) {
        self.ownerName = ownerName
        self.hasEvents = !events.isEmpty
        var runs = Self.segment(lines)
        Self.alignStarts(&runs, events: events)
        let allWall = !runs.isEmpty && runs.allSatisfy { $0.wallStart != nil }
        let base = allWall ? runs.compactMap(\.wallStart).min() ?? 0 : 0

        var rows: [TranscriptRow] = []
        var cumulative = 0.0          // cumulative placement: where the next run begins
        var previousEnd = 0.0         // elapsed of the last row so far: stamps never go backwards between runs
        for (k, run) in runs.enumerated() {
            let ordered = Self.dedup(run.lines).enumerated().sorted {
                ($0.element.tAudioEnd, $0.offset) < ($1.element.tAudioEnd, $1.offset)
            }.map(\.element)
            let startElapsed = max(allWall ? (run.wallStart ?? 0) - base : cumulative, previousEnd)
            for (n, line) in ordered.enumerated() {
                let elapsed = startElapsed + line.tAudioEnd
                rows.append(TranscriptRow(id: "r\(k).\(n)", turnID: line.turnID, run: k, elapsed: elapsed,
                                          wall: allWall ? (line.tWall ?? run.wallStart.map { $0 + line.tAudioEnd }) : nil,
                                          speaker: Self.speaker(line.speaker), text: line.text, card: nil))
            }
            let end = ordered.map(\.tAudioEnd).max() ?? 0
            cumulative = startElapsed + end
            previousEnd = max(previousEnd, rows.last?.elapsed ?? previousEnd)
        }
        runCount = runs.count
        rows = Self.relabelRoom(rows, events: events, wallKnown: allWall)
        if allWall { Self.attachCards(&rows, events: events) }
        self.rows = rows
    }

    private static func speaker(_ s: String) -> TranscriptSpeaker {
        switch s {
        case "me": .me
        case "room": .room
        default: .other
        }
    }

    // MARK: Runs

    /// Forward lines (they carry `run_start`) group by it. Legacy lines have no run marker: a run ends when a turn id repeats inside
    /// it or `t_audio_end` drops more than 30 s below the run's maximum.
    private static func segment(_ lines: [TranscriptLine]) -> [Run] {
        var runs: [Run] = []
        var seen = Set<String>()
        var maxEnd = 0.0
        for line in lines {
            if let rs = line.runStart {
                let key = (rs * 1000).rounded()
                if let last = runs.last, let f = last.forwardStart, (f * 1000).rounded() == key {
                    runs[runs.count - 1].lines.append(line)
                } else {
                    runs.append(Run(lines: [line], forwardStart: rs, wallStart: rs))
                }
                seen = []
                continue
            }
            let startsNew: Bool
            if let last = runs.last, last.forwardStart == nil {
                startsNew = seen.contains(line.turnID) || line.tAudioEnd < maxEnd - 30
            } else {
                startsNew = true
            }
            if startsNew {
                runs.append(Run(lines: [line], forwardStart: nil, wallStart: nil))
                seen = [line.turnID]
                maxEnd = line.tAudioEnd
            } else {
                runs[runs.count - 1].lines.append(line)
                seen.insert(line.turnID)
                maxEnd = max(maxEnd, line.tAudioEnd)
            }
        }
        return runs
    }

    /// Legacy runs are aligned to the last N `start` events (early starts without speech have no lines). Forward runs already know
    /// their start. Without enough starts a legacy run keeps `wallStart == nil` and the document places its runs one after another.
    private static func alignStarts(_ runs: inout [Run], events: [SessionEvent]) {
        let legacy = runs.indices.filter { runs[$0].forwardStart == nil }
        guard !legacy.isEmpty else { return }
        // Legacy runs come before forward ones; a legacy run after a forward one cannot be placed.
        if let firstForward = runs.firstIndex(where: { $0.forwardStart != nil }), legacy.contains(where: { $0 > firstForward }) { return }
        var starts = events.filter { $0.ev == "start" }.map(\.t).sorted()
        if let first = runs.compactMap(\.forwardStart).min() { starts = starts.filter { $0 < first - 30 } }
        guard starts.count >= legacy.count else { return }
        let aligned = Array(starts.suffix(legacy.count))
        for (j, i) in legacy.enumerated() { runs[i].wallStart = aligned[j] }
    }

    /// Inside a run the later text of a repeated turn id replaces the earlier one in the earlier one's position.
    private static func dedup(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var at: [String: Int] = [:]
        for line in lines {
            if let i = at[line.turnID] {
                out[i].text = line.text
            } else {
                at[line.turnID] = out.count
                out.append(line)
            }
        }
        return out
    }

    // MARK: Room rows

    /// A `room` row is Alex reading his card when the brain relabelled it (`room_text` final): `me`, or `split` with `me_words`
    /// leading words that are his and a remainder that stays room. A legacy split (no `me_words`) stays one room row.
    private static func relabelRoom(_ rows: [TranscriptRow], events: [SessionEvent], wallKnown: Bool) -> [TranscriptRow] {
        let finals = events.enumerated().filter { $0.element.ev == "room_text" && $0.element.final == true && $0.element.turn != nil }
        guard !finals.isEmpty, rows.contains(where: { $0.speaker == .room }) else { return rows }
        var byTurn: [String: [(idx: Int, ev: SessionEvent)]] = [:]
        for f in finals { byTurn[f.element.turn!, default: []].append((f.offset, f.element)) }
        for key in byTurn.keys { byTurn[key]!.sort { $0.ev.t < $1.ev.t } }
        let roomCounts = Dictionary(grouping: rows.filter { $0.speaker == .room }, by: \.turnID).mapValues(\.count)

        var used = Set<Int>()
        var ordinal: [String: Int] = [:]
        var out: [TranscriptRow] = []
        for row in rows {
            guard row.speaker == .room, let cands = byTurn[row.turnID] else { out.append(row); continue }
            var chosen: SessionEvent?
            if wallKnown, let wall = row.wall {
                let best = cands.filter { !used.contains($0.idx) }.min { abs($0.ev.t - wall) < abs($1.ev.t - wall) }
                if let best, abs(best.ev.t - wall) <= 30 { used.insert(best.idx); chosen = best.ev }
            } else {
                let k = ordinal[row.turnID, default: 0]
                ordinal[row.turnID] = k + 1
                if roomCounts[row.turnID] == cands.count { chosen = cands[k].ev }
            }
            guard let ev = chosen else { out.append(row); continue }
            switch ev.label {
            case "me":
                var r = row
                r.speaker = .me
                out.append(r)
            case "split":
                guard let n = ev.meWords, n > 0, let cut = indexAfterWords(n, in: row.text) else { out.append(row); continue }
                let mine = row.text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = row.text[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
                var a = row
                a.speaker = .me
                a.text = mine
                if rest.isEmpty {
                    out.append(a)
                } else {
                    a.id = row.id + "a"
                    var b = row
                    b.id = row.id + "b"
                    b.text = rest
                    out.append(a)
                    out.append(b)
                }
            default:
                out.append(row)
            }
        }
        return out
    }

    /// The index where the (n+1)-th whitespace-separated word starts, or the end when the text has n words or fewer.
    static func indexAfterWords(_ n: Int, in text: String) -> String.Index? {
        var words = 0
        var inWord = false
        var i = text.startIndex
        while i < text.endIndex {
            let isSpace = text[i].isWhitespace
            if !isSpace, !inWord {
                words += 1
                if words == n + 1 { return i }
            }
            inWord = !isSpace
            i = text.index(after: i)
        }
        return text.endIndex
    }

    // MARK: Cards

    private struct CardRecord {
        var t: Double
        var turn: String
        var tier: String
        var say: String?
        var points: [String]
    }

    /// One card per turn, under the row it answered. `card_done` carries the whole card; an older log only has `card` (the first
    /// line of each call, 60 characters). A card whose turn has no row (`now-<n>`, follow cards) goes under the last row whose
    /// wall time is not after the card.
    private static func attachCards(_ rows: inout [TranscriptRow], events: [SessionEvent]) {
        let doneIDs = Set(events.filter { $0.ev == "card_done" }.compactMap(\.id))
        var records: [CardRecord] = []
        for e in events {
            guard let turn = e.turn else { continue }
            let tier = e.tier ?? "F"
            if e.ev == "card_done" {
                guard e.say != nil || !e.points.isEmpty else { continue }
                records.append(CardRecord(t: e.t, turn: turn, tier: tier, say: e.say, points: e.points))
            } else if e.ev == "card", !(e.id.map(doneIDs.contains) ?? false), let text = e.text, !text.isEmpty {
                records.append(CardRecord(t: e.t, turn: turn, tier: tier, say: e.kind == "point" ? nil : text,
                                          points: e.kind == "point" ? [text] : []))
            }
        }
        var perRow: [Int: [CardRecord]] = [:]
        for rec in records.sorted(by: { $0.t < $1.t }) {
            if let i = target(for: rec, in: rows) { perRow[i, default: []].append(rec) }
        }
        for (i, recs) in perRow {
            var card = TranscriptCard(tiers: [], say: nil, points: [])
            for r in recs {
                if !card.tiers.contains(r.tier) { card.tiers.append(r.tier) }
                if let s = r.say { card.say = s }
                for p in r.points where !card.points.contains(p) { card.points.append(p) }
            }
            rows[i].card = card
        }
    }

    private static func target(for rec: CardRecord, in rows: [TranscriptRow]) -> Int? {
        let same = rows.indices.filter { rows[$0].turnID == rec.turn }
        if same.count == 1 { return same[0] }
        if same.count > 1 {
            // The same id comes back in every run: the row nearest in wall time; a tie (the two halves of a split) takes the later.
            var best = same[0]
            var bestGap = Double.infinity
            for i in same {
                let gap = abs((rows[i].wall ?? rec.t) - rec.t)
                if gap <= bestGap { best = i; bestGap = gap }
            }
            return best
        }
        return rows.indices.last { (rows[$0].wall ?? .infinity) <= rec.t }
    }

    // MARK: Stamps

    /// "m:ss" under an hour, "h:mm:ss" from an hour; whole seconds, rounded down.
    static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Names and blocks

    func name(of speaker: TranscriptSpeaker) -> String {
        switch speaker {
        case .me: ownerName
        case .other: L10n.tr("Other")
        case .room: L10n.tr("Room")
        }
    }

    /// A block is consecutive rows of one speaker less than 60 s apart (indices into `rows`).
    var blocks: [[Int]] {
        var out: [[Int]] = []
        for i in rows.indices {
            if let last = out.last?.last, rows[last].speaker == rows[i].speaker, rows[i].elapsed - rows[last].elapsed < 60 {
                out[out.count - 1].append(i)
            } else {
                out.append([i])
            }
        }
        return out
    }

    /// The first row stamped `stamp` ("12:34"): where an Ask citation jumps to.
    func row(forStamp stamp: String) -> TranscriptRow? { rows.first { $0.stamp == stamp } }

    /// The rows as Ask receives them (spec 3.2): stamp, speaker name, text.
    var askRows: [(stamp: String, speaker: String, text: String)] {
        rows.map { ($0.stamp, name(of: $0.speaker), $0.text) }
    }

    // MARK: Export

    /// `[m:ss] Name: text` per row, without cards.
    func plainText() -> String {
        rows.map { "[\($0.stamp)] \(name(of: $0.speaker)): \($0.text)\n" }.joined()
    }

    /// `# title`, the meta line, then `**m:ss Name:** text` paragraphs; with `includeCards` each card follows its row as
    /// `> Card (F · D): SAY` and `> - point` lines.
    func markdown(title: String, meta: String, includeCards: Bool) -> String {
        var out = "# \(title)\n\n\(meta)\n"
        for row in rows {
            out += "\n**\(row.stamp) \(name(of: row.speaker)):** \(row.text)\n"
            guard includeCards, let card = row.card else { continue }
            out += "\n> \(L10n.tr("Card")) (\(card.tierLabel))"
            if let say = card.say { out += ": \(say)" }
            out += "\n"
            for p in card.points { out += "> - \(p)\n" }
        }
        return out
    }

    /// "20 Oct 2026 · Phone · 12 turns".
    static func metaLine(date: Date, kind: String, turns: Int, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let day = date.formatted(Date.FormatStyle(timeZone: timeZone).locale(L10n.formatLocale).day().month(.abbreviated).year())
        return [day, kind, L10n.tr("\(turns) turns")].joined(separator: " · ")
    }
}

// MARK: - Search

/// One hit: a row, and the range of Characters in its text (nil when the speaker's name matched).
struct TranscriptMatch: Equatable, Sendable {
    var row: Int
    var range: Range<Int>?
}

enum TranscriptSearch {
    /// Case- and accent-insensitive with Turkish folding (`TextFold.fold`). Searches row text and speaker names; rows keep their
    /// order, a name hit comes before the hits in the text.
    static func matches(in doc: TranscriptDocument, query: String) -> [TranscriptMatch] {
        let q = Array(TextFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !q.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        for (i, row) in doc.rows.enumerated() {
            if contains(Array(TextFold.fold(doc.name(of: row.speaker))), q) { out.append(TranscriptMatch(row: i, range: nil)) }
            let (chars, origin) = folded(row.text)
            var s = 0
            while s + q.count <= chars.count {
                if Array(chars[s ..< s + q.count]) == q {
                    out.append(TranscriptMatch(row: i, range: origin[s] ..< origin[s + q.count - 1] + 1))
                    s += q.count
                } else {
                    s += 1
                }
            }
        }
        return out
    }

    /// The folded Characters of `s`, each with the offset of the original Character it came from.
    private static func folded(_ s: String) -> (chars: [Character], origin: [Int]) {
        var chars: [Character] = []
        var origin: [Int] = []
        for (i, ch) in s.enumerated() {
            for f in TextFold.fold(String(ch)) {
                chars.append(f)
                origin.append(i)
            }
        }
        return (chars, origin)
    }

    private static func contains(_ hay: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for s in 0 ... hay.count - needle.count where Array(hay[s ..< s + needle.count]) == needle { return true }
        return false
    }
}

/// The find state: the hits and which one is current. Next and previous wrap around.
struct TranscriptFind: Equatable, Sendable {
    var matches: [TranscriptMatch] = []
    /// 0-based index into `matches`; nil when there are none.
    var current: Int?

    init(matches: [TranscriptMatch] = []) {
        self.matches = matches
        current = matches.isEmpty ? nil : 0
    }

    var count: Int { matches.count }
    /// 1-based position for "3 of 17".
    var position: Int? { current.map { $0 + 1 } }
    var currentMatch: TranscriptMatch? { current.map { matches[$0] } }

    mutating func next() {
        guard let c = current else { return }
        current = (c + 1) % matches.count
    }

    mutating func previous() {
        guard let c = current else { return }
        current = (c - 1 + matches.count) % matches.count
    }

    /// The Character ranges to highlight in row `row`, and whether the current match is among them.
    func ranges(inRow row: Int) -> [(range: Range<Int>, isCurrent: Bool)] {
        matches.enumerated().compactMap { i, m in
            guard m.row == row, let r = m.range else { return nil }
            return (r, i == current)
        }
    }
}
