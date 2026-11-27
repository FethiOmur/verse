import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Live nudges on the island (docs/specs/2026-11-27-live-nudges-plan.md, "Island behaviour"): `state.nudge` is apart from the
/// card, lives `ttl_s` seconds, is cleared by `nudge_clear`, collapse, stop and reset, and is dropped while the prompter, a
/// practice interview or a status panel is showing.
@MainActor
final class NudgeOverlayTests: XCTestCase {
    private func model(_ clock: Clock) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(), bank: [:], clock: { clock.t })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    private func nudge(_ id: String = "n001", title: Any? = "Pay story", lines: Any? = ["Lead with the range.", "Then the reason."],
                       ttl: Any? = nil, turn: Any? = 41) -> RunnerEvent {
        var d: [String: Any] = ["type": "nudge", "id": id]
        if let title { d["title"] = title }
        if let lines { d["lines"] = lines }
        if let ttl { d["ttl_s"] = ttl }
        if let turn { d["turn_id"] = turn }
        return .brain(obj(d))
    }

    private func clear(_ id: String) -> RunnerEvent { .brain(obj(["type": "nudge_clear", "id": id])) }

    private func kindName(_ s: OverlayState, prompter: Bool = false) -> String {
        switch IslandKind.resolve(s, prompterOpen: prompter) {
        case .nudge: return "nudge"
        case .card: return "card"
        case .startup: return "startup"
        case .topics: return "topics"
        case .capsule: return "capsule"
        case .statusPanel: return "status"
        case .prompter: return "prompter"
        case .sim: return "sim"
        case .prompt: return "prompt"
        }
    }

    func testSetAndNoExpiryAfterAnyNumberOfTicks() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge(ttl: 10, turn: "r41"))
        XCTAssertEqual(m.state.nudge?.id, "n001")
        XCTAssertEqual(m.state.nudge?.title, "Pay story")
        XCTAssertEqual(m.state.nudge?.lines, ["Lead with the range.", "Then the reason."])
        XCTAssertEqual(m.state.nudge?.turnID, "r41")
        XCTAssertEqual(m.state.nudge?.pointText, "Lead with the range. Then the reason.", "the lines joined into one point")
        XCTAssertEqual(kindName(m.state), "nudge", "no card open: the nudge is the body")
        for _ in 0..<200 {
            c.t += 5
            m.tick()
        }
        XCTAssertEqual(m.state.nudge?.id, "n001", "ttl_s is ignored: 1000 s and 200 ticks later it is still there")
        m.apply(nudge(ttl: "soon", turn: 41))
        XCTAssertEqual(m.state.nudge?.turnID, "41", "a wrong-typed ttl and a numeric turn id are tolerated")
    }

    func testANewerNudgeReplacesTheOldOne() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge("n001", turn: "r41"))
        m.apply(nudge("n002", title: "Notice period", lines: ["Four weeks."], turn: "r43"))
        XCTAssertEqual(m.state.nudge?.id, "n002")
        XCTAssertEqual(m.state.nudge?.lines, ["Four weeks."])
        m.apply(clear("n001"))
        XCTAssertEqual(m.state.nudge?.id, "n002", "the old one's clear does not take down the new one")
    }

    func testTheSameTurnsCardKeepsItBeforeOrAfterTheNudge() {
        let c = Clock()
        let m = model(c)
        // The nudge first, then the card for the sentence that triggered it.
        m.apply(nudge(turn: "r1"))
        m.apply(turn("r1", "What salary are you looking for?"))
        XCTAssertEqual(m.state.nudge?.id, "n001", "the card for the nudge's own turn keeps it")
        // The card first, then the nudge for the same turn.
        m.apply(turn("r2", "And the notice period?"))
        XCTAssertNil(m.state.nudge, "a card for a later turn takes it down")
        m.apply(nudge("n002", turn: "r2"))
        XCTAssertEqual(m.state.nudge?.id, "n002", "a nudge for the open card's turn shows on it")
        XCTAssertEqual(kindName(m.state), "card")
    }

    func testALaterTurnsCardRemovesIt() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "What salary are you looking for?"))
        m.apply(nudge(turn: "r1"))
        m.apply(turn("r2", "And when could you start?"))
        XCTAssertNil(m.state.nudge, "the first card for a later turn removes it")

        m.apply(nudge("n003", turn: nil))
        XCTAssertNotNil(m.state.nudge)
        m.apply(turn("r3", "Anything else?"))
        XCTAssertNil(m.state.nudge, "no turn_id: any card for a new turn is later")
    }

    func testTurnOrderForTheNudgeRule() {
        func n(_ t: String?) -> OverlayNudge { OverlayNudge(id: "x", title: "", lines: ["a"], turnID: t) }
        XCTAssertFalse(n("r41").isOutdated(byCardFor: "r41"), "same turn")
        XCTAssertTrue(n("r41").isOutdated(byCardFor: "r42"), "later turn")
        XCTAssertFalse(n("r42").isOutdated(byCardFor: "r41"), "a late card for an older turn keeps it")
        XCTAssertFalse(n("41").isOutdated(byCardFor: "r41"), "a bare number names the same count")
        XCTAssertTrue(n("41").isOutdated(byCardFor: "r42"))
        XCTAssertTrue(n("m5").isOutdated(byCardFor: "r6"), "different speakers cannot be ordered: the card that opens after is later")
        XCTAssertTrue(n(nil).isOutdated(byCardFor: "r1"), "no turn id: any new card is later")
    }

    func testATierUpgradeAndARegenerateKeepIt() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "What salary are you looking for?"))
        m.apply(nudge(turn: "r1"))
        for e in stream("f0001", "r1", "F", "SAY: Somewhere in the posted range.") { m.apply(e) }
        for e in stream("s0001", "r1", "S", "SAY: The posted range works for me.") { m.apply(e) }
        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0001"])))
        for e in stream("d0001", "r1", "D", "- Mention the equity question later.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "The posted range works for me.", "the S answer replaced F")
        XCTAssertEqual(m.state.nudge?.id, "n001", "F, S and D of the same turn keep the nudge")

        // Regenerate: the brain announces the new turn, then its first delta opens the card.
        m.apply(.brain(obj(["type": "metric", "stage": "regenerate", "turn_id": "now-1", "of": "r1",
                            "question": "What salary are you looking for?"])))
        for e in stream("f0002", "now-1", "F", "SAY: Within the posted range.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "now-1", "the regenerated card is on screen")
        XCTAssertEqual(m.state.nudge?.id, "n001", "a regenerate keeps the nudge")

        // A plain card-now answer is for the newest remote turn, the nudge's own here.
        for e in stream("f0003", "now-2", "F", "SAY: Happy to talk numbers.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "now-2")
        XCTAssertEqual(m.state.nudge?.id, "n001", "a card-now answer for the nudge's turn keeps it")
    }

    func testTapOnTheAmberPointDismissesOnlyTheNudge() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "What salary are you looking for?"))
        for e in stream("f0001", "r1", "F", "SAY: Somewhere in the posted range.") { m.apply(e) }
        for e in stream("f0001", "r1", "F", "- Mention the band.") { m.apply(e) }
        m.apply(nudge(turn: "r1"))
        guard let card = m.state.card, let n = m.state.nudge else { return XCTFail("a card and a nudge") }
        // The card view hands the amber point the model's dismiss (the view's own tap gesture is not driven here).
        let view = CardView(card: card, scale: 1, maxHeight: nil, nudge: n, onDismissNudge: { m.dismissNudge() })
        let point = PointList(points: card.bullets, scale: 1, nudge: n.pointText, onDismissNudge: view.onDismissNudge)
        XCTAssertEqual(point.nudge, "Lead with the range. Then the reason.")
        point.onDismissNudge()
        XCTAssertNil(m.state.nudge, "the tap dismisses the nudge")
        XCTAssertEqual(m.state.card?.say, "Somewhere in the posted range.", "and only the nudge")
        XCTAssertEqual(m.state.card?.bullets, ["Mention the band."], "the card's own points are untouched")
    }

    func testNudgeClearTakesDownOnlyTheNudgeItNames() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge("n002"))
        m.apply(clear("n001"))
        XCTAssertEqual(m.state.nudge?.id, "n002", "a clear for another nudge changes nothing")
        m.apply(.brain(obj(["type": "nudge_clear"])))
        XCTAssertNotNil(m.state.nudge, "a clear without an id changes nothing")
        m.apply(clear("n002"))
        XCTAssertNil(m.state.nudge)
    }

    func testANewCardKeepsTheNudgeAndItStaysOutOfTheCard() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge(turn: "r1"))
        m.apply(turn("r1", "What salary are you looking for?"))
        for e in stream("f0001", "r1", "F", "SAY: Somewhere in the posted range.") { m.apply(e) }
        XCTAssertEqual(m.state.nudge?.id, "n001", "the pay question is exactly when the pay nudge matters")
        XCTAssertEqual(kindName(m.state), "card", "with a card open the nudge is its first point, not the body")
        XCTAssertEqual(m.state.card?.say, "Somewhere in the posted range.")
        XCTAssertEqual(m.state.card?.bullets, [], "nothing of the nudge enters the card")
        XCTAssertEqual(m.history.entries.map(\.card.turnID), ["r1"], "the history holds answers only")
        for entry in m.history.entries {
            XCTAssertFalse(entry.card.bullets.contains("Lead with the range."))
        }
    }

    func testTapAndCollapseClearTheNudge() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge())
        m.apply(turn("r1", "What salary are you looking for?"))
        for e in stream("f0001", "r1", "F", "SAY: Somewhere in the posted range.") { m.apply(e) }
        m.dismissNudge()
        XCTAssertNil(m.state.nudge, "a tap on the amber point dismisses the nudge")
        XCTAssertNotNil(m.state.card, "and only the nudge")

        m.apply(nudge("n002"))
        m.collapse()
        XCTAssertNil(m.state.nudge, "collapse clears it")
        XCTAssertNil(m.state.card)

        // No card: the first click on the band closes the nudge body only; the topic row under it stays.
        m.apply(.chip(obj(["type": "chip", "turn_id": "r3", "text": "ETA", "kind": "topic", "source_ref": ""])))
        m.apply(nudge("n003"))
        XCTAssertEqual(kindName(m.state), "nudge", "a nudge beats the topic row")
        m.collapse()
        XCTAssertNil(m.state.nudge)
        XCTAssertEqual(m.state.topics.map(\.text), ["ETA"])
    }

    func testEndedAndResetClearTheNudge() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge())
        m.apply(.ended(exitCode: 0))
        XCTAssertNil(m.state.nudge, "stop clears it")
        m.apply(nudge())
        XCTAssertNil(m.state.nudge, "a late nudge after the session ended is dropped")

        let m2 = model(c)
        m2.apply(nudge())
        XCTAssertNotNil(m2.state.nudge)
        m2.sessionStarting(lang: "en")   // reset
        XCTAssertNil(m2.state.nudge, "reset clears it")

        var r = OverlayReducer()
        r.sessionStarting(lang: "en")
        r.apply(nudge(), now: 1)
        XCTAssertNotNil(r.state.nudge)
        r.reset(lang: "en")
        XCTAssertNil(r.state.nudge)
    }

    func testDroppedUnderThePrompterSimulationAndAStatusPanel() {
        let c = Clock()
        let m = model(c)
        m.setPrompterOpen(true)
        m.apply(nudge())
        XCTAssertNil(m.state.nudge, "dropped while the prompter is open")
        m.setPrompterOpen(false)
        XCTAssertNil(m.state.nudge, "not kept for later")
        m.apply(nudge())
        XCTAssertNotNil(m.state.nudge)
        m.setPrompterOpen(true)
        XCTAssertNil(m.state.nudge, "opening the prompter takes it down")
        m.setPrompterOpen(false)

        m.apply(status("credit_exhausted", "No credit."))
        m.apply(nudge())
        XCTAssertNil(m.state.nudge, "dropped under a status panel")
        m.dismissStatus()
        m.apply(status("offline"))
        m.apply(nudge())
        XCTAssertNotNil(m.state.nudge, "\"No connection\" is a wing, not a panel")

        let s = OverlayModel(config: OverlayConfig(), bank: [:], clock: { c.t })
        s.simStarting(voice: "text", showCaption: false)
        s.apply(nudge())
        XCTAssertNil(s.state.nudge, "dropped during a practice interview")
    }

    func testAnEventWithoutUsableLinesIsIgnored() {
        let c = Clock()
        let m = model(c)
        m.apply(nudge(lines: nil))
        XCTAssertNil(m.state.nudge, "no lines")
        m.apply(nudge(lines: [String]()))
        XCTAssertNil(m.state.nudge, "empty lines")
        m.apply(nudge(lines: ["  ", ""]))
        XCTAssertNil(m.state.nudge, "blank lines")
        m.apply(nudge(lines: "not a list"))
        XCTAssertNil(m.state.nudge, "lines of the wrong type")

        m.apply(nudge("n009", title: nil, lines: ["One.", 7, "Two.", "Three.", "Four."], turn: nil))
        XCTAssertEqual(m.state.nudge?.title, "", "no title: empty")
        XCTAssertEqual(m.state.nudge?.lines, ["One.", "Two.", "Three."], "non-strings dropped, at most three lines")
        XCTAssertNil(m.state.nudge?.turnID)

        m.apply(.brain(obj(["type": "nudge", "lines": ["Only a line."], "unknown": ["x": 1]])))
        XCTAssertEqual(m.state.nudge?.id, "", "no id: still shown, unknown fields ignored")
    }
}
