import CoreGraphics
import Foundation
@testable import VerseUI
import XCTest

/// Hold to talk (gap G8) and Return after inserting (gap G9): the Fn + Space release in the filter, the hold's timing, the
/// controller's stop on a long release, and the Return decision. Everything is faked: no event tap, no key events posted.
extension DictationTests {

    final class FakeReturnKey: DictationReturnKeyPosting {
        private(set) var posted = 0
        func postReturn() { posted += 1 }
    }

    private static let fnFlag = CGEventFlags.maskSecondaryFn
    private static let spaceKey = FnSpaceFilter.spaceKeyCode
    private static let fnKey: Int64 = 63

    // MARK: filter: the release

    func testTheSpaceKeyUpOfAToggleReportsTheReleaseOnce() {
        var f = FnSpaceFilter()
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false), .toggle)
        for _ in 0..<5 {
            XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: true), .swallow,
                           "auto-repeat neither toggles nor releases")
        }
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false), .release)
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false), .pass,
                       "Fn let go after the Space: already released")
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.spaceKey, flags: [], isRepeat: false), .pass)
    }

    func testFnLetGoWhileTheSpaceIsHeldIsTheReleaseAndTheSpaceKeyUpIsOnlySwallowed() {
        var f = FnSpaceFilter()
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false), .toggle)
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: 56, flags: [Self.fnFlag, .maskShift], isRepeat: false), .pass,
                       "another modifier while Fn is still down is not a release")
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false), .releasePassing)
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false), .pass, "reported once")
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: [], isRepeat: true), .swallow,
                       "the held space still types nothing")
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.spaceKey, flags: [], isRepeat: false), .swallow, "no second release")
        // The next press starts afresh.
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false), .toggle)
        XCTAssertEqual(f.decide(type: .keyUp, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false), .release)
    }

    func testFlagsChangesPassWhenNoToggleIsHeld() {
        var f = FnSpaceFilter()
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: Self.fnFlag, isRepeat: false), .pass)
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false), .pass)
        XCTAssertEqual(f.decide(type: .keyDown, keyCode: Self.spaceKey, flags: [], isRepeat: false), .pass, "a plain space")
        XCTAssertEqual(f.decide(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false), .pass)
    }

    func testTheTapDropsTheSpaceKeyUpButPassesTheFnFlagsChange() {
        let box = FnSpaceTapBox(onToggle: {}, onRelease: {}, onCancel: {})
        XCTAssertTrue(box.handle(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false))
        XCTAssertFalse(box.handle(type: .flagsChanged, keyCode: Self.fnKey, flags: [], isRepeat: false),
                       "a modifier change is never dropped")
        XCTAssertTrue(box.handle(type: .keyUp, keyCode: Self.spaceKey, flags: [], isRepeat: false))
        XCTAssertTrue(box.handle(type: .keyDown, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false))
        XCTAssertTrue(box.handle(type: .keyUp, keyCode: Self.spaceKey, flags: Self.fnFlag, isRepeat: false))
    }

    // MARK: the hold's timing

    func testHoldToTalkThresholdIsTypeWhispers() {
        XCTAssertEqual(DictationHoldToTalk.threshold, 1.0)
    }

    func testAShortPressKeepsTheToggleAndALongOneStops() {
        var h = DictationHoldToTalk()
        h.pressStarted(at: 10)
        XCTAssertFalse(h.released(at: 10.99), "under the threshold: toggle")
        XCTAssertFalse(h.isArmed)
        h.pressStarted(at: 20)
        XCTAssertTrue(h.released(at: 21), "at the threshold: stop")
        XCTAssertFalse(h.released(at: 30), "a release is decided once")
    }

    func testTheClockRestartsWhenTheMicrophoneOpens() {
        var h = DictationHoldToTalk()
        h.pressStarted(at: 0)
        h.microphoneOpened(at: 0.6)
        XCTAssertFalse(h.released(at: 1.3), "1.3 s held, but only 0.7 s with the microphone open")
        h.pressStarted(at: 0)
        h.microphoneOpened(at: 0.6)
        XCTAssertTrue(h.released(at: 1.6))
        h.pressStarted(at: 5)
        h.microphoneOpened(at: 4)
        XCTAssertFalse(h.released(at: 5.5), "the clock never moves back")
    }

    func testADisarmedHoldNeverStops() {
        var h = DictationHoldToTalk()
        XCTAssertFalse(h.released(at: 100))
        h.pressStarted(at: 0)
        h.disarm()
        h.microphoneOpened(at: 0.2)
        XCTAssertFalse(h.isArmed, "opening the microphone does not arm it")
        XCTAssertFalse(h.released(at: 5))
    }

    // MARK: the controller

    func testAHeldFnSpaceStopsOnReleaseThroughTheSecondPressPath() async {
        let r = rig { $0.finishText = "held" }
        r.controller.activate()
        defer { r.controller.deactivate() }
        r.settings.sounds = true
        await r.controller.press(fnSpace: true)
        XCTAssertEqual(r.controller.phase, .recording)
        XCTAssertTrue(r.controller.hold.isArmed)
        r.clock.t += 1.5
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.inserter.calls.map(\.text), ["held"])
        XCTAssertEqual(r.sounds.played, [.start, .stop], "the stop cue as for a second press")
        XCTAssertTrue(r.logs.value.contains { $0.contains("release tail") }, "the release tail ran")
    }

    func testAShortFnSpaceTapKeepsRecordingUntilTheNextPress() async {
        let r = rig { $0.finishText = "tapped" }
        r.controller.activate()
        defer { r.controller.deactivate() }
        await r.controller.press(fnSpace: true)
        r.clock.t += 0.3
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.controller.phase, .recording, "a tap toggles")
        XCTAssertTrue(r.inserter.calls.isEmpty)
        r.clock.t += 3
        await r.controller.press(fnSpace: true)
        XCTAssertEqual(r.inserter.calls.map(\.text), ["tapped"])
        r.clock.t += 2
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.inserter.calls.count, 1, "the stop press's own release does nothing")
        XCTAssertEqual(r.controller.phase, .idle)
    }

    func testTheHotKeyAndTheSettingOffStayToggleOnly() async {
        let r = rig()
        r.controller.activate()
        defer { r.controller.deactivate() }
        await r.controller.press()
        XCTAssertFalse(r.controller.hold.isArmed, "⌃⌥⌘D never arms the hold")
        r.clock.t += 5
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.controller.phase, .recording)
        await r.controller.press()
        XCTAssertEqual(r.controller.phase, .idle)

        r.settings.holdToTalk = false
        await r.controller.press(fnSpace: true)
        r.clock.t += 5
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.controller.phase, .recording, "hold to talk off: Fn + Space toggles")
    }

    func testEscDuringAHoldCancelsAndTheReleaseThenDoesNothing() async {
        let r = rig()
        r.controller.activate()
        defer { r.controller.deactivate() }
        await r.controller.press(fnSpace: true)
        r.controller.cancelByKey()
        XCTAssertFalse(r.controller.hold.isArmed)
        r.clock.t += 2
        await r.controller.releaseFnSpace()
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertEqual(r.notifier.notices, [.cancelled])
    }

    func testAReleaseWhileTheMicrophoneIsStillOpeningCountsFromTheKeyDown() async {
        let r = rig { $0.holdBegin = true; $0.finishText = "slow mic" }
        r.controller.activate()
        defer { r.controller.deactivate() }
        let start = Task { await r.controller.press(fnSpace: true) }
        await waitUntil("begin held") { r.last?.beginHeld == true }
        r.clock.t += 1.2
        let stop = Task { await r.controller.releaseFnSpace() }
        await waitUntil("finalising") { r.controller.phase == .finalising }
        r.last?.releaseBegin()
        await start.value
        await stop.value
        XCTAssertEqual(r.inserter.calls.map(\.text), ["slow mic"])
    }

    func testTheTapReportsTheReleaseToTheController() async {
        let r = rig()
        r.controller.activate()
        defer { r.controller.deactivate() }
        XCTAssertNotNil(r.keyTap.onRelease, "the controller hands the tap a release handler")
    }

    private func waitUntil(_ what: String, _ cond: @escaping () -> Bool) async {
        for _ in 0..<2000 {
            if cond() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Return after inserting

    func testReturnDecisionTable() {
        let outcomes: [DictationInsertOutcome] = [.pasted, .pastedIntoTerminal, .copiedToClipboard, .nothing, .notInserted,
                                                  .notInsertedClipboardChanged]
        for outcome in outcomes {
            for source in [DictationInsertSource.dictation, .pasteLast] {
                for enabled in [true, false] {
                    let want = enabled && source == .dictation && outcome == .pasted
                    XCTAssertEqual(DictationReturnAfterInsert.shouldPress(enabled: enabled, outcome: outcome, source: source), want,
                                   "\(enabled) \(outcome) \(source)")
                }
            }
        }
        XCTAssertEqual(DictationReturnAfterInsert.delay, .milliseconds(50))
    }

    func testReturnIsPressedAfterADeliveredDictationOnlyWithTheSettingOn() async {
        let key = FakeReturnKey()
        let r = rig(returnKey: key) { $0.finishText = "send this" }
        XCTAssertFalse(r.settings.pressReturnAfterInsert, "off by default")
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(key.posted, 0)

        r.settings.pressReturnAfterInsert = true
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(key.posted, 1)
        XCTAssertEqual(r.clock.sleeps.last, DictationReturnAfterInsert.delay)

        r.inserter.outcome = .notInserted
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(key.posted, 1, "never after a paste that went nowhere")

        r.inserter.outcome = .pasted
        await r.controller.pasteLast()
        XCTAssertEqual(key.posted, 1, "never after Paste last dictation")

        await r.controller.press()
        r.controller.cancelByKey()
        XCTAssertEqual(key.posted, 1, "never after Esc")
    }

    func testHoldToTalkIsOnAndReturnOffByDefaultAndBothPersist() {
        let d = defaults()
        let s = DictationSettings(defaults: d)
        XCTAssertTrue(s.holdToTalk)
        XCTAssertFalse(s.pressReturnAfterInsert)
        s.holdToTalk = false
        s.pressReturnAfterInsert = true
        let again = DictationSettings(defaults: d)
        XCTAssertFalse(again.holdToTalk)
        XCTAssertTrue(again.pressReturnAfterInsert)
    }
}
