import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The live controls on the island's answer card: Regenerate (⌥⌘R) and the BAD mark (⌥⌘↓). The language rule and the
/// mark toggle are pure; the in-flight guard and the card they act on are driven through the overlay model; the wire lines are
/// checked against the fixture the brain's own test feeds to the brain (brain/tests/fixtures/live_controls/swift_wire.jsonl, read
/// back there by the after-call review's reader).
@MainActor
final class LiveControlsTests: XCTestCase {

    final class Clock: @unchecked Sendable { var now: TimeInterval = 1000 }

    private func runningModel(_ clock: Clock = Clock()) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { clock.now })
        m.sessionStarting(lang: "en")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        return m
    }

    private func answer(_ m: OverlayModel, _ tid: String, _ say: String, id: String? = nil) {
        m.apply(turn(tid, "Question \(tid)?"))
        for e in stream(id ?? "f-\(tid)", tid, "F", "SAY: \(say)") { m.apply(e) }
    }

    private func metric(_ stage: String, _ fields: [String: Any] = [:]) -> RunnerEvent {
        .brain(obj(["type": "metric", "turn_id": "", "stage": stage].merging(fields) { _, new in new }))
    }

    // MARK: the language rule

    func testRegenerateLanguageRule() {
        let cases: [(answer: String?, dominant: String?, lang: String?, reset: Bool, why: String)] = [
            ("it", "en", "en", true, "an Italian answer in an English call: English, and the auto language is reset"),
            ("en", "it", "it", true, "the other way round"),
            ("tr", "en", "en", true, "Turkish off the dominant language"),
            ("en", "en", "en", false, "already in the dominant language: a fresh variant in it"),
            ("it", "it", "it", false, "same in Italian"),
            ("it", nil, "it", false, "AUTO off: the card's own language"),
            (nil, nil, nil, false, "nothing known: the brain decides, nothing is reset"),
            (nil, "en", "en", false, "the card's language unknown: the dominant one, nothing to reset"),
        ]
        for c in cases {
            let r = RegenerateRule.language(answer: c.answer, dominant: c.dominant)
            XCTAssertEqual(r.lang, c.lang, c.why)
            XCTAssertEqual(r.reset, c.reset, c.why)
        }
    }

    func testTheRecognizersGoBackOnlyWhenTheAutoLanguageWasReset() {
        func req(_ lang: String?, _ reset: Bool) -> RegenerateRequest {
            RegenerateRequest(turn: "r1", question: "q", lang: lang, reset: reset, avoid: nil)
        }
        XCTAssertEqual(VerseController.recognizerReset(req("en", true), auto: true, listening: "it"), "en")
        XCTAssertNil(VerseController.recognizerReset(req("en", true), auto: true, listening: "en"), "already listening in it")
        XCTAssertNil(VerseController.recognizerReset(req("en", true), auto: false, listening: "it"), "a pinned call never switches")
        XCTAssertNil(VerseController.recognizerReset(req("en", false), auto: true, listening: "it"), "a fresh variant swaps nothing")
    }

    // MARK: regenerate through the model

    func testRegenerateAsksForTheCardOnScreenInTheDominantLanguageAndResets() throws {
        let m = runningModel()
        var sent: [RegenerateRequest] = []
        m.regenerateActions = { sent.append($0); return true }
        m.apply(metric("lang_dominant", ["lang": "en", "reason": "start"]))
        answer(m, "r1", "Una risposta.")
        m.apply(metric("answer_lang", ["turn_id": "r1", "lang": "it", "dominant": "en"]))
        let req = try XCTUnwrap(m.regenerate())
        XCTAssertEqual(req, RegenerateRequest(turn: "r1", question: "Question r1?", lang: "en", reset: true, avoid: "Una risposta."))
        XCTAssertEqual(sent, [req])
        XCTAssertTrue(m.state.regenerating)
    }

    func testAnItalianCardAfterAShortFlipInAMostlyEnglishCallIsRegeneratedInEnglishWithAReset() throws {
        // The owner's example (item 9): the cards flipped to Italian on a short run, most of the call is English.
        let m = runningModel()
        var sent: [RegenerateRequest] = []
        m.regenerateActions = { sent.append($0); return true }
        m.apply(metric("lang_dominant", ["lang": "en", "reason": "start", "majority": "en"]))
        m.apply(metric("lang_dominant", ["lang": "it", "prev": "en", "reason": "sustained", "majority": "en"]))
        XCTAssertEqual(m.state.dominantLang, "it")
        XCTAssertEqual(m.state.majorityLang, "en")
        answer(m, "r5", "Una risposta.")
        m.apply(metric("answer_lang", ["turn_id": "r5", "lang": "it", "dominant": "it"]))
        let req = try XCTUnwrap(m.regenerate())
        XCTAssertEqual([req.lang, req.reset ? "reset" : "keep"], ["en", "reset"])
        XCTAssertEqual(VerseController.recognizerReset(req, auto: true, listening: "it"), "en", "the recognizers go back to English")
        // The majority moves on its own; AUTO off forgets both.
        m.apply(metric("lang_majority", ["lang": "it", "prev": "en"]))
        XCTAssertEqual(m.state.majorityLang, "it")
        m.apply(metric("lang_auto", ["on": false, "lang": "en"]))
        XCTAssertNil(m.state.majorityLang)
        XCTAssertNil(m.state.dominantLang)
    }

    func testARegenerateWhileOneIsInFlightIsIgnoredUntilTheBrainSaysDone() {
        let m = runningModel()
        var sent = 0
        m.regenerateActions = { _ in sent += 1; return true }
        answer(m, "r1", "One.")
        XCTAssertNotNil(m.regenerate())
        XCTAssertNil(m.regenerate(), "pressed again while the first is on its way: ignored")
        XCTAssertFalse(m.canRegenerate)
        // The new answer streams on its card-now turn; listening and new cards are untouched meanwhile.
        m.apply(metric("regenerate", ["turn_id": "now-1", "of": "r1", "question": "Question r1?"]))
        m.apply(delta("f9", "now-1", "F", "SAY: A fresh answer.", done: true))
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        XCTAssertEqual(m.state.card?.question, "Question r1?", "the regenerated card asks the question it answers again")
        XCTAssertNil(m.regenerate(), "still streaming")
        m.apply(metric("regenerate_done", ["turn_id": "now-1", "id": "f9"]))
        XCTAssertNotNil(m.regenerate(), "done: the next press counts")
        XCTAssertEqual(sent, 2)
        m.apply(metric("regenerate_empty", ["of": "now-1"]))
        XCTAssertFalse(m.state.regenerating)
    }

    func testAnUnconfirmedRegenerateStopsBlockingAfterTheTimeout() {
        let clock = Clock()
        let m = runningModel(clock)
        m.regenerateActions = { _ in true }
        answer(m, "r1", "One.")
        XCTAssertNotNil(m.regenerate())
        clock.now += RegenerateRule.inFlightTimeout - 1
        m.tick()
        XCTAssertTrue(m.state.regenerating)
        clock.now += 1
        m.tick()
        XCTAssertFalse(m.state.regenerating)
        XCTAssertNotNil(m.regenerate())
    }

    func testRegenerateWithNoBrainToAskIsUndone() {
        let m = runningModel()
        m.regenerateActions = { _ in false }
        answer(m, "r1", "One.")
        XCTAssertNil(m.regenerate())
        XCTAssertFalse(m.state.regenerating)
    }

    func testRegenerateOnAnEarlierAnswerAsksForThatOneAndGoesLiveWhereTheNewAnswerArrives() throws {
        let m = runningModel()
        var sent: [RegenerateRequest] = []
        m.regenerateActions = { sent.append($0); return true }
        answer(m, "r1", "One.")
        answer(m, "r2", "Two.")
        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.turnID, "r1")
        _ = try XCTUnwrap(m.regenerate())
        XCTAssertEqual(sent.map(\.turn), ["r1"])
        XCTAssertFalse(m.history.isPinned, "the island goes live, where the regenerated answer arrives")
        m.apply(metric("regenerate", ["turn_id": "now-1", "of": "r1", "question": "Question r1?"]))
        m.apply(delta("f9", "now-1", "F", "SAY: One, said another way.", done: true))
        XCTAssertEqual(m.history.entries.map(\.key), ["r1", "r2", "now-1"], "the replaced answers stay reachable with Back")
        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.say, "Two.")
    }

    func testRegenerateOnAnEarlierCardLeavesTheNewerAnswerStreamingIntoTheHistory() throws {
        let m = runningModel()
        m.regenerateActions = { _ in true }
        answer(m, "r1", "One.")
        m.apply(turn("r2", "Question r2?"))
        m.apply(delta("f-r2", "r2", "F", "SAY: Two"))                    // half of r2's SAY line
        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.turnID, "r1")
        _ = try XCTUnwrap(m.regenerate())
        m.apply(metric("regenerate", ["turn_id": "now-1", "of": "r1", "question": "Question r1?"]))
        m.apply(delta("f9", "now-1", "F", "SAY: One, said another way.", done: true))
        m.apply(delta("f-r2", "r2", "F", " and a half.", done: true))  // the rest of r2 arrives while the regenerated card is shown
        m.apply(delta("f-r2", "r2", "F", "- A point.", done: true))
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        let r2 = try XCTUnwrap(m.history.entries.first { $0.key == "r2" })
        XCTAssertEqual(r2.card.say, "Two and a half.", "the newer answer is not frozen at what it had streamed")
        XCTAssertEqual(r2.card.bullets, ["A point."])
    }

    func testANewerQuestionWithNoAnswerYetStillGetsItsEntryWhenARegeneratedCardIsShown() throws {
        let m = runningModel()
        m.regenerateActions = { _ in true }
        answer(m, "r1", "One.")
        m.apply(turn("r2", "Question r2?"))                                // heard, nothing streamed yet
        m.showEarlierAnswer()
        XCTAssertEqual(m.displayState.card?.turnID, "r1")
        _ = try XCTUnwrap(m.regenerate())
        m.apply(metric("regenerate", ["turn_id": "now-1", "of": "r1", "question": "Question r1?"]))
        m.apply(delta("f9", "now-1", "F", "SAY: One, said another way.", done: true))
        for e in stream("f-r2", "r2", "F", "SAY: Two.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        XCTAssertEqual(m.history.entries.first { $0.key == "r2" }?.card.say, "Two.", "r2's answer is in the history, not lost")
    }

    func testARegeneratedCardIsNotTheNewestTurnSoAWaitingStatementStillOpensOnItsBankHit() {
        let m = runningModel()
        m.regenerateActions = { _ in true }
        answer(m, "r1", "One.")
        XCTAssertNotNil(m.regenerate())
        m.apply(turn("r2", "So you built the pipeline", kind: "statement"))   // waits for a bank hit
        m.apply(metric("regenerate", ["turn_id": "now-1", "of": "r1", "question": "Question r1?"]))
        m.apply(delta("f9", "now-1", "F", "SAY: One, said another way.", done: true))
        XCTAssertEqual(m.state.card?.turnID, "now-1")
        m.apply(.brain(obj(["type": "bank_hit", "turn_id": "r2", "bank_id": "b1"])))
        XCTAssertEqual(m.state.card?.turnID, "r2", "the newest remote turn still opens its card late")
    }

    func testNothingToRegenerateWithoutAnAnswerOnScreenOrARunningSession() {
        let m = runningModel()
        m.regenerateActions = { _ in XCTFail("nothing to ask"); return true }
        XCTAssertNil(m.regenerate(), "no card")
        m.apply(turn("r1", "Still being heard?"))
        XCTAssertNil(m.regenerate(), "a card that only shows the question is no answer yet")
        m.apply(.ended(exitCode: 0))
        XCTAssertNil(m.regenerate())
    }

    // MARK: marks

    func testAMarkToggles() {
        var marks = CardMarks()
        var card = OverlayCard(turnID: "r2", question: "How did it go?")
        card.say = "Well."
        card.cardID = "f0004"
        XCTAssertEqual(marks.press(.bad, on: card), [CardMarkEvent(card: "f0004", mark: "bad", turn: "r2", question: "How did it go?")])
        XCTAssertEqual(marks.mark(for: card), .bad)
        XCTAssertEqual(marks.press(.bad, on: card).map(\.mark), ["cleared"], "the same mark again clears it")
        XCTAssertNil(marks.mark(for: card))
        var opener = OverlayCard(turnID: "r3", question: "q")
        opener.say = "From the bank."
        XCTAssertEqual(marks.press(.bad, on: opener).map(\.card), ["P-r3"], "a card with no call yet is named by its turn")
    }

    func testAMarkSetOnTheBankOpenerCanBeUndoneAfterTheCallsLinesReplaceIt() {
        var marks = CardMarks()
        var card = OverlayCard(turnID: "r3", question: "What would you change?")
        card.say = "From the bank."
        XCTAssertEqual(marks.press(.bad, on: card).map(\.card), ["P-r3"])
        card.cardID = "f0005"                                             // F's lines arrive on the same card
        card.say = "From the call."
        XCTAssertEqual(marks.mark(for: card), .bad, "the island still shows the mark")
        XCTAssertEqual(marks.press(.bad, on: card).map { [$0.card, $0.mark] }, [["P-r3", "cleared"]], "pressed again: undone where it was sent")
        XCTAssertNil(marks.mark(for: card))
        XCTAssertEqual(marks.press(.bad, on: card).map { [$0.card, $0.mark] }, [["f0005", "bad"]])
    }

    func testTheMarkNamesTheCallIdOfTheCardOnScreenIncludingAnEarlierOne() throws {
        let m = runningModel()
        var events: [CardMarkEvent] = []
        m.markActions = { events.append($0) }
        answer(m, "r1", "One.", id: "f0003")
        answer(m, "r2", "Two.", id: "f0007")
        XCTAssertEqual(m.state.card?.cardID, "f0007")
        m.showEarlierAnswer()
        XCTAssertEqual(try XCTUnwrap(m.mark(.bad)), CardMarkEvent(card: "f0003", mark: "bad", turn: "r1", question: "Question r1?"))
        XCTAssertEqual(m.markOnScreen, .bad, "the button shows the mark of the card on screen")
        XCTAssertTrue(m.history.isPinned, "a mark changes nothing else")
        m.showNewerAnswer()
        XCTAssertNil(m.markOnScreen, "the live card has no mark")
        m.mark(.bad)
        m.mark(.bad)
        XCTAssertEqual(events.map(\.mark), ["bad", "bad", "cleared"])
        XCTAssertEqual(events.map(\.card), ["f0003", "f0007", "f0007"])
    }

    func testTheMarkFollowsTheCardTheIslandShows() {
        let m = runningModel()
        // S selected over F: the S call's lines are on screen.
        m.apply(turn("r1", "Question r1?"))
        for e in stream("s0002", "r1", "S", "SAY: From the stable partial.") { m.apply(e) }
        for e in stream("f0005", "r1", "F", "SAY: From the final.") { m.apply(e) }
        m.apply(.brain(obj(["type": "select", "turn_id": "r1", "id": "s0002"])))
        XCTAssertEqual(m.state.card?.cardID, "s0002")
        // A follow card replaces the text: its own call is the card on screen.
        m.apply(.brain(obj(["type": "follow", "turn_id": "r1", "reason": "diverged", "card_id": "c1"])))
        m.apply(.brain(obj(["type": "delta", "id": "c0009", "card_id": "c1", "turn_id": "r1", "tier": "C",
                            "text": "SAY: My own line goes on.", "line_done": true])))
        XCTAssertEqual(m.state.card?.cardID, "c0009")
    }

    func testTheMarkNamesTheCallWhoseSayLineIsOnScreen() {
        let m = runningModel()
        m.bank = ["b1": BankOpener(opener: "From the bank.", points: ["Bank point."])]
        // The bank's opener with F's points under it (F has no SAY line yet): the opener is the bank's.
        m.apply(turn("r1", "Question r1?"))
        m.apply(.brain(obj(["type": "bank_hit", "turn_id": "r1", "bank_id": "b1"])))
        m.apply(delta("f0002", "r1", "F", "- A point from F.", done: true))
        XCTAssertEqual(m.state.card?.say, "From the bank.")
        XCTAssertNil(m.state.card?.cardID, "named P-r1, not by F's id")
        // D's OPENER_WRONG correction replaces the SAY line: the mark names D.
        m.apply(turn("r2", "Question r2?"))
        for e in stream("f0004", "r2", "F", "SAY: We shipped in Q2.") { m.apply(e) }
        for e in stream("d0005", "r2", "D", "SAY: We shipped in Q3.") { m.apply(e) }
        XCTAssertEqual(m.state.card?.cardID, "f0004")
        m.apply(.brain(obj(["type": "opener_status", "turn_id": "r2", "ok": false])))
        XCTAssertEqual(m.state.card?.say, "We shipped in Q3.")
        XCTAssertEqual(m.state.card?.cardID, "d0005")
    }

    func testMarksAreForgottenWhenTheSessionEndsOrANewOneStarts() {
        let m = runningModel()
        m.markActions = { _ in }
        answer(m, "r1", "One.")
        m.mark(.bad)
        XCTAssertEqual(m.marks.marks.count, 1)
        m.apply(.ended(exitCode: 0))
        XCTAssertTrue(m.marks.marks.isEmpty)
        XCTAssertNil(m.mark(.bad), "no mark without a running session")
    }

    // MARK: the wire

    func testTheWireLinesMatchTheFixtureTheBrainReadsBack() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("brain/tests/fixtures/live_controls/swift_wire.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
        var marks = CardMarks()
        var card = OverlayCard(turnID: "r2", question: "How did the Lantern rollout go?")
        card.say = "It went well."
        card.cardID = "f0004"
        var bank = OverlayCard(turnID: "r3", question: "What would you change next time?")
        bank.say = "From the bank."
        // The fixture's first line is a "good" mark: the brain still reads one (older apps wrote it), but this app never sends it, so
        // that line is encoded by hand and the press that follows sets BAD (its own line is checked below) before it is cleared.
        let good = BrainCommand.cardMark(card: "f0004", mark: "good", turn: card.turnID, question: card.question).jsonLine()
        XCTAssertEqual(marks.press(.bad, on: card).map(\.mark), ["bad"])
        let wire = [good] + (marks.press(.bad, on: card) + marks.press(.bad, on: bank)).map {
            BrainCommand.cardMark(card: $0.card, mark: $0.mark, turn: $0.turn, question: $0.question).jsonLine()
        }
        let req = RegenerateRule.request(for: { var c = card; c.answerLang = "it"; return c }(), dominant: "en")
        let regen = BrainCommand.regenerate(turn: req.turn, question: req.question, lang: req.lang, reset: req.reset, avoid: req.avoid).jsonLine()
        XCTAssertEqual(wire + [regen], lines)
        XCTAssertEqual(BrainCommand.regenerate(turn: "r1").jsonLine(), #"{"action":"regenerate","turn":"r1","type":"control"}"#,
                       "optional fields only when set")
    }

    // MARK: control row against the resize grip

    func testTheControlRowAndTheGripKeepApartAtTheNarrowestCard() {
        let narrow = CGFloat(AppSettings.cardWidthRange.lowerBound)
        let four = CardControlRow.buttons(canGoForward: false, hasAnswer: true)
        let five = CardControlRow.buttons(canGoForward: true, hasAnswer: true)
        XCTAssertEqual([four, five], [4, 5], "Back, Regenerate, Bad, Stop; and Forward on an earlier answer")
        XCTAssertEqual(CardControlRow.buttons(canGoForward: false, hasAnswer: false), 2, "a question with no answer yet: Back and Stop")
        XCTAssertEqual([CardControlRow.width(buttons: four), CardControlRow.width(buttons: five)], [158, 196])
        // The row ends 24 pt from the right edge; the grip's 120 pt hit area ends where the row begins, never under it.
        for n in [2, four, five] {
            let rowLeft = narrow - CardControlRow.trailingInset - CardControlRow.width(buttons: n)
            let gripRight = narrow / 2 + CardControlRow.gripShift(cardWidth: narrow, buttons: n) + CardControlRow.gripWidth / 2
            XCTAssertLessThanOrEqual(gripRight, rowLeft, "\(n) buttons at \(narrow) pt")
        }
        XCTAssertEqual(CardControlRow.gripShift(cardWidth: narrow, buttons: four), -32)
        XCTAssertEqual(CardControlRow.gripShift(cardWidth: narrow, buttons: five), -70)
        XCTAssertEqual(CardControlRow.gripShift(cardWidth: 484, buttons: four), 0, "wide enough: centred")
        XCTAssertEqual(CardControlRow.gripShift(cardWidth: 560, buttons: five), 0)
        XCTAssertEqual(CardControlRow.gripShift(cardWidth: 600, buttons: five), 0, "the default width")
        XCTAssertLessThan(CardControlRow.gripShift(cardWidth: 559, buttons: five), 0)
    }

    // MARK: hot keys

    func testLiveKeysAreRegisteredOnlyWhileASessionRuns() {
        let reg = QuickStartTests.FakeRegistrar()
        var presses: [String] = []
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {},
                                 onRegenerate: { presses.append("regen") },
                                 onMarkBad: { presses.append("bad") }, lessThanKeyCodes: { [50] })
        keys.registerStartStop()
        XCTAssertFalse(keys.regenerateRegistered || keys.markBadRegistered)
        XCTAssertFalse(reg.tried.contains(.regenerate), "never tried before a session runs")

        keys.setSessionRunning(true)
        XCTAssertTrue(keys.regenerateRegistered && keys.markBadRegistered)
        let byID = Dictionary(uniqueKeysWithValues: reg.live.values.map { ($0.id, $0.spec) })
        XCTAssertEqual(byID[GlobalHotKeys.regenerateID], .regenerate)
        XCTAssertEqual(byID[GlobalHotKeys.markBadID], .markBad)
        XCTAssertEqual(HotKeySpec.regenerate.modifiers, HotKeySpec.cardNow.modifiers, "option + command")
        XCTAssertEqual([HotKeySpec.regenerate.keyCode, HotKeySpec.markBad.keyCode], [15, 125], "R, down")
        reg.press(GlobalHotKeys.regenerateID)
        reg.press(GlobalHotKeys.markBadID)
        XCTAssertEqual(presses, ["regen", "bad"])

        keys.setSessionRunning(false)
        XCTAssertFalse(keys.regenerateRegistered || keys.markBadRegistered)
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID])
    }

    func testALiveKeyTakenByAnotherAppIsListed() {
        let reg = QuickStartTests.FakeRegistrar()
        reg.refuse = [GlobalHotKeys.regenerateID, GlobalHotKeys.markBadID]
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {}, lessThanKeyCodes: { [50] })
        keys.setSessionRunning(true)
        XCTAssertEqual(keys.unavailableAnswerKeys, [.regenerate, .markBad])
        XCTAssertEqual(keys.unavailableAnswerKeys.map(VerseController.keyLabel), ["⌥⌘R", "⌥⌘↓"])
        XCTAssertTrue(keys.cardNowRegistered)
    }
}
