import Foundation
import VerseSpeech
import VerseTurns
import XCTest
@testable import VerseTurns

/// V2: sentinel lines never render (bug 1) and a bank hit of the brain's paraphrase matcher keeps topic chips away (bug 3).
final class TurnFixesTests: XCTestCase {

    // MARK: bug 1 - sentinel rule (mirror of brain/verse_brain/runtime/lines.py)

    func testSentinelLines() {
        for s in ["NONE", "none", "None.", "SAY: NONE", "SAY: none.", "- NONE", "- None", "N/A", "SAY: N/A", "(none)", "[NONE]",
                  "SKIP", "  none  ", "SAY:  NONE ", "`none`", "null", "\u{2022} None"] {
            XCTAssertTrue(ModelLine.isSentinel(s), s)
        }
        for s in ["None of my projects failed.", "SAY: None of that was my call.", "- No, we kept it simple.", "SAY: No problem at all.",
                  "Skip the slides, I'll explain.", "SAY: Sure, go ahead.", "- Nothing blocked us.", "", "SAY:", "-",
                  "I handled none of the billing."] {
            XCTAssertFalse(ModelLine.isSentinel(s), s)
        }
    }

    // MARK: bug 3 - the engine and the brain's paraphrase hit

    static let bank = TopicTriggerTests.bank

    private func topicChips(_ events: [TurnEngine.Timed]) -> [String] {
        events.chips.filter { $0.kind == "topic" }.map(\.factID)
    }

    /// Two events of one utterance, then time moves past the endpoint.
    private func say(_ engine: TurnEngine, _ text: String, at t: Double, noteHitAfterFirst: Bool = false) async -> [TurnEngine.Timed] {
        var out = await engine.ingestTimed(ev(text, at: t, start: t - 1, end: t))
        if noteHitAfterFirst { await engine.noteBrainBankHit(turnID: "r1") }
        out += await engine.ingestTimed(ev(text, at: t + 0.1, start: t - 1, end: t + 0.1))
        out += await engine.advance(to: t + 1.5)
        return out
    }

    func testBrainHitStopsTopicChipsOfTheOpenTurn() async {
        // The turn starts without a topic, then drifts onto one. Control: the chip comes.
        let first = "so we were just talking about how we plan the work"
        let second = "so we were just talking about the invoice extraction pipeline went live last quarter"
        let control = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var c = await control.ingestTimed(ev(first, at: 1.0, start: 0, end: 1.0))
        c += await control.ingestTimed(ev(second, at: 1.2, start: 0, end: 1.2))
        XCTAssertEqual(topicChips(c), ["t001"], "control: without a brain hit the topic chip comes")

        // The brain's paraphrase matcher hit this turn in between: no chip, and the turn does not stay in the window.
        let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
        var out = await engine.ingestTimed(ev(first, at: 1.0, start: 0, end: 1.0))
        await engine.noteBrainBankHit(turnID: "r1")
        out += await engine.ingestTimed(ev(second, at: 1.2, start: 0, end: 1.2))
        out += await engine.advance(to: 3.0)
        XCTAssertTrue(topicChips(out).isEmpty, "\(topicChips(out))")
    }

    func testBrainHitAfterTheTurnClosedTakesItOutOfTheTopicWindow() async {
        // r0 uses the chip slot (one per 12 s). r1 is a topic statement inside the cooldown: no chip of its own, but its
        // text stays in the window. Control: it comes back as a chip once r2 starts after the cooldown.
        func scenario(brainHitOnR1: Bool) async -> [String] {
            let engine = TurnEngine(config: TurnConfig(), bank: Self.bank, facts: .empty)
            var out = await say(engine, "our notice period is two months for engineers", at: 1.0)
            out += await say(engine, "so the invoice extraction pipeline went live last quarter", at: 8.0)
            if brainHitOnR1 { await engine.noteBrainBankHit(turnID: "r2") }
            out += await say(engine, "okay let me share my screen so you can see the numbers for this quarter", at: 14.0)
            return topicChips(out)
        }
        let control = await scenario(brainHitOnR1: false)
        XCTAssertEqual(control, ["t004", "t001"], "control: r1's text comes back at r2 after the cooldown")
        let fixed = await scenario(brainHitOnR1: true)
        XCTAssertEqual(fixed, ["t004"], "a turn the brain hit is not a topic later either")
    }
}
