import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Earlier answers in the notch: the history records the cards the reducer shows, Back and Forward move a pinned view over
/// it, and the live state (what the controller and the prompter read) never changes because of it.
@MainActor
final class AnswerHistoryTests: XCTestCase {

    // MARK: the pure model

    private func card(_ turn: String, say: String?, bullets: [String] = [], follow: String? = nil) -> OverlayCard {
        var c = OverlayCard(turnID: turn, question: "Question \(turn)?")
        c.say = say
        c.bullets = bullets
        if let follow {
            c.following = true
            c.followCardID = follow
        }
        return c
    }

    func testOneEntryPerCardAndStreamingUpdatesItInPlace() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "First"))
        h.observe(card("r1", say: "First answer"))
        h.observe(card("r1", say: "First answer", bullets: ["a point"]))
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertEqual(h.entries[0].card.say, "First answer")
        XCTAssertEqual(h.entries[0].card.bullets, ["a point"])
        h.observe(card("r2", say: "Second"))
        XCTAssertEqual(h.entries.map(\.key), ["r1", "r2"])
    }

    func testACardWithoutAnAnswerIsNotRecorded() {
        var h = AnswerHistory()
        h.observe(card("r1", say: nil))
        h.observe(nil)
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertFalse(h.canGoBack)
        h.back()
        XCTAssertFalse(h.isPinned, "nothing to go back to")
    }

    func testAFollowCardIsAnEntryOfItsOwnAndTheOriginalStays() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "Answer to the question"))
        h.observe(card("r1", say: "Continuation of my own line", follow: "c1"))
        XCTAssertEqual(h.entries.map(\.key), ["r1", "r1|C|c1"])
        XCTAssertEqual(h.entries[0].card.say, "Answer to the question", "the replaced answer keeps its text")
        h.back()
        XCTAssertEqual(h.pinned?.card.say, "Answer to the question")
    }

    func testBackFromLiveSkipsTheEntryThatIsOnScreen() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "One"))
        h.observe(card("r2", say: "Two"))
        h.observe(card("r3", say: "Three"))
        h.back()
        XCTAssertEqual(h.pinned?.key, "r2", "live shows r3 already")
        h.back()
        XCTAssertEqual(h.pinned?.key, "r1")
        XCTAssertFalse(h.canGoBack)
        h.back()
        XCTAssertEqual(h.pinned?.key, "r1", "at the oldest entry Back does nothing")
    }

    func testBackFromLiveWhileANewQuestionIsHeardShowsTheLastAnswer() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "One"))
        h.observe(card("r2", say: "Two"))
        // A filler opened a new card: only the heard question so far.
        h.observe(card("r3", say: nil))
        XCTAssertTrue(h.canGoBack)
        h.back()
        XCTAssertEqual(h.pinned?.key, "r2", "the answer that was just replaced")
        // The card was closed: the last answer is what Back shows too.
        h.returnToLive()
        h.observe(nil)
        h.back()
        XCTAssertEqual(h.pinned?.key, "r2")
    }

    func testForwardStepsNewerThenReturnsToLive() {
        var h = AnswerHistory()
        for t in ["r1", "r2", "r3"] { h.observe(card(t, say: t)) }
        h.back()
        h.back()
        XCTAssertEqual(h.pinned?.key, "r1")
        XCTAssertFalse(h.forwardReturnsToLive)
        h.forward()
        XCTAssertEqual(h.pinned?.key, "r2")
        XCTAssertTrue(h.forwardReturnsToLive, "the next one is the live card")
        h.forward()
        XCTAssertFalse(h.isPinned)
        XCTAssertFalse(h.canGoForward)
        h.forward()
        XCTAssertFalse(h.isPinned, "Forward while live does nothing")
    }

    func testForwardPastTheNewestReturnsToLiveWhenTheLiveCardIsNoAnswer() {
        var h = AnswerHistory()
        for t in ["r1", "r2"] { h.observe(card(t, say: t)) }
        h.observe(card("r3", say: nil))
        h.back()
        h.back()
        XCTAssertEqual(h.pinned?.key, "r1")
        h.forward()
        XCTAssertEqual(h.pinned?.key, "r2", "the newest entry is not on screen live, so it is a step of its own")
        h.forward()
        XCTAssertFalse(h.isPinned)
    }

    func testNewAnswersWhilePinnedKeepTheSameEntryOnScreen() {
        var h = AnswerHistory()
        for t in ["r1", "r2", "r3"] { h.observe(card(t, say: t)) }
        h.back()
        XCTAssertEqual(h.pinned?.key, "r2")
        XCTAssertFalse(h.hasNewerSincePin)
        h.observe(card("r4", say: nil))
        XCTAssertFalse(h.hasNewerSincePin, "a question without an answer is not a newer answer")
        h.observe(card("r4", say: "Four"))
        h.observe(card("r5", say: "Five"))
        XCTAssertEqual(h.pinned?.key, "r2", "the same entry, not two steps back of a moving list")
        XCTAssertTrue(h.isPinned, "no return to live on a new answer")
        XCTAssertTrue(h.hasNewerSincePin)
        XCTAssertEqual(h.entries.map(\.key), ["r1", "r2", "r3", "r4", "r5"], "new answers are still recorded")
        XCTAssertEqual(h.marker, L10n.tr("Earlier answer · newer ones arrived"))
    }

    func testStreamingIntoTheLiveEntryWhilePinnedLeavesThePinnedOneAlone() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "One"))
        h.observe(card("r2", say: "Two"))
        h.back()
        h.observe(card("r2", say: "Two, now longer", bullets: ["more"]))
        XCTAssertEqual(h.pinned?.card.say, "One")
        XCTAssertEqual(h.entries[1].card.say, "Two, now longer", "the live entry is updated in the history")
    }

    func testStreamingIntoThePinnedEntryShowsOnThePinnedView() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "One"))
        h.observe(card("r2", say: "Two"))
        h.observe(card("r3", say: nil))   // r2 is no longer on screen live
        h.back()
        XCTAssertEqual(h.pinned?.key, "r2")
        // The pinned entry receives a late update (same card key): the entry and the pinned view follow it.
        h.observe(card("r2", say: "Two", bullets: ["late point"]))
        XCTAssertEqual(h.pinned?.card.bullets, ["late point"])
        XCTAssertEqual(h.pinned?.key, "r2")
    }

    func testCapacityDropsTheOldestButNeverThePinnedEntry() {
        var h = AnswerHistory()
        for i in 1...AnswerHistory.capacity { h.observe(card("r\(i)", say: "\(i)")) }
        XCTAssertEqual(h.entries.count, AnswerHistory.capacity)
        h.observe(card("r11", say: "11"))
        XCTAssertEqual(h.entries.count, AnswerHistory.capacity)
        XCTAssertEqual(h.entries.first?.key, "r2", "the oldest went")

        // Pin the oldest, then let many more answers arrive.
        while h.canGoBack { h.back() }
        XCTAssertEqual(h.pinned?.key, "r2")
        for i in 12...30 { h.observe(card("r\(i)", say: "\(i)")) }
        XCTAssertEqual(h.entries.count, AnswerHistory.capacity)
        XCTAssertEqual(h.pinned?.key, "r2", "the pinned entry stays")
        XCTAssertEqual(h.entries.map(\.key), ["r2"] + (22...30).map { "r\($0)" })
        h.forward()
        XCTAssertEqual(h.pinned?.key, "r22")
    }

    func testClearForgetsEverythingAndGoesLive() {
        var h = AnswerHistory()
        for t in ["r1", "r2"] { h.observe(card(t, say: t)) }
        h.back()
        h.clear()
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertFalse(h.isPinned)
        XCTAssertNil(h.marker)
    }

    func testDisplayReplacesOnlyTheCard() {
        var h = AnswerHistory()
        h.observe(card("r1", say: "One"))
        h.observe(card("r2", say: "Two"))
        var live = OverlayState()
        live.running = true
        live.card = card("r2", say: "Two")
        live.addresseeTag = "for you"
        live.timeCue = .soon
        XCTAssertEqual(h.display(live), live, "live: drawn as it is")
        h.back()
        let shown = h.display(live)
        XCTAssertEqual(shown.card?.say, "One")
        var expected = live
        expected.card = shown.card
        XCTAssertEqual(shown, expected, "cues, tags and the running flag stay live")
    }

    // MARK: through the overlay model

    private func runningModel() -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    private func answer(_ m: OverlayModel, _ tid: String, _ say: String) {
        m.apply(turn(tid, "Question \(tid)?"))
        for e in stream("f-\(tid)", tid, "F", "SAY: \(say)") { m.apply(e) }
    }

    func testTheModelRecordsShownAnswersAndPinsWithoutTouchingTheLiveState() throws {
        let m = runningModel()
        answer(m, "r1", "The first answer.")
        answer(m, "r2", "The second answer.")
        XCTAssertEqual(m.history.entries.map(\.key), ["r1", "r2"])

        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.say, "The first answer.")
        XCTAssertEqual(m.state.card?.say, "The second answer.", "the live state is untouched")

        // Answers keep coming while pinned: the live state moves, the island keeps the pinned one.
        answer(m, "r3", "The third answer.")
        XCTAssertEqual(m.state.card?.say, "The third answer.")
        XCTAssertEqual(m.displayState.card?.say, "The first answer.")
        XCTAssertTrue(m.history.hasNewerSincePin)
        // Streaming into the live card while pinned.
        for e in stream("f-r3", "r3", "F", "- one more point") { m.apply(e) }
        XCTAssertEqual(m.state.card?.bullets, ["one more point"])
        XCTAssertEqual(m.history.entries.last?.card.bullets, ["one more point"])
        XCTAssertEqual(m.displayState.card?.say, "The first answer.")

        m.showNewerAnswer()
        XCTAssertEqual(m.displayState.card?.say, "The second answer.")
        m.showNewerAnswer()
        XCTAssertFalse(m.history.isPinned)
        XCTAssertEqual(m.displayState, m.state)
    }

    func testAClickOnTheBandWhilePinnedGoesLiveAndLeavesTheLiveCard() {
        let m = runningModel()
        answer(m, "r1", "One.")
        answer(m, "r2", "Two.")
        m.showEarlierAnswer()
        m.collapse()
        XCTAssertFalse(m.history.isPinned)
        XCTAssertEqual(m.state.card?.say, "Two.", "the live card stays open")
    }

    func testStopClearsTheHistory() {
        let m = runningModel()
        answer(m, "r1", "One.")
        answer(m, "r2", "Two.")
        m.showEarlierAnswer()
        m.apply(.ended(exitCode: 0))
        XCTAssertTrue(m.history.entries.isEmpty)
        XCTAssertFalse(m.history.isPinned)
        m.showEarlierAnswer()
        XCTAssertFalse(m.history.isPinned, "no Back without a running session")
    }

    func testANewSessionStartsWithAnEmptyHistory() {
        let m = runningModel()
        answer(m, "r1", "One.")
        answer(m, "r2", "Two.")
        m.showEarlierAnswer()
        m.sessionStarting(lang: "en")
        XCTAssertTrue(m.history.entries.isEmpty)
        XCTAssertFalse(m.history.isPinned)
    }

    func testFollowModeRecordsTheReplacedAnswer() throws {
        let m = runningModel()
        answer(m, "r1", "The answer to the question.")
        m.apply(.brain(obj(["type": "follow", "turn_id": "r1", "reason": "diverged", "card_id": "c1"])))
        m.apply(.brain(obj(["type": "delta", "id": "c-c1", "card_id": "c1", "turn_id": "r1", "tier": "C",
                            "text": "SAY: My own line goes on.", "line_done": true])))
        XCTAssertEqual(m.state.card?.followCardID, "c1")
        XCTAssertEqual(m.history.entries.map(\.key), ["r1", "r1|C|c1"])
        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.say, "The answer to the question.")
        XCTAssertFalse(try XCTUnwrap(m.displayState.card).following)
    }

    func testCardNowWhilePinnedStillOpensItsLiveCard() {
        let m = runningModel()
        answer(m, "r1", "One.")
        answer(m, "r2", "Two.")
        m.showEarlierAnswer()
        m.apply(delta("n1", "now-1", "F", "SAY: An answer on request.", done: true))
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        XCTAssertEqual(m.displayState.card?.say, "One.")
        XCTAssertEqual(m.history.entries.last?.key, "now-1")
    }
}
