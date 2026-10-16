import Carbon.HIToolbox
import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The island side of anytime calls: the room speaker and card-now turns handled by the reducer itself, the start card,
/// "Unprepared", the stop confirmation and the profile status.
@MainActor
final class AnytimeOverlayTests: XCTestCase {
    private func started(route: AudioRoute? = .room, unprepared: Bool = true) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        m.sessionStarting(lang: "en", session: "adhoc-20261016-1432-room", app: nil, route: route, unprepared: unprepared)
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    private func partial(_ id: String, _ text: String, speaker: String) -> RunnerEvent {
        .outbound(obj(["type": "partial", "turn_id": id, "speaker": speaker, "text": text, "cue": false, "t_audio_end": 1.0, "dir": "to_brain"]))
    }

    // MARK: room speaker

    func testARoomQuestionOpensACardLikeARemoteOne() {
        let m = started()
        m.apply(turn("r1", "Can you walk me through the payments project?", addressee: "unknown", speaker: "room"))
        XCTAssertEqual(m.state.card?.turnID, "r1", "no rewrite of room to remote is needed any more")
        XCTAssertNil(m.state.addresseeTag, "the room route never knows who a question is for")
        for e in stream("F1", "r1", "F", "SAY: It processed about 41,000 payments a month.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.say, "It processed about 41,000 payments a month.")
    }

    func testRoomPartialsCountAsTheOtherSideHearing() {
        let m = started()
        XCTAssertEqual(m.state.startup?.phase, .ready)
        m.apply(partial("r1", "so what about", speaker: "room"))
        XCTAssertEqual(m.state.startup?.phase, .listening)
        XCTAssertEqual(m.state.startup?.transcribing, true)
    }

    func testAMeTurnIsNotTheOtherSide() {
        let m = started()
        m.apply(turn("m1", "I would start with the data model", speaker: "me"))
        XCTAssertNil(m.state.card)
    }

    // MARK: card now

    func testCardNowOpensACardForWhatWasHeardLast() {
        let m = started()
        m.apply(partial("r1", "so what about the budget", speaker: "room"))
        m.apply(partial("m1", "my own words", speaker: "me"))
        for e in stream("F-now-1", "now-1", "F", "SAY: The budget was set per location.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        XCTAssertEqual(m.state.card?.question, "so what about the budget", "the other side's words, not the owner's")
        XCTAssertEqual(m.state.card?.say, "The budget was set per location.")
        XCTAssertEqual(m.state.addresseeTag, "for you")
    }

    func testCardNowPrefersTheNewestTextOfTheOtherSide() {
        let m = started()
        m.apply(partial("r1", "so what about", speaker: "room"))
        m.apply(turn("r1", "so what about the budget for next year", addressee: "unknown", kind: "statement", speaker: "room"))
        m.apply(partial("r2", "and the timeline", speaker: "room"))
        m.apply(delta("F-now-1", "now-1", "F", "SAY: "))
        XCTAssertEqual(m.state.card?.question, "and the timeline", "the open partial is the newest")
    }

    func testACardNowCardOpensOnceAndStaysClosedWhenDismissed() {
        let m = started()
        m.apply(partial("r1", "what did you build there", speaker: "room"))
        m.apply(delta("F-now-1", "now-1", "F", "SAY: First", done: true))
        XCTAssertNotNil(m.state.card)
        m.collapse()
        XCTAssertNil(m.state.card)
        m.apply(delta("D-now-1", "now-1", "D", "- a late deep point"))
        XCTAssertNil(m.state.card, "a card the user closed is not opened again by a later delta of its turn")
        // The next card-now is a new turn.
        m.apply(delta("F-now-2", "now-2", "F", "SAY: Second", done: true))
        XCTAssertEqual(m.state.card?.turnID, "now-2")
    }

    func testADeltaOfAnOrdinaryTurnWithoutATurnStillOpensNothing() {
        let m = started()
        m.apply(partial("r1", "what did you build there", speaker: "room"))
        m.apply(delta("F1", "r1", "F", "SAY: hello", done: true))
        XCTAssertNil(m.state.card, "only now-* turns open a card from a bare delta")
    }

    // MARK: profile status

    func testTheMeMissingNoticeIsAStatusThatNeverCoversACard() throws {
        let m = started()
        m.apply(.brain(try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"me_missing"}"#))))
        XCTAssertEqual(m.state.status, .meMissing)
        guard case .statusPanel(.meMissing) = IslandKind.resolve(m.state, prompterOpen: false) else { return XCTFail("a status panel") }
        XCTAssertEqual(OverlayStatus.meMissing.title, "Your profile was not found")
        XCTAssertEqual(OverlayStatus.meMissing.detail, "Verse answers without it. Build it on the Me page.")
        // A question comes in: the card takes the island, the status goes.
        m.apply(turn("r1", "What did you build?", addressee: "me"))
        XCTAssertNil(m.state.status)
        XCTAssertNotNil(m.state.card)
    }

    func testTheConflictNoticeStaysOffTheIsland() throws {
        let m = started()
        let before = m.state
        m.apply(.brain(try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"me_conflicts","items":[{"me":"m402","pack":"f003","topic":"close time"}]}"#))))
        XCTAssertEqual(m.state, before)
    }

    // MARK: stop confirmation

    func testPressAgainToStopShowsAndLapses() {
        let m = started()
        m.setStopConfirm(true)
        XCTAssertEqual(m.state.status, .stopConfirm)
        guard case .statusPanel(.stopConfirm) = IslandKind.resolve(m.state, prompterOpen: false) else { return XCTFail("a status panel") }
        XCTAssertEqual(OverlayStatus.stopConfirm.title, "Press ⌥⌘V again to stop")
        m.setStopConfirm(false)
        XCTAssertNil(m.state.status)
    }

    func testTheStopConfirmationOverlaysACardAndGivesItBack() {
        let m = started()
        m.apply(turn("r1", "What did you build?", addressee: "me"))
        for e in stream("F1", "r1", "F", "SAY: A reconciliation service.") { m.apply(e) }
        m.setStopConfirm(true)
        guard case .statusPanel = IslandKind.resolve(m.state, prompterOpen: false) else { return XCTFail("the status overlays the card") }
        XCTAssertEqual(m.state.card?.say, "A reconciliation service.", "the card is still there")
        m.setStopConfirm(false)
        guard case .card = IslandKind.resolve(m.state, prompterOpen: false) else { return XCTFail("the card is back") }
    }

    func testTheStopConfirmationNeverHidesARealError() {
        let m = started()
        m.apply(status("credit_exhausted", "Credit is used up."))
        m.setStopConfirm(true)
        XCTAssertEqual(m.state.status, .creditExhausted("Credit is used up."))
        m.setStopConfirm(false)
        XCTAssertEqual(m.state.status, .creditExhausted("Credit is used up."), "taking the confirmation down leaves other statuses")
    }

    func testTheConfirmationHasNoButtonsAndTheProfileStatusOpensTheMePage() {
        // The panel's buttons depend on the status; the rules are small enough to state here.
        XCTAssertTrue(OverlayStatus.stopConfirm.needsPanel)
        XCTAssertTrue(OverlayStatus.meMissing.needsPanel)
        XCTAssertEqual(OverlayStatus.stopConfirm.shortTitle, "Stop?")
        XCTAssertEqual(OverlayStatus.meMissing.shortTitle, "No profile")
    }

    // MARK: start card

    func testTheStartCardCarriesRouteLanguageAndUnprepared() {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        m.sessionStarting(lang: "it", session: "adhoc-20261016-1432-room", app: nil, route: .room, unprepared: true)
        let p = try! XCTUnwrap(m.state.startup)
        XCTAssertTrue(p.isStartCard)
        XCTAssertEqual(p.route, .room)
        XCTAssertEqual(p.lang, "it")
        XCTAssertTrue(m.state.unprepared)
        XCTAssertEqual(m.state.route, .room)
        XCTAssertEqual(p.title, "Starting…")
        var ready = p
        ready.phase = .ready
        XCTAssertEqual(ready.title, "Ready", "no folder name on the start card")
        XCTAssertEqual(ready.subtitle, "listening through the microphone")
        ready.phase = .listening
        XCTAssertEqual(ready.subtitle, "hearing the room")
        ready.transcribing = true
        XCTAssertEqual(ready.subtitle, "hearing the room · transcribing")
    }

    func testAMeetingStartedTheOldWayKeepsThePlainPanel() {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        m.sessionStarting(lang: "en", session: "mara-northwindlabs", app: "Comet")
        let p = try! XCTUnwrap(m.state.startup)
        XCTAssertFalse(p.isStartCard)
        XCTAssertFalse(m.state.unprepared)
        XCTAssertNil(m.state.route)
        var ready = p
        ready.phase = .ready
        XCTAssertEqual(ready.title, "Ready · mara-northwindlabs")
        XCTAssertEqual(ready.subtitle, "listening to Comet")
    }

    func testTheChipsReachTheController() {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        var seen: [StartChipAction] = []
        m.startChipActions = { seen.append($0) }
        m.startChipAction(.cycleRoute)
        m.startChipAction(.setLanguage("tr"))
        XCTAssertEqual(seen, [.cycleRoute, .setLanguage("tr")])
    }

    func testTheRouteChipCyclesThroughWhatCanRun() {
        XCTAssertEqual(StartRoutes.next(after: .meeting), .room)
        XCTAssertEqual(StartRoutes.next(after: .room), .meeting)
        XCTAssertEqual(StartRoutes.next(after: .phone), .meeting, "phone is not startable yet: a click leaves it")
        XCTAssertEqual(StartRoutes.label(.room), "Room")
        XCTAssertEqual(StartRoutes.label(.phone), "Phone")
        XCTAssertEqual(StartRoutes.label(.meeting), "Meeting")
        XCTAssertEqual(AppSettings.callLanguages, ["en", "it", "tr"])
    }

    // MARK: hot key hand-over

    func testThePracticeHotKeyLeavesOtherKeysToTheirHandlers() {
        // ⌥Space of the interview is the only event SimHotKey consumes; ⌥⌘V (signature VRHQ) must pass through.
        XCTAssertTrue(SimHotKey.isOwn(EventHotKeyID(signature: SimHotKey.signature, id: 1)))
        XCTAssertFalse(SimHotKey.isOwn(EventHotKeyID(signature: 0x5652_4851, id: 1)), "GlobalHotKeys' signature")
        XCTAssertFalse(SimHotKey.isOwn(EventHotKeyID(signature: SimHotKey.signature, id: 2)))
    }
}
