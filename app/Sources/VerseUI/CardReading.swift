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
@MainActor
public final class CardReading: ObservableObject {
    /// The SAY text the count belongs to.
    @Published public private(set) var say: String?
    /// Whole words of `say` already said.
    @Published public private(set) var spokenWords = 0

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
        let stream = tap.stream()
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.ingest(event)
            }
        }
    }

    /// One transcript event. Only `Channel.me` counts.
    public func ingest(_ event: TranscriptEvent) {
        guard event.channel == .me, let driver else { return }
        let t = clock.now()
        driver.ingest(event, at: t)
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
