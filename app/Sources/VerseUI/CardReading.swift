import Foundation
import VersePrompter
import VerseSpeech

/// How much of the card's SAY line Alex has already said, for the prompter-style answer card (spec 3.2, states 4
/// and 5: spoken words 100 % white, unspoken 55 %).
///
/// It is the same word tracking the meeting-card prompter mode uses: one `WordTrackingDriver` (the `PromptMatcher`
/// behind the teleprompter) per SAY text, fed with the `me` channel of the meeting's `MeetingMicTap`. No second
/// matcher. Without a `me` channel nothing is ever fed, so every word stays unspoken. A new SAY text (a new card, the
/// selected tier, a follow card replacing the card) starts a fresh driver: nothing is spoken yet, and the speech that
/// is still open at that moment is not counted against the new line.
///
/// Room route (anytime calls, before speaker separation): the one microphone hears Alex and the other person, and its
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
@MainActor
public final class CardReading: ObservableObject {
    /// The SAY text the count belongs to.
    @Published public private(set) var say: String?
    /// Whole words of `say` already said.
    @Published public private(set) var spokenWords = 0

    /// The call is in the room route: the microphone's `remote` events count as well as `me` ones.
    public var roomRoute = false

    private let clock: PrompterClock
    private var gate = RoomReadingGate()
    private var driver: WordTrackingDriver?
    private var consumer: Task<Void, Never>?

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

    /// The overlay's SAY changed (or not). The same text again keeps the count.
    public func setSay(_ text: String?) {
        let text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard text != say else { return }
        let anchor = driver?.openTranscript ?? ""
        say = text
        spokenWords = 0
        gate.reset()
        guard let text else { driver = nil; return }
        driver = WordTrackingDriver(page: PromptPage(text: text), anchor: anchor)
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
        guard event.channel == .me || (roomRoute && event.channel == .remote), let driver else { return }
        if event.channel == .remote, let say, !gate.accepts(event, say: say, now: clock.now()) { return }
        let t = clock.now()
        var mine = event
        mine.channel = .me                  // the word tracker only takes his channel; in the room the microphone is both of them
        driver.ingest(mine, at: t)
        let words = Int((driver.position(at: t) + 1e-9).rounded(.down))
        if words > spokenWords { spokenWords = words }
    }

    /// Screenshot renderer: shows a SAY text with `spokenWords` already said, without any transcript.
    func presentForPreview(say text: String, spokenWords words: Int) {
        say = text
        spokenWords = words
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

    private(set) var cursor = 0
    private var base = 0
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

    mutating func accepts(_ event: TranscriptEvent, say: String, now: TimeInterval) -> Bool {
        let words = RoomReading.words(event.text)
        let card = RoomReading.words(say)
        let sameRange = !lastFinal && (abs(event.audioStart - lastStart) < Self.sameStart || Self.sharedPrefix(words, lastWords) >= 2)
        if !sameRange { base = cursor; entry = nil }
        lastWords = words
        lastFinal = event.isFinal
        lastStart = event.audioStart
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
