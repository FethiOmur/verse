import Foundation
import VerseTurns
import VerseUI
import XCTest

/// A JSON object as the runner hands it over.
func obj(_ d: [String: Any]) -> [String: JSONValue] {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    return JSONValue.decodeObject(String(decoding: data, as: UTF8.self))!
}

func turn(_ id: String, _ text: String, addressee: String = "me", kind: String = "question", speaker: String = "remote") -> RunnerEvent {
    .outbound(obj(["type": "turn", "turn_id": id, "speaker": speaker, "text": text, "addressee": addressee, "kind": kind,
                   "t_audio_end": 1.0, "dir": "to_brain"]))
}

func delta(_ id: String, _ tid: String, _ tier: String, _ text: String, done: Bool = false) -> RunnerEvent {
    .brain(obj(["type": "delta", "id": id, "turn_id": tid, "tier": tier, "text": text, "line_done": done]))
}

/// Streams `line` word by word like the brain does, the last chunk with line_done.
func stream(_ id: String, _ tid: String, _ tier: String, _ line: String) -> [RunnerEvent] {
    let words = line.split(separator: " ").map(String.init)
    return words.enumerated().map { i, w in delta(id, tid, tier, (i == 0 ? "" : " ") + w, done: i == words.count - 1) }
}

func status(_ st: String, _ msg: String = "") -> RunnerEvent {
    .brain(obj(["type": "status", "state": st, "message": msg]))
}

final class Clock: @unchecked Sendable {
    var t: TimeInterval = 1000
}

@MainActor
final class OverlayModelTests: XCTestCase {
    private let bank = ["b001": BankOpener(opener: "Sure, I'll give you the short version.", points: ["I led Lantern.", "Entry fell to 2 minutes.", "Route optimiser pilot."])]

    private func model(_ clock: Clock, timeout: TimeInterval = 45, others: [String] = []) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(cardTimeout: timeout, otherNames: others), bank: bank, clock: { clock.t })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    func testOverlayQuestionCard() {
        let c = Clock()
        let m = model(c)
        XCTAssertEqual(m.state.activity, .listening)
        // bank hit during the partials, then the turn
        m.apply(.outbound(obj(["type": "bank_hit", "turn_id": "r1", "bank_id": "b001", "score": 0.81, "dir": "to_brain"])))
        XCTAssertNil(m.state.card, "no card before the turn")
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertEqual(m.state.card?.say, "Sure, I'll give you the short version.", "P opener first")
        XCTAssertEqual(m.state.card?.sayTier, "P")
        XCTAssertEqual(m.state.capsuleTag, "en · for you")

        // an unselected S never shows
        for e in stream("s0001", "r1", "S", "SAY: Wrong speculative answer") { m.apply(e) }
        XCTAssertEqual(m.state.card?.sayTier, "P")

        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0003"])))
        m.apply(delta("s0003", "r1", "S", "SAY:"))
        XCTAssertEqual(m.state.card?.sayTier, "P", "a bare SAY: prefix does not replace the opener yet")
        m.apply(delta("s0003", "r1", "S", " In my last role"))
        XCTAssertEqual(m.state.card?.say, "In my last role")
        m.apply(delta("s0003", "r1", "S", " I built that pipeline.", done: true))
        for e in stream("s0003", "r1", "S", "- schema-validated extraction") { m.apply(e) }
        for e in stream("s0003", "r1", "S", "- low-confidence fields go to an operator") { m.apply(e) }
        // F does not replace a selected S
        for e in stream("f0004", "r1", "F", "SAY: F answer") { m.apply(e) }

        let card = try! XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "In my last role I built that pipeline.")
        XCTAssertEqual(card.sayTier, "S")
        XCTAssertEqual(card.bullets, ["schema-validated extraction", "low-confidence fields go to an operator"])
        XCTAssertFalse(card.sayCorrected)

        // chips dedupe by text
        let chip = RunnerEvent.chip(obj(["type": "chip", "turn_id": "r1", "kind": "number", "text": "€42K budget", "source_ref": "prep:L7", "fact_id": "f002"]))
        m.apply(chip)
        m.apply(chip)
        XCTAssertEqual(m.state.card?.chips, [OverlayChip(text: "€42K budget", source: "prep note", kind: "number")])
        XCTAssertEqual(m.state.activity, .listening)
    }

    func testOverlayFOnlyWithoutSelect() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "What results did Lantern deliver?"))
        XCTAssertEqual(m.state.activity, .thinking)
        for e in stream("f0002", "r1", "F", "SAY: Entry went from 11 to 2 minutes.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "Entry went from 11 to 2 minutes.")
        XCTAssertEqual(m.state.card?.sayTier, "F")
    }

    func testOverlayOpenerWrong() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "How do you handle bad invoices?"))
        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0001"])))
        for e in stream("s0001", "r1", "S", "SAY: We rejected bad invoices.") { m.apply(e) }
        for e in stream("s0001", "r1", "S", "- point one") { m.apply(e) }
        m.apply(.brain(obj(["type": "opener_status", "turn_id": "r1", "ok": false])))
        for e in stream("d0002", "r1", "D", "- Lantern flagged invoices instead of rejecting them.") { m.apply(e) }
        for e in stream("d0002", "r1", "D", "- Flagged fields carried a confidence score (prep:L14)") { m.apply(e) }
        let card = try! XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "Lantern flagged invoices instead of rejecting them.")
        XCTAssertTrue(card.sayCorrected)
        XCTAssertEqual(card.sayTier, "D")
        XCTAssertEqual(card.deepPoints, ["Flagged fields carried a confidence score (prep:L14)"])
        XCTAssertEqual(card.bullets, ["point one"])

        // OPENER_OK: D only appends under the divider
        m.apply(turn("r2", "And what about the route optimiser?"))
        m.apply(.brain(obj(["type": "select", "turn_id": "r2", "id": "s0003"])))
        for e in stream("s0003", "r2", "S", "SAY: It cut empty runs by 14 percent.") { m.apply(e) }
        m.apply(.brain(obj(["type": "opener_status", "turn_id": "r2", "ok": true])))
        for e in stream("d0004", "r2", "D", "- 23 vans over 10 weeks in Milan (prep:L16)") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "r2", "a new question replaces the previous card")
        XCTAssertEqual(m.state.card?.say, "It cut empty runs by 14 percent.")
        XCTAssertFalse(m.state.card?.sayCorrected ?? true)
        XCTAssertEqual(m.state.card?.deepPoints, ["23 vans over 10 weeks in Milan (prep:L16)"])
    }

    func testOverlayAddresseeOther() {
        let c = Clock()
        let m = model(c, others: ["Marco"])
        m.apply(turn("r1", "Marco, can you share the budget numbers?", addressee: "other"))
        XCTAssertNil(m.state.card)
        XCTAssertEqual(m.state.addresseeTag, "for Marco")
        XCTAssertTrue(m.state.tagDimmed)
        XCTAssertEqual(m.state.capsuleTag, "en · for Marco")
        // and its brain output (none expected) or a stray S line never makes a SAY line
        for e in stream("s0001", "r1", "S", "SAY: should not show") { m.apply(e) }
        XCTAssertNil(m.state.card)

        // fragments and statements open no card either
        m.apply(turn("r2", "So the thing is", kind: "fragment"))
        m.apply(turn("r3", "We use Postgres for that.", kind: "statement"))
        XCTAssertNil(m.state.card)
    }

    /// The brain reclassified a `statement` turn as a question: its S/F stream carries a SAY line, so the card opens
    /// on the first delta that has one.
    func testOverlayStatementReclassifiedByBrain() throws {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "So you have run Postgres at that scale.", kind: "statement"))
        XCTAssertNil(m.state.card, "a statement opens no card on its own")

        // a non-SAY line from the brain does not open it
        for e in stream("s0001", "r1", "S", "- just a note") { m.apply(e) }
        XCTAssertNil(m.state.card)

        // the first delta that completes a SAY prefix opens the card
        m.apply(delta("s0002", "r1", "S", "SA"))
        XCTAssertNil(m.state.card, "a partial prefix is not a SAY line yet")
        m.apply(delta("s0002", "r1", "S", "Y:"))
        let opened = try XCTUnwrap(m.state.card, "card opens on the first delta with a SAY line")
        XCTAssertEqual(opened.turnID, "r1")
        XCTAssertEqual(opened.question, "So you have run Postgres at that scale.")
        XCTAssertEqual(m.state.addresseeTag, "for you")
        XCTAssertEqual(m.state.activity, .thinking)

        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0002"])))
        m.apply(delta("s0002", "r1", "S", " Yes, about 2 TB on one primary.", done: true))
        XCTAssertEqual(m.state.card?.say, "Yes, about 2 TB on one primary.")
        XCTAssertEqual(m.state.card?.sayTier, "S")
        XCTAssertEqual(m.state.activity, .listening)

        // F works the same way; D (deep) alone never opens a card
        m.apply(turn("r2", "And that was the hard part.", kind: "statement"))
        for e in stream("d0003", "r2", "D", "SAY: deep only") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "r1", "a D stream does not open a card for a statement")
        for e in stream("f0004", "r2", "F", "SAY: It was the migration window.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "r2")
        XCTAssertEqual(m.state.card?.say, "It was the migration window.")

        // a late SAY for an older statement does not take over the card of a newer turn
        m.apply(turn("r3", "We also use Redis.", kind: "statement"))
        m.apply(turn("r4", "What did you cache in Redis?"))
        for e in stream("f0005", "r3", "F", "SAY: stale answer") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "r4")

        // a statement for someone else stays closed whatever the brain streams
        let m2 = model(Clock(), others: ["Marco"])
        m2.apply(turn("r9", "Marco handled the Postgres side.", addressee: "other", kind: "statement"))
        for e in stream("f0009", "r9", "F", "SAY: should not show") { m2.apply(e) }
        XCTAssertNil(m2.state.card)
    }

    func testOverlayStatusChips() {
        let c = Clock()
        let m = model(c)
        m.apply(status("offline", "network unreachable"))
        XCTAssertEqual(m.state.status, .offline)
        XCTAssertEqual(m.state.status?.shortTitle, "Offline")
        XCTAssertEqual(m.state.activity, .offline)
        m.apply(status("ready"))
        XCTAssertNil(m.state.status, "back online clears the chip")
        XCTAssertEqual(m.state.activity, .listening)

        m.apply(status("credit_exhausted", "Credit used up until 1 December"))
        XCTAssertEqual(m.state.status, .creditExhausted("Credit used up until 1 December"))
        XCTAssertEqual(m.state.status?.title, "Max API credit used up")
        XCTAssertEqual(m.state.status?.detail, "Credit used up until 1 December")
        XCTAssertTrue(m.state.status?.needsPanel ?? false)

        m.apply(.status(state: "restarting", message: "brain process ended unexpectedly; restarting"))
        XCTAssertEqual(m.state.status, .restarting)
        XCTAssertEqual(m.state.status?.shortTitle, "Restarting")

        m.apply(status("refusal"))
        XCTAssertEqual(m.state.status, .restarting, "a refusal shows nothing")

        m.apply(.status(state: "permission_denied", message: "microphone"))
        XCTAssertEqual(m.state.status, .permission("microphone"))
        XCTAssertEqual(m.state.status?.title, "Microphone access needed")
        XCTAssertEqual(SystemSettingsLink.url(permission: "microphone").absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

        m.apply(.status(state: "error", message: "brain process ended unexpectedly again"))
        XCTAssertEqual(m.state.status, .error("brain process ended unexpectedly again"))
        m.apply(.ended(exitCode: 1))
        XCTAssertFalse(m.state.running)
        XCTAssertEqual(m.state.status, .error("brain process ended unexpectedly again"), "the error stays readable after the end")
    }

    func testOverlayTimeout() {
        let c = Clock()
        let m = model(c, timeout: 45)
        m.apply(turn("r1", "Can you tell me about yourself?"))
        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0001"])))
        for e in stream("s0001", "r1", "S", "SAY: Short version first.") { m.apply(e) }
        c.t += 30
        for e in stream("d0002", "r1", "D", "- a detail point") { m.apply(e) }   // new content resets the clock
        c.t += 40
        m.tick()
        XCTAssertNotNil(m.state.card, "40 s after the last content: still shown")
        c.t += 6
        m.tick()
        XCTAssertNil(m.state.card, "45 s without new content: collapsed to the capsule")
        XCTAssertTrue(m.state.running)
    }

    func testOverlayTopicChipWithoutCard() {
        let c = Clock()
        let m = model(c, timeout: 45)
        func topic(_ tid: String, _ text: String) -> RunnerEvent {
            .chip(obj(["type": "chip", "turn_id": tid, "kind": "topic", "text": text, "source_ref": "glossary:g001", "fact_id": "g001"]))
        }
        m.apply(topic("r1", "ETA drift"))
        m.apply(topic("r1", "ETA drift"))
        c.t += 20
        m.apply(topic("r2", "Compass"))
        XCTAssertNil(m.state.card, "a topic opens no question card")
        XCTAssertEqual(m.state.topics.map(\.text), ["ETA drift", "Compass"], "deduped by text, in order")
        c.t += 26
        m.tick()
        XCTAssertEqual(m.state.topics.map(\.text), ["Compass"], "ETA drift is 46 s old: dropped")
        c.t += 20
        m.tick()
        XCTAssertTrue(m.state.topics.isEmpty)

        // with a card open for the same turn, a topic chip joins the card's chips instead
        m.apply(turn("r3", "How does Compass re-plan routes?"))
        m.apply(topic("r3", "Compass"))
        XCTAssertEqual(m.state.card?.chips.map(\.text), ["Compass"])
        XCTAssertTrue(m.state.topics.isEmpty)
    }

    func testChipSourceLabels() {
        let c = Clock()
        let m = model(c)
        m.apply(turn("r1", "What's ARGO?"))
        m.apply(.chip(obj(["type": "chip", "turn_id": "r1", "kind": "term", "text": "ARGO", "source_ref": "prep:L9", "fact_id": "g1"])))
        m.apply(.chip(obj(["type": "chip", "turn_id": "r1", "kind": "date", "text": "22 October", "source_ref": "vault:notes/x.md", "fact_id": "f1"])))
        XCTAssertEqual(m.state.card?.chips.map(\.source), ["glossary", "vault"])
    }

    // MARK: F3 paraphrase hits from the brain (`bank_hit` with `via:"embed"`, a brain line, not an outbound one)

    private func embedHit(_ tid: String, _ bid: String, score: Double = 0.88) -> RunnerEvent {
        .brain(obj(["type": "bank_hit", "turn_id": tid, "bank_id": bid, "score": score, "via": "embed"]))
    }

    private func verdict(_ tid: String, _ bid: String, agree: Bool) -> RunnerEvent {
        .brain(obj(["type": "bank_verdict", "turn_id": tid, "bank_id": bid, "agree": agree]))
    }

    func testEmbedBankHitShowsOpener() {
        let c = Clock()
        let m = model(c)
        // before the turn (while the question is spoken): shown once the card opens
        m.apply(embedHit("r1", "b001"))
        XCTAssertNil(m.state.card)
        m.apply(turn("r1", "How did you end up where you are today?"))
        XCTAssertEqual(m.state.card?.say, "Sure, I'll give you the short version.")
        XCTAssertEqual(m.state.card?.sayTier, "P")
        XCTAssertEqual(m.state.card?.bullets, ["I led Lantern.", "Entry fell to 2 minutes.", "Route optimiser pilot."])
        // after the turn (card already open): shown at once
        m.apply(turn("r2", "Tell us who you are and what you have done so far?"))
        XCTAssertNil(m.state.card?.say)
        m.apply(embedHit("r2", "b001"))
        XCTAssertEqual(m.state.card?.say, "Sure, I'll give you the short version.")
        XCTAssertEqual(m.state.card?.sayTier, "P")
        // Haiku agreeing changes nothing
        m.apply(verdict("r2", "b001", agree: true))
        XCTAssertEqual(m.state.card?.sayTier, "P")
    }

    func testEmbedBankVerdictDisagreeRemovesOpener() {
        let c = Clock()
        let m = model(c)
        m.bank["b002"] = BankOpener(opener: "What stands out to me is the product direction.", points: ["Halden point."])
        m.apply(embedHit("r1", "b001"))
        m.apply(turn("r1", "What would a former manager say you need to work on?"))
        XCTAssertEqual(m.state.card?.sayTier, "P")
        m.apply(verdict("r1", "b001", agree: false))
        XCTAssertNil(m.state.card?.say, "the retracted opener is gone")
        XCTAssertNil(m.state.card?.sayTier)
        XCTAssertEqual(m.state.card?.bullets, [], "its points go with it")
        // the same id again does not come back; another entry for the turn (e.g. Swift's n-gram) still shows
        m.apply(embedHit("r1", "b001"))
        XCTAssertNil(m.state.card?.say)
        m.apply(.outbound(obj(["type": "bank_hit", "turn_id": "r1", "bank_id": "b002", "score": 0.7, "dir": "to_brain"])))
        XCTAssertEqual(m.state.card?.say, "What stands out to me is the product direction.")
        // the fast tier's own SAY line replaces the opener as before
        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0001"])))
        for e in stream("s0001", "r1", "S", "SAY: Probably that I polish prototypes too long.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.sayTier, "S")
    }

    func testSwiftBankVerdictDisagreeStillRemovesOpener() {
        let c = Clock()
        let m = model(c)
        m.apply(.outbound(obj(["type": "bank_hit", "turn_id": "r1", "bank_id": "b001", "score": 0.7, "dir": "to_brain"])))
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertEqual(m.state.card?.sayTier, "P")
        m.apply(verdict("r1", "b001", agree: false))
        XCTAssertNil(m.state.card?.say)
    }
}
