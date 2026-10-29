import Foundation
import VersePrompter
import VerseSpeech

/// How much of the card's SAY line the owner has already said, for the prompter-style answer card (spec 3.2, states 4
/// and 5; since 29 Oct spoken words fade to 35 % and unspoken stay 100 % white).
///
/// It is the same word tracking the meeting-card prompter mode uses: one `WordTrackingDriver` (the `PromptMatcher`
/// behind the teleprompter) per SAY text, fed with the `me` channel of the meeting's `MeetingMicTap`. No second
/// matcher. Without a `me` channel nothing is ever fed, so every word stays unspoken. A new SAY text (a new card, the
/// selected tier, a follow card replacing the card) starts a fresh driver: nothing is spoken yet, and the speech that
/// is still open at that moment is not counted against the new line.
///
/// Room route (anytime calls, before speaker separation): the one microphone hears the owner and the other person, and its
/// events arrive as `remote`. With `roomRoute` on, every event of the microphone feeds the matcher. That is safe because
/// the matcher only advances on words that follow the SAY text in order, so another person's speech rarely moves it; what
/// it cannot tell apart is another person reading the same words (the interim rule until separation; see the spec, 2.1).
/// It does move on a sentence that restates the SAY line in order, though (an interviewer repeating the question the card
/// answers: 12 of 22 words struck in the fixture test), so a room event only reaches the matcher when the tail of its text
/// lines up with the SAY line (`RoomReading`): reading the card does, a question that shares a few words does not.
///
/// The recognizer can deliver the reading in finals of two to six words (live Italian call, 16 Oct), too short for that window rule.
/// `RoomReadingGate` therefore also follows a reading cursor on the SAY line: a fragment that begins the line, or that continues
/// from the cursor inside a reading session, moves the count too (the brain's `own.py` applies the same three rules to the
/// transcript).
///
/// Re-anchoring (the twin of the brain's "anchor" rule in `own.py`): every rule above follows one in-order path from the cursor, so
/// a jump on the card (a skipped sentence, a re-read line, a start from a point) lost it. `RoomReadingGate.anchor` therefore also
/// searches the whole card, the SAY line and the points, for a stretch of `anchorMin` or more content words (`anchorGap` at most
/// skipped between two) holding `anchorShare` of the text, and the reading moves there, forward or back. What is struck is the set
/// of words actually read (`struck`), not a prefix: a jump ahead strikes nothing it skipped, and a jump back un-strikes nothing.
@MainActor
public final class CardReading: ObservableObject {
    /// The SAY text the count belongs to.
    @Published public private(set) var say: String?
    /// How many words of `say` are struck (said). For a reading that never jumped these are its first `spokenWords` words.
    @Published public private(set) var spokenWords = 0
    /// Which words of `say` are struck, by index among its whitespace-separated words.
    @Published public private(set) var struck = IndexSet()

    /// The call is in the room route: the microphone's `remote` events count as well as `me` ones.
    public var roomRoute = false

    private let clock: PrompterClock
    private var gate = RoomReadingGate()
    private var driver: WordTrackingDriver?
    private var consumer: Task<Void, Never>?
    /// The points under the SAY line: part of the card the reading can jump to (the brain strikes them; here they only anchor).
    private var points: [String] = []
    private var card: ReadingCard?
    /// The SAY word the driver's current stretch started at: what it reads from there on is struck, nothing before it.
    private var segmentStart = 0

    public init(clock: PrompterClock = SystemPrompterClock()) {
        self.clock = clock
    }

    deinit { consumer?.cancel() }

    /// Spoken words for the SAY text the card shows now; 0 for any other text, so a card never shows the previous
    /// line's progress, even for the frame before `setSay` runs.
    public func spoken(for text: String?) -> Int {
        guard let text, text == say else { return 0 }
        return spokenWords
    }

    /// The struck words of the SAY text the card shows now; none for any other text.
    public func struckWords(for text: String?) -> IndexSet {
        guard let text, text == say else { return IndexSet() }
        return struck
    }

    /// The overlay's SAY changed (or not). The same text again keeps the count.
    public func setSay(_ text: String?) {
        let text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard text != say else { return }
        let anchor = driver?.openTranscript ?? ""
        say = text
        spokenWords = 0
        struck = IndexSet()
        segmentStart = 0
        gate.reset()
        rebuildCard()
        guard let text else { driver = nil; return }
        driver = WordTrackingDriver(page: PromptPage(text: text), anchor: anchor)
    }

    /// The points under the SAY line, in reading order. The reading can re-anchor on them; they are not struck here.
    public func setPoints(_ new: [String]) {
        guard new != points else { return }
        points = new
        rebuildCard()
    }

    private func rebuildCard() {
        card = say.map { ReadingCard(lines: [$0] + points) }
    }

    /// Follows the `me` channel of a meeting; nil stops following.
    public func connect(_ tap: MeetingMicTap?) {
        consumer?.cancel()
        consumer = nil
        guard let tap else { return }
        let stream = tap.cardStream()
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.ingest(event)
            }
        }
    }

    /// One transcript event. `Channel.me` counts; in the room route the microphone's `remote` events count too.
    public func ingest(_ event: TranscriptEvent) {
        guard event.channel == .me || (roomRoute && event.channel == .remote), driver != nil else { return }
        let t = clock.now()
        var taken = true
        if event.channel == .remote, let say {
            taken = gate.accepts(event, say: say, now: t)
        } else {
            gate.observe(event)
        }
        // the path from the cursor is lost when he jumps: look for a new anchor on the whole card first
        if let card, let anchor = gate.anchor(for: event, card: card) {
            relocate(to: anchor, event: event, now: t)
            return
        }
        guard taken else { return }
        feed(event, now: t)
    }

    /// The reading moved to `anchor`: the gate's cursor goes there (back as well as forward); on the SAY line the word tracker starts
    /// again at the first word read, and only what is read from there on is struck. An anchor on a point leaves the SAY line as it is.
    private func relocate(to anchor: ReadingAnchor, event: TranscriptEvent, now t: TimeInterval) {
        let newRange = gate.newRange
        gate.relocate(anchor, now: t)
        guard anchor.line == 0, let say, let card else { return }
        let word = card.word[anchor.firstToken]
        if newRange || word != segmentStart {
            segmentStart = word
            driver = WordTrackingDriver(page: PromptPage(text: say), startWord: Double(word), anchor: anchor.prefix)
        }
        feed(event, now: t)
    }

    private func feed(_ event: TranscriptEvent, now t: TimeInterval) {
        guard let driver else { return }
        var mine = event
        mine.channel = .me                  // the word tracker only takes his channel; in the room the microphone is both of them
        driver.ingest(mine, at: t)
        let words = Int((driver.position(at: t) + 1e-9).rounded(.down))
        if words > segmentStart {
            struck.insert(integersIn: segmentStart..<words)
            if struck.count != spokenWords { spokenWords = struck.count }
            if event.channel == .me, let card { gate.follow(cursor: card.firstToken(ofSayWord: words)) }
        }
    }

    /// Where the reading cursor sits on the whole card (SAY line, then points), as a word position; for tests.
    var readingCursor: Int { gate.cursor }

    /// The SAY word the word tracker has got to; for tests.
    var trackerWord: Int { driver.map { Int(($0.position(at: clock.now()) + 1e-9).rounded(.down)) } ?? 0 }

    /// Screenshot renderer: shows a SAY text with `spokenWords` already said, without any transcript.
    func presentForPreview(say text: String, spokenWords words: Int) {
        say = text
        spokenWords = words
        struck = words > 0 ? IndexSet(integersIn: 0..<words) : IndexSet()
    }
}

/// Where the SAY text turns from said to unsaid.
enum SaySplit {
    /// `text` cut after its first `words` whitespace-separated words. `spoken` keeps its trailing space, so the two
    /// parts join back into `text` exactly.
    static func split(_ text: String, spokenWords words: Int) -> (spoken: String, rest: String) {
        guard words > 0 else { return ("", text) }
        var seen = 0
        var inWord = false
        var cut = text.endIndex
        for i in text.indices {
            if text[i].isWhitespace {
                if inWord {
                    seen += 1
                    inWord = false
                    if seen == words { cut = text.index(after: i); break }
                }
            } else {
                inWord = true
            }
        }
        return (String(text[..<cut]), String(text[cut...]))
    }
}


extension SaySplit {
    /// `text` cut into runs of struck and unstruck words (`struck`: indices among its whitespace-separated words). The whitespace after a
    /// word belongs to it, so the runs join back into `text` exactly.
    static func segments(_ text: String, struck: IndexSet) -> [(text: String, spoken: Bool)] {
        var out: [(text: String, spoken: Bool)] = []
        var word = -1
        var inWord = false
        for ch in text {
            if ch.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                word += 1
            }
            let spoken = struck.contains(max(word, 0))
            if let last = out.last, last.spoken == spoken {
                out[out.count - 1].text.append(ch)
            } else {
                out.append((String(ch), spoken))
            }
        }
        return out
    }
}


/// Room route, before speaker separation: does this microphone text read the SAY line? The last `window` words of the text
/// must sit on one in-order path through the SAY words (at most `maxGap` SAY words skipped between two matched ones) for at
/// least `minShare` of them, with at least `minMatched` matched. Plain lower-cased words (no stop list: the matcher it guards
/// is character-based and counts every word); the brain's own relabelling (`brain/verse_brain/runtime/own.py`) uses the
/// follow detector's content words and stemmer for the same question.
enum RoomReading {
    static let window = 12
    static let minShare = 0.7
    static let minMatched = 4
    static let maxGap = 3

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The words of `s` like `words`, with where each one sits in `s` (so a text can be cut before a word).
    static func spans(_ s: String) -> [(word: String, range: Range<String.Index>)] {
        var out: [(word: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            if s[i].isLetter || s[i].isNumber {
                if start == nil { start = i }
            } else if let from = start {
                out.append((String(s[from..<i]).lowercased(), from..<i))
                start = nil
            }
            i = next
        }
        if let from = start { out.append((String(s[from...]).lowercased(), from..<s.endIndex)) }
        return out
    }

    /// The longest in-order path of matched pairs (text index, card index) for re-anchoring: it may begin anywhere on the card, at most
    /// `maxGap` card entries are skipped between two matches, and among equally long paths the one that begins nearest to card position
    /// `near` wins. Rank of a path = (matched pairs, -|start - near|); the first found wins a tie, in the order text index, card index.
    /// Twin of `anchor_path` in `brain/verse_brain/runtime/own.py`.
    static func anchorPath(_ text: [String], _ card: [String], maxGap: Int, near: Int) -> [(Int, Int)] {
        struct Cell { var count: Int; var prev: [Int]?; var start: Int }
        func better(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 != b.0 ? a.0 > b.0 : a.1 > b.1 }
        var best: [[Int]: Cell] = [:]
        var top: [Int]?
        for i in text.indices {
            for j in card.indices where card[j] == text[i] {
                var cur = Cell(count: 1, prev: nil, start: j)
                for i2 in 0..<i {
                    for j2 in max(0, j - 1 - maxGap)..<max(0, j) {
                        guard let c = best[[i2, j2]] else { continue }
                        if better((c.count + 1, -abs(c.start - near)), (cur.count, -abs(cur.start - near))) {
                            cur = Cell(count: c.count + 1, prev: [i2, j2], start: c.start)
                        }
                    }
                }
                best[[i, j]] = cur
                if let t = top, !better((cur.count, -abs(cur.start - near)), (best[t]!.count, -abs(best[t]!.start - near))) { continue }
                top = [i, j]
            }
        }
        var out: [(Int, Int)] = []
        var node = top
        while let n = node {
            out.append((n[0], n[1]))
            node = best[n]?.prev
        }
        return out.reversed()
    }

    static func reads(_ text: String, say: String) -> Bool {
        let tail = Array(words(text).suffix(window))
        let card = words(say)
        guard tail.count >= minMatched, !card.isEmpty else { return false }
        let n = aligned(tail, card)
        return n >= minMatched && Double(n) / Double(tail.count) >= minShare
    }

    /// The longest in-order path of matched pairs (text index, card index), skipping at most `maxGap` card words between two matches;
    /// `first` says where on the card a path may begin.
    static func path(_ text: [String], _ card: [String], maxGap: Int, first: (Int) -> Bool) -> [(Int, Int)] {
        var best: [[Int]: (count: Int, prev: [Int]?)] = [:]
        var top: [Int]?
        for i in text.indices {
            for j in card.indices where card[j] == text[i] {
                var count = 0
                var prev: [Int]?
                for i2 in 0..<i {
                    for j2 in max(0, j - 1 - maxGap)..<max(0, j) where j2 < j {
                        if let c = best[[i2, j2]], c.count > count { count = c.count; prev = [i2, j2] }
                    }
                }
                if count == 0 && !first(j) { continue }
                best[[i, j]] = (count + 1, prev)
                if top == nil || count + 1 > best[top!]!.count { top = [i, j] }
            }
        }
        var out: [(Int, Int)] = []
        var cur = top
        while let c = cur {
            out.append((c[0], c[1]))
            cur = best[c]?.prev
        }
        return out.reversed()
    }

    /// Most words of `text` on one in-order path through `card`, skipping at most `maxGap` card words between two matches.
    static func aligned(_ text: [String], _ card: [String]) -> Int {
        var best = [Int](repeating: 0, count: card.count)
        var top = 0
        for w in text {
            var row: [Int: Int] = [:]
            for j in card.indices where card[j] == w {
                let lo = max(0, j - 1 - maxGap)
                let prev = j > lo ? (best[lo..<j].max() ?? 0) : 0
                row[j] = prev + 1
            }
            for (j, v) in row where v > best[j] { best[j] = v; top = max(top, v) }
        }
        return top
    }
}


/// Room route, before speaker separation: the stateful form of `RoomReading`. A microphone event is taken for his reading of the SAY
/// line by one of three rules, on one in-order path through the SAY words (at most `maxGap` SAY words skipped between two matched
/// ones):
///
/// * window: the last `RoomReading.window` words line up with the line (`RoomReading.reads`);
/// * start: at least `startMin` words matched from the first `startSlack` words of the line, `startShare` of the text on the path;
/// * continue: inside a reading session (the last accepted event was within `sessionSeconds`), the first matched SAY word lies at most
///   `back` before and `ahead` after the cursor (the SAY position after the last matched stretch) with at least `continueWeight`
///   matched, `continueShare` of the text on the path. A word of four letters or more weighs 1, a shorter one 0.5: a fragment of
///   three short words proves little, "sia la chiarezza" proves enough.
///
/// The cumulative partials and the final of one recognizer range are all judged from the cursor the range started at, not from
/// where its own earlier partials moved it. A range that has once been taken for his reading stays his while `exitShare` of its
/// words lie on the path that began where his reading of the range began (a recognizer revises words between two partials; live
/// English call, 17 Oct: the highlight stopped in the middle of a sentence). Reset with the SAY text.
struct RoomReadingGate {
    static let sessionSeconds = 4.0
    static let startMin = 3
    static let startSlack = 2
    static let startShare = 0.75
    static let allGap = 4
    static let continueWeight = 2.0
    static let continueShare = 0.6
    static let back = 2
    static let ahead = 4
    static let exitShare = 0.6
    static let stayMin = 3
    /// Two partials are one range when their start times are this close, or they open with the same two words.
    static let sameStart = 0.75
    // Re-anchoring anywhere on the card (twin: OwnParams.anchor_min / anchor_gap / anchor_share in brain/verse_brain/runtime/own.py).
    // Stronger than the continue rule (2 words, near the cursor) because it may land anywhere: a question that shares two or three
    // card words, or one matching word, never moves the reading. The share sits above the nearest interviewer fixture there (an
    // interviewer quoting 4 consecutive card words with one more of his own: 4 of 5 = 0.80); a short line read whole (4 of 4) passes.
    static let anchorMin = 4        // content words on one near-consecutive path (function words do not count)
    static let anchorGap = 1        // card content words that may be skipped between two matched ones
    static let anchorShare = 0.85   // share of the text's content words on that path

    private(set) var cursor = 0
    /// The cursor when the current recognizer range began: every partial and the final of one range are judged from here.
    private(set) var base = 0
    /// The last event opened a new recognizer range.
    private(set) var newRange = false
    /// Where on the SAY line the reading of the current range began; nil until the range has been taken for his.
    private var entry: Int?
    private var lastRead: TimeInterval?
    private var lastWords: [String] = []
    private var lastFinal = true
    private var lastStart = -1.0

    mutating func reset() {
        self = RoomReadingGate()
    }

    func sessionActive(at now: TimeInterval) -> Bool {
        guard let lastRead else { return false }
        return now - lastRead <= Self.sessionSeconds
    }

    /// Notes an event: is it a new recognizer range, and the words it holds.
    @discardableResult
    mutating func observe(_ event: TranscriptEvent) -> [String] {
        let words = RoomReading.words(event.text)
        let sameRange = !lastFinal && (abs(event.audioStart - lastStart) < Self.sameStart || Self.sharedPrefix(words, lastWords) >= 2)
        newRange = !sameRange
        if !sameRange { base = cursor; entry = nil }
        lastWords = words
        lastFinal = event.isFinal
        lastStart = event.audioStart
        return words
    }

    /// The reading jumped: the cursor goes to `anchor`, forward or back (the other rules only ever move it forward).
    mutating func relocate(_ anchor: ReadingAnchor, now: TimeInterval) {
        cursor = anchor.cursor
        entry = anchor.firstToken
        lastRead = now
    }

    /// His own channel moved the word tracker to card position `cursor`: the cursor follows it forward.
    mutating func follow(cursor position: Int) {
        cursor = max(cursor, position)
    }

    /// Where on the whole card (SAY line and points) this text re-anchors the reading, or nil: fewer than `anchorMin` content words on a
    /// near-consecutive path, under `anchorShare` of the text's content words on it, or a path that only continues the reading where
    /// it was (its first word within `back` before and `ahead` after the range's starting cursor), which the other rules judge. Call
    /// after `observe`/`accepts` of the same event.
    func anchor(for event: TranscriptEvent, card: ReadingCard) -> ReadingAnchor? {
        let text = RoomReading.spans(event.text)
        let lang = ReadingWords.language(event.lang)
        let mine = text.indices.filter { ReadingWords.isContent(text[$0].word, lang) }
        guard mine.count >= Self.anchorMin else { return nil }
        let content = card.tokens.indices.filter { ReadingWords.isContent(card.tokens[$0], lang) }
        let near = content.filter { $0 < base }.count
        let path = RoomReading.anchorPath(mine.map { ReadingWords.stem(text[$0].word, lang) },
                                          content.map { ReadingWords.stem(card.tokens[$0], lang) }, maxGap: Self.anchorGap, near: near)
        guard path.count >= Self.anchorMin, Double(path.count) / Double(mine.count) >= Self.anchorShare,
              let head = path.first, let tail = path.last else { return nil }
        var first = content[head.1]
        if first >= base - Self.back && first <= base + Self.ahead { return nil }
        // function words just before the first matched content word are part of what he read: they start the stretch too
        var from = mine[head.0]
        while from > 0, first > 0, card.line[first - 1] == card.line[first], text[from - 1].word == card.tokens[first - 1] {
            from -= 1
            first -= 1
        }
        return ReadingAnchor(firstToken: first, cursor: content[tail.1] + 1, line: card.line[first], matched: path.count,
                             prefix: String(event.text[..<text[from].range.lowerBound]))
    }

    mutating func accepts(_ event: TranscriptEvent, say: String, now: TimeInterval) -> Bool {
        let words = observe(event)
        let card = RoomReading.words(say)
        guard !words.isEmpty, !card.isEmpty else { return false }
        if let e = entry {
            // the range is already his: it stays his while enough of it lies on the path that began where it began
            let path = Self.path(words, card, first: { $0 >= e - Self.back && $0 <= e + Self.ahead })
            if path.count >= Self.stayMin, Double(path.count) / Double(words.count) >= Self.exitShare {
                cursor = max(cursor, (path.last?.1 ?? 0) + 1)
                lastRead = now
                return true
            }
        }
        let tail = Array(words.suffix(RoomReading.window))
        var end: Int?
        var firstCard: Int?
        if RoomReading.reads(event.text, say: say) {
            let p = RoomReading.path(tail, card, maxGap: RoomReading.maxGap, first: { _ in true })
            end = p.last?.1
            firstCard = p.first?.1
        }
        if end == nil {
            let path = Self.path(words, card, first: { $0 <= Self.startSlack })
            if path.count >= Self.startMin, Double(path.count) / Double(words.count) >= Self.startShare, Self.weight(path, words) >= 1 {
                end = path.last?.1
                firstCard = path.first?.1
            }
        }
        if end == nil, sessionActive(at: now) {
            let lo = base - Self.back, hi = base + Self.ahead
            let path = Self.path(words, card, first: { $0 >= lo && $0 <= hi })
            if Self.weight(path, words) >= Self.continueWeight, Double(path.count) / Double(words.count) >= Self.continueShare {
                end = path.last?.1
                firstCard = path.first?.1
            }
        }
        guard let end else { return false }
        cursor = max(cursor, end + 1)
        lastRead = now
        if entry == nil { entry = firstCard }
        return true
    }

    private static func sharedPrefix(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    private static func weight(_ path: [(Int, Int)], _ words: [String]) -> Double {
        path.reduce(0) { $0 + (words[$1.0].count >= 4 ? 1.0 : 0.5) }
    }

    private static func path(_ text: [String], _ card: [String], first: (Int) -> Bool) -> [(Int, Int)] {
        RoomReading.path(text, card, maxGap: allGap, first: first)
    }
}


/// Where a text re-anchored the reading (see `RoomReadingGate.anchor`).
struct ReadingAnchor: Equatable {
    /// Card token where the stretch he read begins, and the card position right after its last matched token.
    var firstToken: Int
    var cursor: Int
    /// The line of the card it begins on: 0 is the SAY line, 1 and up are the points.
    var line: Int
    var matched: Int
    /// The part of the event's text before the stretch: the word tracker must not see it.
    var prefix: String
}


/// The whole card as the re-anchoring sees it: the SAY line, then the points, as one run of lower-cased words (`RoomReading.words`).
struct ReadingCard {
    var tokens: [String] = []
    /// Per token: the line it is on, and the index of the whitespace-separated word of that line it belongs to ("co-op" is one word, two tokens).
    var line: [Int] = []
    var word: [Int] = []

    init(lines: [String]) {
        for (l, text) in lines.enumerated() {
            for (w, chunk) in text.split(whereSeparator: \.isWhitespace).enumerated() {
                for token in RoomReading.words(String(chunk)) {
                    tokens.append(token)
                    line.append(l)
                    word.append(w)
                }
            }
        }
    }

    /// The card position of the first token of SAY word `w` (the end of the SAY line when there is none).
    func firstToken(ofSayWord w: Int) -> Int {
        tokens.indices.first { line[$0] == 0 && word[$0] >= w } ?? (line.firstIndex { $0 != 0 } ?? tokens.count)
    }
}


/// Content words and stems for the re-anchoring. The brain's own relabelling (`own.py`) uses the follow detector's stemmer; this is a
/// lighter one with the same stop lists (English from `follow.py`, Italian and Turkish from `own.py`, accent-folded), which is enough to
/// tell a content word from a function word and to forgive an ending.
enum ReadingWords {
    static func language(_ lang: String) -> String {
        let l = String(lang.lowercased().prefix(2))
        return l == "it" || l == "tr" ? l : "en"
    }

    static func fold(_ w: String, _ lang: String) -> String {
        var w = w
        if lang == "tr" { w = w.replacingOccurrences(of: "I", with: "ı").replacingOccurrences(of: "İ", with: "i") }
        return w.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "ß", with: "ss")
    }

    static func isContent(_ word: String, _ lang: String) -> Bool {
        if word.contains(where: \.isNumber) { return true }
        let w = fold(word, lang)
        return w.count > 1 && !(stops[lang] ?? []).contains(w)
    }

    static func stem(_ word: String, _ lang: String) -> String {
        var w = fold(word, lang)
        if w.contains(where: \.isNumber) { return w }
        switch lang {
        case "tr":
            return String(w.prefix(5))
        case "it":
            if w.count > 4, "aeiou".contains(w.last!) { w.removeLast() }
            return String(w.prefix(6))
        default:
            for suffix in ["ing", "ed", "es", "s"] where w.count >= suffix.count + 3 && w.hasSuffix(suffix) {
                w.removeLast(suffix.count)
                break
            }
            return w
        }
    }

    static let stops: [String: Set<String>] = ["en": en, "it": it, "tr": tr]

    static let en: Set<String> = Set("""
a about actually after again ah aha ahh all almost already also although always am an and another any anyone anything
anyway approximately are around as at basically be because been before being bit both but by came can can't come could
couldn't did didn't do does doesn't doing don't done down each eh either er erm even every everyone everything exactly
first for from gave get gets getting give go goes going gone got had has hasn't have haven't having he he's here hm
hmm honestly how however huh i i'd i'll i'm i've if in into is it it's its just kind knew know let lets like literally
lot lots made mainly make makes making many may maybe me mean means meant mhm might mine mm more most mostly much must
my myself nearly need needed neither never next no nope nor not now of off often oh ok okay on one only or other our
ours out over own perhaps please pretty probably put quite rather really right roughly said same saw say saying says
see shall she she's should so some someone something sometimes sorry sort still stuff such sure take tell than thank
thanks that the their theirs them then there these they they're they've thing things think this those though thought
to told too took uh um under up us usually very want wanted was way we we'd we'll we're we've well went were what when
where which while who whom whose why will with won't would wouldn't yeah yep yes yet you you'd you'll you're you've
your yours yup
""".split(whereSeparator: \.isWhitespace).map(String.init))
    static let it: Set<String> = Set("""
a abbiamo ad agli ai al all alla alle allo allora anche ancora avere avete che chi ci col come con cosa cui da dagli
dai dal dalla dalle dallo degli dei del della delle dello di dove e ecco ed era erano ero essere fare fatto fra fu gia
gli ha hai hanno ho i il in io la le lei li lo loro lui ma mai me mi mia mie miei mio molto ne negli nei nel nella
nelle no noi non o per perche pero piu poco poi quando quel quella quelle quelli quello questa queste questi questo
quindi se sei sempre si sia solo sono stata stato su sua sue sugli sui sul sulla sulle suo suoi ti tra tu tua tue tuo
tuoi un una uno vi voi
""".split(whereSeparator: \.isWhitespace).map(String.init))
    static let tr: Set<String> = Set("""
ama bazi ben bir biz bu cok da daha de degil en evet fakat gibi hayir hem her icin ile ise iste kadar ki mi mu ne o
olarak once onlar peki sen siz sonra su tabii var ve veya ya yani yok
""".split(whereSeparator: \.isWhitespace).map(String.init))
}
