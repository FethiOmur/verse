import Foundation
import VerseTurns
import VerseUI
import XCTest

/// V2 on the overlay: sentinel lines never reach a card (bug 1), a bank hit that lands after the turn closed as
/// statement/fragment opens its card (bug 2), a bank hit takes the turn's topic chips down (bug 3).
@MainActor
final class TurnFixesOverlayTests: XCTestCase {
    private let bank = ["b001": BankOpener(opener: "Sure, I'll give you the short version.", points: ["I led Lantern.", "Entry fell to 2 minutes."])]

    private func model() -> OverlayModel {
        let c = Clock()
        let m = OverlayModel(config: OverlayConfig(cardTimeout: 45), bank: bank, clock: { c.t })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    private func brainHit(_ tid: String, _ bid: String = "b001") -> RunnerEvent {
        .brain(obj(["type": "bank_hit", "turn_id": tid, "bank_id": bid, "score": 0.9, "via": "embed"]))
    }

    private func topicChip(_ tid: String, _ text: String) -> RunnerEvent {
        .chip(obj(["type": "chip", "turn_id": tid, "kind": "topic", "text": text, "source_ref": "prep:L1", "fact_id": "t001"]))
    }

    // MARK: bug 1

    func testSentinelLinesNeverRenderOnACard() {
        let m = model()
        m.apply(turn("r1", "What did the pilot achieve?"))
        for e in stream("f1", "r1", "F", "NONE") { m.apply(e) }
        XCTAssertNil(m.state.card?.say)
        XCTAssertEqual(m.state.card?.bullets ?? [], [])
        for e in stream("f1", "r1", "F", "SAY: NONE") { m.apply(e) }
        XCTAssertNil(m.state.card?.say)
        for e in stream("d1", "r1", "D", "- none") { m.apply(e) }
        XCTAssertEqual(m.state.card?.deepPoints ?? [], [])
        // a real line next to it still shows
        for e in stream("f1", "r1", "F", "SAY: Sure, here is the short version.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "Sure, here is the short version.")
    }

    func testSentinelSayDoesNotOpenACardForAStatement() {
        let m = model()
        m.apply(turn("r1", "I will be taking notes during the call.", kind: "statement"))
        // the whole line in one chunk, as the brain sends a line it has held to the end
        m.apply(delta("f1", "r1", "F", "SAY: NONE", done: true))
        XCTAssertNil(m.state.card, "a sentinel SAY line is not an answer")
        for e in stream("f1", "r1", "F", "SAY: Of course.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "Of course.")
    }

    // MARK: bug 2

    func testLateBrainHitOpensTheCardOfAFragmentAndAStatement() {
        for kind in ["fragment", "statement"] {
            let m = model()
            m.apply(turn("r1", "So have you built something like this end to end before", kind: kind))
            XCTAssertNil(m.state.card, kind)
            m.apply(brainHit("r1"))
            XCTAssertEqual(m.state.card?.turnID, "r1", kind)
            XCTAssertEqual(m.state.card?.say, "Sure, I'll give you the short version.", "P opener at once (\(kind))")
        }
    }

    func testHitBeforeTheTurnAlsoOpensTheCardOfAFragment() {
        let m = model()
        m.apply(brainHit("r1"))
        m.apply(turn("r1", "So have you built something like this end to end before", kind: "fragment"))
        XCTAssertEqual(m.state.card?.turnID, "r1")
    }

    func testLateHitNeverTakesOverANewerTurnOrOpensACardForAnotherAddressee() {
        let m = model()
        m.apply(turn("r1", "So have you built something like this end to end before", kind: "fragment"))
        m.apply(turn("r2", "What did the pilot achieve?"))
        m.apply(brainHit("r1"))
        XCTAssertEqual(m.state.card?.turnID, "r2")
        let o = model()
        o.apply(turn("r1", "Marco, have you built something like this", addressee: "other", kind: "fragment"))
        o.apply(brainHit("r1"))
        XCTAssertNil(o.state.card)
    }

    func testFragmentWithoutAHitStillOpensNoCard() {
        let m = model()
        m.apply(turn("r1", "So the thing is", kind: "fragment"))
        XCTAssertNil(m.state.card)
    }

    // MARK: bug 3

    func testBrainHitClearsTheTopicChipsOfThatTurnOnly() {
        let m = model()
        m.apply(topicChip("r1", "Lantern project"))
        m.apply(topicChip("r0", "Notice period"))
        XCTAssertEqual(m.state.topics.map(\.text), ["Lantern project", "Notice period"])
        m.apply(brainHit("r1"))
        XCTAssertEqual(m.state.topics.map(\.text), ["Notice period"])
        // a chip of that turn that was still on its way is dropped
        m.apply(topicChip("r1", "Kubernetes"))
        XCTAssertEqual(m.state.topics.map(\.text), ["Notice period"])
    }

    func testNgramHitClearsTopicChipsToo() {
        let m = model()
        m.apply(topicChip("r1", "Lantern project"))
        m.apply(.outbound(obj(["type": "bank_hit", "turn_id": "r1", "bank_id": "b001", "score": 0.7, "dir": "to_brain"])))
        XCTAssertTrue(m.state.topics.isEmpty)
    }
}
