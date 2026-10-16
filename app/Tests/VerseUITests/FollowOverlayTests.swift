import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// "Follow my answer", overlay side: the reducer turns the brain's `follow` / C deltas / `covered` lines into a card that
/// follows Alex, and leaves every card without them exactly as it was. The brain's lines are scripted JSON, as it writes them.
@MainActor
final class FollowOverlayTests: XCTestCase {

    /// One line of brain stdout, decoded the way the runner hands it to the overlay.
    private func line(_ json: String) -> RunnerEvent { .brain(JSONValue.decodeObject(json)!) }

    private func cDelta(_ card: String, _ text: String, done: Bool = true, turn: String = "r1") -> RunnerEvent {
        line(#"{"type":"delta","id":"c-\#(card)","card_id":"\#(card)","turn_id":"\#(turn)","tier":"C","text":\#(jsonString(text)),"line_done":\#(done)}"#)
    }

    private func jsonString(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [s], options: []), as: UTF8.self).dropFirst().dropLast().description
    }

    private func follow(_ card: String, turn: String = "r1", reason: String = "diverged") -> RunnerEvent {
        line(#"{"type":"follow","turn_id":"\#(turn)","reason":"\#(reason)","card_id":"\#(card)"}"#)
    }

    private func covered(_ card: String, _ point: Int, turn: String = "r1") -> RunnerEvent {
        line(#"{"type":"covered","turn_id":"\#(turn)","card_id":"\#(card)","point":\#(point)}"#)
    }

    /// A model with a question card r1 answered by F: SAY plus two points.
    private func modelWithCard() -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        m.apply(turn("r1", "What was the hardest project you worked on?"))
        for l in ["SAY: The hardest was Lantern, the invoice pipeline.", "- schema-validated extraction", "- low-confidence fields go to an operator"] {
            for e in stream("f0001", "r1", "F", l) { m.apply(e) }
        }
        return m
    }

    /// The follow card of a scripted brain: SAY continues his line, three points.
    private func playFollow(_ m: OverlayModel, card: String = "c1") {
        m.apply(follow(card))
        m.apply(cDelta(card, "SAY: And on the route optimiser I built the first pilot on my own."))
        m.apply(cDelta(card, "- 12 depots in the pilot"))
        m.apply(cDelta(card, "- ETA drift down by a third"))
        m.apply(cDelta(card, "- I wrote the re-plan loop"))
    }

    // MARK: follow

    func testFollowReplacesTheVisibleTextWithTheCDeltas() throws {
        let m = modelWithCard()
        var card = try XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "The hardest was Lantern, the invoice pipeline.")
        XCTAssertFalse(card.following)
        m.apply(.chip(obj(["type": "chip", "turn_id": "r1", "kind": "number", "text": "38,000 invoices a month", "source_ref": "prep:L13"])))

        playFollow(m)
        card = try XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "And on the route optimiser I built the first pilot on my own.")
        XCTAssertEqual(card.sayTier, "C")
        XCTAssertEqual(card.bullets, ["12 depots in the pilot", "ETA drift down by a third", "I wrote the re-plan loop"])
        XCTAssertTrue(card.following, "the \"following you\" mark")
        XCTAssertEqual(card.question, "What was the hardest project you worked on?")
        XCTAssertEqual(card.turnID, "r1")
        XCTAssertEqual(card.chips.count, 1, "the fact chips of the question stay")
        XCTAssertTrue(card.struck.isEmpty)
    }

    func testTheOriginalCardStaysUntilTheFollowCardHasASayLine() throws {
        let m = modelWithCard()
        m.apply(follow("c1"))
        var card = try XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "The hardest was Lantern, the invoice pipeline.", "no blank card between follow and the first C text")
        XCTAssertFalse(card.following)
        m.apply(cDelta("c1", "SAY:", done: false))
        XCTAssertFalse(try XCTUnwrap(m.state.card).following, "a bare SAY: prefix shows nothing yet")
        m.apply(cDelta("c1", " And then the route optimiser."))
        card = try XCTUnwrap(m.state.card)
        XCTAssertTrue(card.following)
        XCTAssertEqual(card.say, "And then the route optimiser.")
    }

    func testCTextThatArrivesBeforeTheFollowLineIsShownOnceItArrives() throws {
        let m = modelWithCard()
        m.apply(cDelta("c1", "SAY: Buffered sentence."))
        XCTAssertFalse(try XCTUnwrap(m.state.card).following, "a C delta alone does not switch the card")
        m.apply(follow("c1"))
        XCTAssertEqual(m.state.card?.say, "Buffered sentence.")
    }

    func testARefreshReplacesTheFollowCardWithoutFlickerBackToTheOriginal() throws {
        let m = modelWithCard()
        playFollow(m, card: "c1")
        m.apply(covered("c1", 0))
        m.apply(follow("c2", reason: "refresh"))
        XCTAssertEqual(m.state.card?.sayTier, "C", "c2 has no text yet: c1 stays, the original does not come back")
        XCTAssertEqual(m.state.card?.say, "And on the route optimiser I built the first pilot on my own.")
        XCTAssertEqual(m.state.card?.struck, [0])
        m.apply(cDelta("c2", "SAY: Next I tuned the re-plan interval."))
        m.apply(cDelta("c2", "- every 90 seconds"))
        let card = try XCTUnwrap(m.state.card)
        XCTAssertEqual(card.say, "Next I tuned the re-plan interval.")
        XCTAssertEqual(card.bullets, ["every 90 seconds"])
        XCTAssertTrue(card.struck.isEmpty, "covered belongs to a card id: the new card starts clean")
        XCTAssertTrue(card.following)
    }

    // MARK: covered

    func testCoveredStrikesThroughThatPointOfThatCard() throws {
        let m = modelWithCard()
        playFollow(m)
        m.apply(covered("c1", 1))
        XCTAssertEqual(m.state.card?.struck, [1])
        m.apply(covered("c1", 0))
        XCTAssertEqual(m.state.card?.struck, [0, 1])
        m.apply(covered("c1", 1))   // twice: still one strike
        XCTAssertEqual(m.state.card?.struck, [0, 1])
        m.apply(covered("c1", 9))   // beyond the points on the card: nothing to strike
        XCTAssertEqual(m.state.card?.struck, [0, 1])
        XCTAssertEqual(m.state.card?.bullets.count, 3, "a struck point stays on the card")
    }

    func testCoveredPointsOfTheOriginalCardAreStruckBeforeAndKeptAfterFollowing() throws {
        let m = modelWithCard()
        // The brain checks the original card against his speech too (its card id is the brain's, not a follow card's).
        m.apply(covered("f0001", 0))
        XCTAssertEqual(m.state.card?.struck, [0])
        XCTAssertFalse(try XCTUnwrap(m.state.card).following)
        playFollow(m)
        XCTAssertTrue(try XCTUnwrap(m.state.card).struck.isEmpty, "the follow card is a different card")
        // Back on the original card: his words match its second point. It is marked covered, the card does not switch back.
        m.apply(covered("f0001", 1))
        let card = try XCTUnwrap(m.state.card)
        XCTAssertTrue(card.following)
        XCTAssertEqual(card.sayTier, "C")
        XCTAssertTrue(card.struck.isEmpty)
    }

    // MARK: reset

    func testANewRemoteQuestionResetsTheFollowState() throws {
        let m = modelWithCard()
        playFollow(m)
        m.apply(covered("c1", 0))
        XCTAssertEqual(m.state.card?.struck, [0])

        m.apply(turn("r2", "And how did you test it?"))
        var card = try XCTUnwrap(m.state.card)
        XCTAssertEqual(card.turnID, "r2")
        XCTAssertFalse(card.following)
        XCTAssertTrue(card.struck.isEmpty)
        XCTAssertNil(card.say)

        // Late lines for the earlier question change nothing on the new card.
        m.apply(follow("c9", turn: "r1"))
        m.apply(cDelta("c9", "SAY: A late follow card of the old question.", turn: "r1"))
        m.apply(covered("c1", 1, turn: "r1"))
        card = try XCTUnwrap(m.state.card)
        XCTAssertFalse(card.following)
        XCTAssertNil(card.say)
        XCTAssertTrue(card.struck.isEmpty)

        // The new question's own answer arrives as always.
        for e in stream("f0002", "r2", "F", "SAY: I tested it against recorded routes.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "I tested it against recorded routes.")
        XCTAssertEqual(m.state.card?.sayTier, "F")
    }

    func testTheSessionEndingClearsTheFollowCard() {
        let m = modelWithCard()
        playFollow(m)
        m.apply(.ended(exitCode: 0))
        XCTAssertNil(m.state.card)
    }

    // MARK: cards without follow

    /// Cards that never see a follow line behave exactly as before, whatever else the brain adds: unknown message types and
    /// unknown fields are ignored, and a C delta the brain never announced with `follow` changes nothing.
    func testCardsWithoutFollowBehaveExactlyAsBefore() {
        func script(noise: Bool) -> [RunnerEvent] {
            var ev: [RunnerEvent] = [turn("r1", "What was the hardest project you worked on?")]
            ev += stream("f0001", "r1", "F", "SAY: The hardest was Lantern, the invoice pipeline.")
            if noise {
                ev.append(line(#"{"type":"metric","turn_id":"r1","stage":"follow_diverged","lex":0.1,"embed":0.2,"words":5,"ms":1300}"#))
                ev.append(line(#"{"type":"future_message","turn_id":"r1","card_id":"x9","anything":[1,2,3]}"#))
                ev.append(line(#"{"type":"delta","id":"f0001","turn_id":"r1","tier":"F","text":"","line_done":false,"card_id":"f0001","extra":{"a":1}}"#))
                ev.append(cDelta("c7", "SAY: Never announced, so never shown."))
                ev.append(line(#"{"type":"follow","turn_id":"r1","reason":"diverged"}"#))                  // no card_id
                ev.append(line(#"{"type":"covered","turn_id":"r1","card_id":"f0001"}"#))                   // no point
                ev.append(line(#"{"type":"covered","turn_id":"r1","card_id":"f0001","point":-1}"#))
            }
            ev += stream("f0001", "r1", "F", "- schema-validated extraction")
            ev += stream("d0002", "r1", "D", "SAY: detail one")
            ev.append(.chip(obj(["type": "chip", "turn_id": "r1", "kind": "term", "text": "Lantern", "source_ref": ""])))
            return ev
        }
        func final(noise: Bool) -> OverlayState {
            let m = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
            m.sessionStarting(lang: "en")
            for e in script(noise: noise) { m.apply(e) }
            return m.state
        }
        let plain = final(noise: false)
        XCTAssertEqual(final(noise: true), plain)
        XCTAssertEqual(plain.card?.say, "The hardest was Lantern, the invoice pipeline.")
        XCTAssertEqual(plain.card?.bullets, ["schema-validated extraction"])
        XCTAssertEqual(plain.card?.deepPoints, ["detail one"])
        XCTAssertEqual(plain.card?.following, false)
        XCTAssertEqual(plain.card?.struck, [])
    }

    func testTheFollowCardDropsTheOriginalDeepPoints() throws {
        let m = modelWithCard()
        for e in stream("d0002", "r1", "D", "SAY: detail one") { m.apply(e) }
        XCTAssertEqual(m.state.card?.deepPoints, ["detail one"])
        playFollow(m)
        XCTAssertEqual(m.state.card?.deepPoints, [], "Sonnet's points answer the original question, not his line")
    }
}
