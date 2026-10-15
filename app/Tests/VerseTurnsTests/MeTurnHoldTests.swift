import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// A me result too short for the text guard to judge, made of a word the remote channel also said nearby, must not close
/// the open remote turn until it is credible as the owner's own speech (fake events, no recognizer).
final class MeTurnHoldTests: XCTestCase {

    /// The sequence the real recognizers produce for speaker bleed (MeChannelTests, guard only): the mic recognizer's first
    /// volatile result is the single word "Can", which the guard cannot judge; "Can you" next is an echo. Before the hold the
    /// single word opened a me turn, closed "Can you tell me" as a turn, and the rest of the question became a second turn.
    func testOneWordBleedMidQuestionLeavesOneRemoteTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("Can you tell me", at: 1.09, start: 0.0))
        out += await engine.ingestTimed(ev("Can", at: 1.097, channel: .me, start: 0.0, end: 1.09))        // one word: cannot be judged
        XCTAssertTrue(out.turns.isEmpty, "the remote turn stays open for a me word that may be echo")
        out += await engine.ingestTimed(ev("Can you", at: 1.098, channel: .me, start: 0.0, end: 1.09))   // two words: echo, dropped
        out += await engine.ingestTimed(ev("Can you tell me about yourself", at: 1.25, start: 0.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself", at: 1.26, channel: .me, start: 0.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself and your background?", at: 1.45, start: 0.0))
        out += await engine.advance(to: 6.0)
        let remote = out.turns.filter { $0.speaker == .remote }
        XCTAssertEqual(remote.count, 1, "one remote turn for one question: \(remote.map(\.text))")
        XCTAssertEqual(remote.first?.text, "Can you tell me about yourself and your background?")
        XCTAssertTrue(out.turns.filter { $0.speaker == .me }.isEmpty, "the echo never became a me turn")
    }

    /// The second failure seen with the real recognizers: no single word, but the microphone recognizer a few words ahead of the
    /// remote one. "Can you tell me about yourself and" (7 words) has 4 of its words in what the remote said so far: under the
    /// 0.6 drop line (4/7), so it opened a me turn and closed the question; the remote words arrived 6 ms later.
    func testMicRecognizerAheadOfTheRemoteOneDoesNotCutTheQuestion() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("Can you tell me", at: 1.1, start: 0.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself and", at: 1.3, channel: .me, start: 0.0))
        XCTAssertTrue(out.turns.isEmpty, "held: the remote words for the tail have not arrived")
        out += await engine.ingestTimed(ev("Can you tell me about yourself and", at: 1.306, start: 0.0))   // the remote catches up: the me turn is echo
        out += await engine.ingestTimed(ev("Can you tell me about yourself and your background?", at: 1.5, start: 0.0))
        out += await engine.advance(to: 4.0)
        XCTAssertEqual(out.turns.filter { $0.speaker == .remote }.map(\.text), ["Can you tell me about yourself and your background?"])
        XCTAssertTrue(out.turns.filter { $0.speaker == .me }.isEmpty)
    }

    /// The same, when the echo word is the only mic result and the remote words arrive after it: the retroactive discard
    /// removes the me turn and the remote turn was never closed.
    func testBleedWordThatIsDiscardedLaterNeverClosesTheQuestion() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("What are your", at: 2.0, start: 0.0))
        out += await engine.ingestTimed(ev("Your", at: 2.05, channel: .me, start: 1.0, end: 2.0))
        out += await engine.ingestTimed(ev("What are your salary expectations", at: 2.3, start: 0.0))
        out += await engine.ingestTimed(ev("Your salary", at: 2.35, channel: .me, start: 1.0, end: 2.3))
        out += await engine.advance(to: 5.0)
        XCTAssertEqual(out.turns.filter { $0.speaker == .remote }.map(\.text), ["What are your salary expectations"])
        XCTAssertTrue(out.turns.filter { $0.speaker == .me }.isEmpty)
    }

    /// Alex really interrupts with a word that is also in the question ("and"), then goes on: the second word closes the
    /// remote turn at once (no wait for the hold window).
    func testRealInterruptionWithAmbiguousFirstWordClosesOnTheSecondWord() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("Walk me through your background and", at: 10.0, start: 7.0))
        out += await engine.ingestTimed(ev("And", at: 10.1, channel: .me, start: 10.0))
        XCTAssertTrue(out.turns.isEmpty, "held while one ambiguous word")
        let second = await engine.ingestTimed(ev("And actually I disagree", at: 10.35, channel: .me, start: 10.0))
        XCTAssertEqual(second.turns.map(\.id), ["r1"], "closed on the second word")
        XCTAssertEqual(second.turns.first?.at ?? 0, 10.35, accuracy: 0.001)
        XCTAssertEqual(second.turnKinds, [.fragment], "an interrupted question is not answered")
    }

    /// A real interruption that stays one ambiguous word still closes the remote turn when the hold window is over:
    /// at most `meCloseHoldMs` (1200 ms) after the word.
    func testSingleAmbiguousWordClosesTheRemoteTurnWithinTheHoldWindow() async {
        let cfg = TurnConfig()
        XCTAssertEqual(cfg.meCloseHoldMs, 1200)
        let engine = TurnEngine(config: cfg, bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Walk me through your background and", at: 10.0, start: 7.0))
        let word = await engine.ingestTimed(ev("And", at: 10.1, channel: .me, start: 10.0))
        XCTAssertTrue(word.turns.isEmpty)
        // The interviewer keeps talking (audio level) and the recognizer keeps repeating the one word, so nothing else ends a turn.
        var early: [TurnEngine.Timed] = []
        var t = 10.2
        while t < 11.25 {
            early += await engine.noteRemoteLevel(-20, at: t)
            if abs(t - 10.9) < 0.01 { early += await engine.ingestTimed(ev("And", at: t, channel: .me, start: 10.0)) }
            t += 0.1
        }
        XCTAssertTrue(early.turns.isEmpty, "still inside the window: \(early.turns)")
        let due = await engine.noteRemoteLevel(-20, at: 11.32)
        XCTAssertEqual(due.turns.map(\.id), ["r1"])
        XCTAssertEqual(due.turns.first?.at ?? 0, 11.3, accuracy: 0.001, "closed meCloseHoldMs (1200) after the word")
    }

    /// A word the remote channel did not say is not bleed: no wait at all (TurnOverlapTests pins the same for "Sorry").
    func testWordTheRemoteNeverSaidClosesImmediately() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Walk me through your background and", at: 10.0, start: 7.0))
        let out = await engine.ingestTimed(ev("Actually", at: 10.1, channel: .me, start: 10.0))
        XCTAssertEqual(out.turns.map(\.id), ["r1"])
        XCTAssertEqual(out.turns.first?.at ?? 0, 10.1, accuracy: 0.001)
    }
}
