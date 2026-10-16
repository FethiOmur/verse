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
@MainActor
public final class CardReading: ObservableObject {
    /// The SAY text the count belongs to.
    @Published public private(set) var say: String?
    /// Whole words of `say` already said.
    @Published public private(set) var spokenWords = 0

    /// The call is in the room route: the microphone's `remote` events count as well as `me` ones.
    public var roomRoute = false

    private let clock: PrompterClock
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
        if event.channel == .remote, let say, !RoomReading.reads(event.text, say: say) { return }
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
