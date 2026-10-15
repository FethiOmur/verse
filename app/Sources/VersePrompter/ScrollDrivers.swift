import Foundation
import Synchronization
import VerseSpeech

/// How the script moves. Chosen in Settings; switchable live.
public enum PrompterMode: String, Sendable, CaseIterable, Codable {
    case wordTracking
    case voicePaced
    case classic
}

/// Position source for one page. Positions are fractional word indexes inside the page (`1.5` = halfway through
/// the second word). All times are on the caller's clock; drivers never read a clock themselves, and input is
/// pushed in with `ingest`, so tests drive them with plain numbers.
public protocol ScrollDriver: Sendable {
    var mode: PrompterMode { get }
    func position(at t: TimeInterval) -> Double
    func isSpeaking(at t: TimeInterval) -> Bool
    func isLost(at t: TimeInterval) -> Bool
    func jump(toWord word: Double, at t: TimeInterval)
    func setWordsPerMinute(_ wpm: Double, at t: TimeInterval)
    func setPaused(_ paused: Bool, at t: TimeInterval)
    func ingest(_ event: TranscriptEvent, at t: TimeInterval)
    func ingest(level: Double, at t: TimeInterval)
    /// Transcript text of the range still open (used to avoid replaying old speech after a page change).
    var openTranscript: String { get }
}

public extension ScrollDriver {
    func isLost(at t: TimeInterval) -> Bool { false }
    func ingest(_ event: TranscriptEvent, at t: TimeInterval) {}
    func ingest(level: Double, at t: TimeInterval) {}
    var openTranscript: String { "" }
}

// MARK: classic

/// A timer: `wordsPerMinute` words per minute, always (while not paused).
public final class ClassicDriver: ScrollDriver {
    private struct State {
        var position: Double
        var wpm: Double
        var last: TimeInterval
        var paused = false
    }
    private let wordCount: Double
    private let state: Mutex<State>
    public var mode: PrompterMode { .classic }

    public init(wordCount: Int, startWord: Double = 0, wordsPerMinute: Double, now: TimeInterval) {
        self.wordCount = Double(wordCount)
        state = Mutex(State(position: max(0, min(startWord, Double(wordCount))), wpm: wordsPerMinute, last: now))
    }

    private func folded(_ s: State, to t: TimeInterval) -> Double {
        guard !s.paused else { return s.position }
        return min(wordCount, s.position + max(0, t - s.last) * s.wpm / 60)
    }

    private func fold(_ s: inout State, to t: TimeInterval) {
        s.position = folded(s, to: t)
        s.last = max(s.last, t)
    }

    public func position(at t: TimeInterval) -> Double { state.withLock { folded($0, to: t) } }
    public func isSpeaking(at t: TimeInterval) -> Bool { false }
    public func jump(toWord word: Double, at t: TimeInterval) {
        state.withLock { s in
            s.position = max(0, min(word, wordCount))
            s.last = t
        }
    }
    public func setWordsPerMinute(_ wpm: Double, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.wpm = wpm
        }
    }
    public func setPaused(_ paused: Bool, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.paused = paused
        }
    }
}

// MARK: voice paced

/// Moves at `wordsPerMinute` only while the microphone level says he is speaking (Textream's detector numbers:
/// activation 0.012, immediate 0.04, 2 frames, 0.75 s hangover). Stops when the hangover ends.
public final class VoicePacedDriver: ScrollDriver {
    private struct State {
        var position: Double
        var wpm: Double
        var last: TimeInterval
        var paused = false
        var vad: VoiceActivityDetector
    }
    private let wordCount: Double
    private let state: Mutex<State>
    public var mode: PrompterMode { .voicePaced }

    public init(wordCount: Int, startWord: Double = 0, wordsPerMinute: Double, now: TimeInterval,
                detector: VoiceActivityDetector = VoiceActivityDetector()) {
        self.wordCount = Double(wordCount)
        state = Mutex(State(position: max(0, min(startWord, Double(wordCount))), wpm: wordsPerMinute, last: now, vad: detector))
    }

    /// Seconds in `(last, t]` that fall inside the activity window known so far.
    private func speakingTime(_ s: State, to t: TimeInterval) -> TimeInterval {
        max(0, min(t, s.vad.activeUntilTime) - s.last)
    }

    private func folded(_ s: State, to t: TimeInterval) -> Double {
        guard !s.paused else { return s.position }
        return min(wordCount, s.position + speakingTime(s, to: t) * s.wpm / 60)
    }

    private func fold(_ s: inout State, to t: TimeInterval) {
        s.position = folded(s, to: t)
        s.last = max(s.last, t)
    }

    public func position(at t: TimeInterval) -> Double { state.withLock { folded($0, to: t) } }
    public func isSpeaking(at t: TimeInterval) -> Bool { state.withLock { !$0.paused && $0.vad.isActive(at: t) } }
    public func jump(toWord word: Double, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.position = max(0, min(word, wordCount))
        }
    }
    public func setWordsPerMinute(_ wpm: Double, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.wpm = wpm
        }
    }
    public func setPaused(_ paused: Bool, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.paused = paused
        }
    }
    public func ingest(level: Double, at t: TimeInterval) {
        state.withLock { s in
            fold(&s, to: t)
            s.vad.process(level: level, at: t)
        }
    }
}

// MARK: word tracking

/// Follows what he actually says: partial and final transcripts of the microphone channel go through
/// `PromptMatcher`. Events of any other channel (the meeting's remote audio) are ignored.
///
/// Lost: speech keeps arriving but nothing has been committed for `lostAfter` seconds (default 8). The position
/// stays; the flag stays set until the next commit or a jump.
public final class WordTrackingDriver: ScrollDriver {
    private struct State {
        var matcher: PromptMatcher
        var paused = false
        /// Latest volatile text of the open recognizer range.
        var open = ""
        /// Text that was already on screen when a jump/page change/resume happened; trimmed from the next result.
        var anchor = ""
        var lastSpeech = -TimeInterval.infinity
        var uncommittedSince: TimeInterval?
        var lostLatched = false
    }
    private let page: PromptPage
    private let lostAfter: TimeInterval
    private let speakingWindow: TimeInterval
    private let speechGap: TimeInterval
    private let state: Mutex<State>
    public var mode: PrompterMode { .wordTracking }

    public init(page: PromptPage, startWord: Double = 0, lostAfter: TimeInterval = 8, speakingWindow: TimeInterval = 1.5,
                speechGap: TimeInterval = 2.5, anchor: String = "") {
        self.page = page
        self.lostAfter = lostAfter
        self.speakingWindow = speakingWindow
        self.speechGap = speechGap
        var s = State(matcher: PromptMatcher(page: page, startingAt: page.characterOffset(forWordProgress: startWord)))
        s.anchor = anchor
        state = Mutex(s)
    }

    public var openTranscript: String { state.withLock { $0.open } }

    public func position(at t: TimeInterval) -> Double {
        state.withLock { page.wordProgress(forCharacterOffset: $0.matcher.readOffset) }
    }

    public func isSpeaking(at t: TimeInterval) -> Bool {
        state.withLock { !$0.paused && t - $0.lastSpeech < speakingWindow }
    }

    public func isLost(at t: TimeInterval) -> Bool {
        state.withLock { s in
            if s.lostLatched { return true }
            guard let since = s.uncommittedSince, !s.paused else { return false }
            // Observing it latches it: the session polls every tick, so it stays set through a pause in speech.
            if t - s.lastSpeech < speakingWindow && t - since >= lostAfter { s.lostLatched = true }
            return s.lostLatched
        }
    }

    /// The last (up to) two spoken words must each match one of the last three script words before `readOffset`,
    /// and the very last spoken word one of the last two.
    private func tailAgrees(spoken: String, readOffset: Int) -> Bool {
        let sourceTokens = SpokenText.tokens(of: page.text)
        let heard = SpokenText.normalize(spoken, sourceTokens: sourceTokens)
            .split(whereSeparator: \.isWhitespace).map { SpokenText.core(String($0)) }.filter { !$0.isEmpty }
        guard let last = heard.last else { return false }
        let read = page.words.filter { !$0.isCue && $0.characterRange.upperBound <= readOffset }
            .map { SpokenText.core($0.text) }
        guard read.suffix(2).contains(where: { PromptMatcher.isFuzzyMatch($0, last) }) else { return false }
        let recent = read.suffix(3)
        return heard.suffix(2).allSatisfy { word in recent.contains { PromptMatcher.isFuzzyMatch($0, word) } }
    }

    public func jump(toWord word: Double, at t: TimeInterval) {
        state.withLock { s in
            s.matcher.jump(to: page.characterOffset(forWordProgress: word))
            s.anchor = s.open
            s.uncommittedSince = nil
            s.lostLatched = false
        }
    }

    public func setWordsPerMinute(_ wpm: Double, at t: TimeInterval) {}

    public func setPaused(_ paused: Bool, at t: TimeInterval) {
        state.withLock { s in
            guard s.paused != paused else { return }
            s.paused = paused
            if !paused {
                s.matcher.restartFromCurrentProgress()
                s.anchor = s.open
                s.uncommittedSince = nil
            }
        }
    }

    public func ingest(_ event: TranscriptEvent, at t: TimeInterval) {
        guard event.channel == .me else { return }
        state.withLock { s in
            if s.paused {
                s.open = event.isFinal ? "" : event.text
                return
            }
            var spoken = event.text
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            if t - s.lastSpeech > speechGap { s.uncommittedSince = nil }
            s.lastSpeech = t
            if s.uncommittedSince == nil { s.uncommittedSince = t }

            if !s.anchor.isEmpty {
                // Same trimming rule as Textream: drop the part of the transcript that predates the jump.
                let common = zip(s.anchor, spoken).prefix(while: { $0 == $1 }).count
                let trim = min(spoken.count, max(common, s.anchor.count - 24))
                spoken = String(spoken.dropFirst(trim))
            }
            if !spoken.isEmpty, let offset = s.matcher.advance(spoken: spoken) {
                // The matcher's gate accepts small single-strategy steps and long off-script speech can creep
                // forward on shared letters. Only a commit whose last spoken word matches one of the last two
                // script words read counts as "he is reading the script" for the lost clock.
                if tailAgrees(spoken: spoken, readOffset: offset) {
                    s.uncommittedSince = nil
                    s.lostLatched = false
                }
            }
            if event.isFinal {
                s.matcher.restartFromCurrentProgress()
                s.open = ""
                s.anchor = ""
            } else {
                s.open = event.text
            }
            if let since = s.uncommittedSince, t - since >= lostAfter { s.lostLatched = true }
        }
    }
}
