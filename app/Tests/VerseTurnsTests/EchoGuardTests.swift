import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Speaker bleed: the remote voice reaches the microphone and comes back as `.me` results. The text guard drops a me
/// result whose words are the remote channel's words of the same moment.
final class EchoGuardTests: XCTestCase {

    /// A question and its echo on the microphone, result by result (the mic recognizer garbles a word now and then).
    private func playEcho(_ engine: TurnEngine) async -> [TurnEngine.Timed] {
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("Can you tell me about yourself", at: 5.0, start: 3.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself", at: 5.1, channel: .me, start: 3.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself and your background", at: 5.2, start: 3.0))
        out += await engine.ingestTimed(ev("Can you tell me a bout yourself and your background", at: 5.25, channel: .me, start: 3.0))
        out += await engine.ingestTimed(ev("Can you tell me about yourself and your background", at: 5.3, channel: .me, final: true, start: 3.0))
        out += await engine.advance(to: 8.0)
        return out
    }

    func testEchoOfTheQuestionNeverClosesTheTurnOrOpensAMeTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let out = await playEcho(engine)
        XCTAssertEqual(out.turns.map(\.id), ["r1"], "\(out.turns.map { "\($0.id) \($0.speaker): \($0.text)" })")
        XCTAssertEqual(out.turns.first?.text, "Can you tell me about yourself and your background")
        XCTAssertEqual(out.turnKinds, [.question])
        let drops = await engine.takeEchoDrops()
        XCTAssertEqual(drops.count, 3)
        XCTAssertTrue(drops.allSatisfy { $0.similarity >= 0.6 })
        let again = await engine.takeEchoDrops()
        XCTAssertTrue(again.isEmpty, "takeEchoDrops hands each drop over once")
    }

    /// Without the guard the same echo cuts the question off and invents a me turn.
    func testWithoutTheGuardTheEchoCutsTheQuestionAndInventsAMeTurn() async {
        var cfg = TurnConfig()
        cfg.echoGuardEnabled = false
        let engine = TurnEngine(config: cfg, bank: .empty, facts: .empty)
        let out = await playEcho(engine)
        XCTAssertTrue(out.turns.contains { $0.speaker == .me }, "an invented me turn")
        XCTAssertNotEqual(out.turns.filter { $0.speaker == .remote }.first?.text, "Can you tell me about yourself and your background",
                          "the question was closed early")
        let drops = await engine.takeEchoDrops()
        XCTAssertTrue(drops.isEmpty)
    }

    /// The microphone recognizer was a result ahead: the echo opened a me turn before the remote words existed. The next
    /// remote result shows what it was, and the open me turn is discarded unsent.
    func testEchoThatArrivesBeforeTheRemoteWordsIsDiscardedLater() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("What do you know", at: 5.0, channel: .me, start: 3.0))
        out += await engine.ingestTimed(ev("What do you know about our company", at: 5.1, start: 3.0))
        out += await engine.advance(to: 9.0)
        XCTAssertTrue(out.turns.filter { $0.speaker == .me }.isEmpty, "\(out.turns.map { "\($0.id): \($0.text)" })")
        let drops = await engine.takeEchoDrops()
        XCTAssertGreaterThanOrEqual(drops.count, 1)
    }

    /// Alex really talking over the interviewer, with other words, is kept and closes the question as before.
    func testOwnSpeechOverTheInterviewerIsKept() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("What are your salary expectations", at: 5.0, start: 3.0))
        let out = await engine.ingestTimed(ev("Between seventy and eighty thousand", at: 5.2, channel: .me, start: 4.6))
        XCTAssertEqual(out.turns.map(\.id), ["r1"], "the question closes when Alex starts")
        let later = await engine.advance(to: 8.0)
        XCTAssertEqual(later.turns.filter { $0.speaker == .me }.first?.text, "Between seventy and eighty thousand")
        let drops = await engine.takeEchoDrops()
        XCTAssertTrue(drops.isEmpty)
    }

    /// Alex repeating a word or two of the question as he starts his answer is not an echo: most of his words are new.
    func testAnswerThatRepeatsAFewQuestionWordsIsKept() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Can you tell me about the Lantern project", at: 5.0, start: 3.0))
        _ = await engine.ingestTimed(ev("Sure the Lantern project extracts invoice fields", at: 5.4, channel: .me, start: 4.9))
        let drops = await engine.takeEchoDrops()
        XCTAssertTrue(drops.isEmpty, "\(drops)")
    }

    /// A me result when the remote side said nothing near it can never be an echo.
    func testNothingToEchoMeansNothingIsDropped() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Can you tell me about yourself", at: 5.0, start: 3.0))
        _ = await engine.advance(to: 7.0)
        // 30 s later Alex says the same words: far outside the window
        _ = await engine.ingestTimed(ev("Can you tell me about yourself", at: 40.0, channel: .me, start: 37.0))
        let drops = await engine.takeEchoDrops()
        XCTAssertTrue(drops.isEmpty)
    }

    func testWordMatching() {
        XCTAssertEqual(EchoGuard.lcs(["a", "b", "c"], ["x", "a", "c", "b"]), 2)
        XCTAssertTrue(EchoGuard.sameWord("labelled", "labeled"))
        XCTAssertFalse(EchoGuard.sameWord("country", "countries"))
        XCTAssertFalse(EchoGuard.sameWord("you", "your"), "short words must be equal")
    }
}
