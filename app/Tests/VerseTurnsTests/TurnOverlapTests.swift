import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Two speakers at once (two-track replay, eval/twotrack/t01.json): whoever holds the floor keeps their turn; a
/// remote event never closes a me turn, and only the first event of a me turn closes the open remote turn.
final class TurnOverlapTests: XCTestCase {

    /// Alex is still finishing an answer when Ingrid asks the next question; both recognizers deliver volatile results
    /// alternately. Before the fix every event closed the other side's turn.
    func testQuestionStaysWholeWhileAlexKeepsTalking() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("I tested both on a labelled", at: 10.0, channel: .me, start: 8.0))
        out += await engine.ingestTimed(ev("How did you", at: 10.4, start: 10.0))
        out += await engine.ingestTimed(ev("I tested both on a labelled sample and picked", at: 10.8, channel: .me, start: 8.0))
        out += await engine.ingestTimed(ev("How did you choose between", at: 11.2, start: 10.0))
        out += await engine.ingestTimed(ev("I tested both on a labelled sample and picked the small model", at: 11.6, channel: .me, start: 8.0))
        out += await engine.ingestTimed(ev("How did you choose between small and large models", at: 12.0, start: 10.0))
        out += await engine.advance(to: 14.0)
        let remote = out.turns.filter { $0.speaker == .remote }
        let me = out.turns.filter { $0.speaker == .me }
        XCTAssertEqual(remote.count, 1, "one remote turn for one question: \(remote.map(\.text))")
        XCTAssertEqual(remote.first?.text, "How did you choose between small and large models")
        XCTAssertEqual(remote.first?.addressee, .me, "it follows the owner's speech")
        XCTAssertEqual(out.turnKinds.first, .question)
        XCTAssertEqual(me.count, 1, "one me turn for one utterance: \(me.map(\.text))")
        XCTAssertEqual(me.first?.text, "I tested both on a labelled sample and picked the small model")
    }

    /// The same overlap the other way round: Alex talks over the end of a question that is already open.
    func testAlexTalkingOverTheEndOpensOneMeTurnAndClosesTheQuestionOnce() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("What are your salary expectations", at: 5.0, start: 3.0))
        out += await engine.ingestTimed(ev("Between", at: 5.1, channel: .me, start: 4.9))          // starts: closes the question now
        out += await engine.ingestTimed(ev("Between seventy eight", at: 5.6, channel: .me, start: 4.9))
        out += await engine.ingestTimed(ev("What are your salary expectations", at: 5.7, final: true, start: 3.0))   // late final: no new turn
        out += await engine.ingestTimed(ev("Between seventy and eighty thousand", at: 6.2, channel: .me, start: 4.9))
        out += await engine.advance(to: 8.0)
        let turns = out.turns
        XCTAssertEqual(turns.map(\.id), ["r1", "m1"], "\(turns.map { "\($0.id): \($0.text)" })")
        XCTAssertEqual(turns.first?.at ?? 0, 5.1, accuracy: 0.001, "the question closed when Alex started")
        XCTAssertEqual(turns.last?.text, "Between seventy and eighty thousand")
    }

    /// Alex interrupts a question that is still open and cut off: closed at once, a fragment (nothing to answer).
    func testInterruptionMidQuestionClosesItAsAFragment() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Could you walk me through how you would approach building an", at: 20.0, start: 17.0))
        let out = await engine.ingestTimed(ev("Sorry", at: 20.3, channel: .me, start: 20.0))
        XCTAssertEqual(out.turns.count, 1)
        XCTAssertEqual(out.turns.first?.speaker, .remote)
        XCTAssertEqual(out.turnKinds, [.fragment], "an interrupted, unfinished question is not answered")
    }

    /// A me turn ends by its own quiet, also while the interviewer talks; nothing of it goes to the brain as a question.
    func testMeTurnClosesByItsOwnEndpointNotByRemoteEvents() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Mm hmm okay", at: 1.0, channel: .me, start: 0.5))
        let during = await engine.ingestTimed(ev("So a bit about us", at: 1.3, start: 1.0))
        XCTAssertTrue(during.turns.isEmpty, "a remote event leaves the me turn open")
        let later = await engine.advance(to: 2.4)
        XCTAssertEqual(later.turns.filter { $0.speaker == .me }.map(\.id), ["m1"])
    }
}
