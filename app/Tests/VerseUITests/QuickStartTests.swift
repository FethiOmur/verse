import Foundation
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// Start anytime (anytime-calls spec 2.1): route pick, session pick, adhoc folders, the double-press stop and the hot keys.
@MainActor
final class QuickStartTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-quickstart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ id: String, start: Date, minutes: Double = 30) -> MeetingEvent {
        MeetingEvent(id: id, title: "Call \(id)", start: start, end: start.addingTimeInterval(minutes * 60))
    }

    private let now = Date(timeIntervalSince1970: 1_792_000_000)   // a fixed instant

    // MARK: route

    func testRoutePick() {
        XCTAssertEqual(QuickStart.pickRoute(.init(phoneCallActive: true, meetingAppHoldsMic: false)), .phone)
        XCTAssertEqual(QuickStart.pickRoute(.init(phoneCallActive: true, meetingAppHoldsMic: true)), .phone, "phone first")
        XCTAssertEqual(QuickStart.pickRoute(.init(phoneCallActive: false, meetingAppHoldsMic: true)), .meeting)
        XCTAssertEqual(QuickStart.pickRoute(.init()), .room, "neither: the microphone alone")
    }

    func testMeetingAppHoldingTheMicFromTheProcessList() {
        let brave = AudioProcessInfo(bundleID: "com.brave.Browser.helper", pid: 10, isRunningInput: true)
        let playing = AudioProcessInfo(bundleID: "com.brave.Browser", pid: 11, isRunningInput: false, isRunningOutput: true)
        let dictation = AudioProcessInfo(bundleID: "com.example.Recorder", pid: 12, isRunningInput: true)
        XCTAssertTrue(QuickStart.meetingAppHoldsMic([dictation, brave]))
        XCTAssertFalse(QuickStart.meetingAppHoldsMic([playing]), "a browser that only plays audio is not a call")
        XCTAssertFalse(QuickStart.meetingAppHoldsMic([dictation]), "an unknown app holding the mic is not a meeting")
        XCTAssertFalse(QuickStart.meetingAppHoldsMic([]))
    }

    /// The phone route needs phase B's tap; until then a phone call is heard through the room route.
    func testPhoneRouteFallsBackToRoomUntilPhaseB() {
        XCTAssertEqual(QuickStart.runnableRoute(.phone), .room)
        XCTAssertEqual(QuickStart.runnableRoute(.meeting), .meeting)
        XCTAssertEqual(QuickStart.runnableRoute(.room), .room)
    }

    // MARK: session

    func testPreparedSessionWhenAnEventWithAMappedSessionIsNear() {
        let e = event("e1", start: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [e], remembered: ["e1": "mara"], sessions: ["mara", "other"]), .prepared("mara"))
        // It started 40 minutes ago and is still running: it counts.
        let running = event("e2", start: now.addingTimeInterval(-40 * 60), minutes: 90)
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [running], remembered: ["e2": "ongoing"], sessions: ["ongoing"]), .prepared("ongoing"))
        // It ended 10 minutes ago: still inside the window.
        let justOver = event("e3", start: now.addingTimeInterval(-40 * 60), minutes: 30)
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [justOver], remembered: ["e3": "late"], sessions: ["late"]), .prepared("late"))
    }

    func testAdhocWhenNothingFits() {
        let far = event("e1", start: now.addingTimeInterval(20 * 60))
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [far], remembered: ["e1": "mara"], sessions: ["mara"]), .adhoc, "20 min away")
        let over = event("e2", start: now.addingTimeInterval(-90 * 60), minutes: 30)
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [over], remembered: ["e2": "old"], sessions: ["old"]), .adhoc, "ended an hour ago")
        let near = event("e3", start: now)
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [near], remembered: [:], sessions: ["x"]), .adhoc, "no prepared session is linked to it")
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [near], remembered: ["e3": "gone"], sessions: ["x"]), .adhoc, "the mapped folder was deleted")
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [], remembered: ["e3": "x"], sessions: ["x"]), .adhoc)
    }

    func testTheEventRunningNowBeatsOneStartingSoon() {
        let running = event("run", start: now.addingTimeInterval(-10 * 60), minutes: 60)
        let soon = event("soon", start: now.addingTimeInterval(5 * 60))
        let map = ["run": "current", "soon": "next"]
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [soon, running], remembered: map, sessions: ["current", "next"]), .prepared("current"))
        // Neither running: the nearest start wins.
        let a = event("a", start: now.addingTimeInterval(12 * 60)), b = event("b", start: now.addingTimeInterval(-6 * 60), minutes: 5)
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [a, b], remembered: ["a": "A", "b": "B"], sessions: ["A", "B"]), .prepared("B"))
        // The nearest has no session: the next one that has.
        XCTAssertEqual(QuickStart.pickSession(now: now, events: [a, b], remembered: ["a": "A"], sessions: ["A"]), .prepared("A"))
    }

    // MARK: adhoc folder

    func testPlanCreatesAnUnpreparedFolderThroughSessionCatalog() throws {
        let root = try tempRoot()
        let utc = TimeZone(identifier: "UTC")!
        let plan = try QuickStart.plan(now: Date(timeIntervalSince1970: 1_792_000_000), facts: .init(), events: [], remembered: [:],
                                       sessions: [], lang: "it", root: root, timeZone: utc)
        XCTAssertEqual(plan.route, .room)
        XCTAssertEqual(plan.mode, .unprepared)
        XCTAssertEqual(plan.lang, "it")
        XCTAssertEqual(plan.session, "adhoc-20261014-1746-room")
        let dir = SessionCatalog.url(plan.session, root: root)

        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))) as? [String: String]
        XCTAssertEqual(meta, ["kind": "adhoc", "mode": "unprepared", "route": "room", "lang": "it"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("pack.md")).count, 0, "an empty pack.md")
        XCTAssertEqual(AdhocMeta.read(sessionDir: dir)?.route, "room")
        XCTAssertTrue(SessionCatalog.isAdhoc(plan.session))
        // The catalog lists it (it has a pack.md), so the Sessions page and the runner find it.
        XCTAssertEqual(SessionCatalog.list(root: root), [plan.session])
    }

    func testTwoStartsInTheSameMinuteGetTwoFolders() throws {
        let root = try tempRoot()
        let utc = TimeZone(identifier: "UTC")!
        let a = try SessionCatalog.createAdhoc(now: now, route: .meeting, lang: "en", root: root, timeZone: utc)
        let b = try SessionCatalog.createAdhoc(now: now.addingTimeInterval(10), route: .meeting, lang: "en", root: root, timeZone: utc)
        let c = try SessionCatalog.createAdhoc(now: now, route: .meeting, lang: "en", root: root, timeZone: utc)
        XCTAssertEqual(a, "adhoc-20261014-1746-meeting")
        XCTAssertEqual(b, "adhoc-20261014-1746-meeting-2")
        XCTAssertEqual(c, "adhoc-20261014-1746-meeting-3")
    }

    func testPlanUsesAPreparedSessionAndCreatesNothing() throws {
        let root = try tempRoot()
        let e = event("e1", start: now)
        let plan = try QuickStart.plan(now: now, facts: .init(meetingAppHoldsMic: true), events: [e], remembered: ["e1": "mara"],
                                       sessions: ["mara"], lang: "en", root: root)
        XCTAssertEqual(plan, QuickStart.Plan(route: .meeting, mode: .prepared, session: "mara", lang: "en"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testAnOrdinarySessionFolderIsNotAdhoc() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("mara", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"lang":"en"}"#.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(AdhocMeta.read(sessionDir: dir))
        XCTAssertFalse(SessionCatalog.isAdhoc("mara"))
    }

    // MARK: double-press stop

    func testSecondPressInsideTheWindowStops() {
        var c = StopConfirm()
        XCTAssertEqual(c.press(running: false, now: now), .start)
        XCTAssertEqual(c.press(running: true, now: now), .arm)
        XCTAssertTrue(c.isArmed(now: now.addingTimeInterval(1.9)))
        XCTAssertEqual(c.press(running: true, now: now.addingTimeInterval(1.9)), .stop)
        XCTAssertFalse(c.isArmed(now: now.addingTimeInterval(2)), "stopping disarms")
    }

    func testAStrayPressNeverEndsACall() {
        var c = StopConfirm()
        XCTAssertEqual(c.press(running: true, now: now), .arm)
        XCTAssertFalse(c.isArmed(now: now.addingTimeInterval(2.1)), "the confirmation lapsed")
        // A press after the window is a new first press, not a stop.
        XCTAssertEqual(c.press(running: true, now: now.addingTimeInterval(2.5)), .arm)
        XCTAssertEqual(c.press(running: true, now: now.addingTimeInterval(10)), .arm)
        XCTAssertEqual(c.press(running: true, now: now.addingTimeInterval(11)), .stop, "only the second of two quick presses stops")
    }

    func testTheSessionEndingResetsTheConfirmation() {
        var c = StopConfirm()
        XCTAssertEqual(c.press(running: true, now: now), .arm)
        XCTAssertEqual(c.press(running: false, now: now.addingTimeInterval(0.5)), .start, "not running any more: a new session")
        XCTAssertEqual(c.press(running: true, now: now.addingTimeInterval(1)), .arm, "the earlier arming is gone")
        c.reset()
        XCTAssertFalse(c.isArmed(now: now.addingTimeInterval(1)))
    }

    /// The controller applies it with its injected clock and shows the confirmation state for the island.
    func testControllerArmsAndStopsWithTheInjectedClock() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        var t = now
        c.clock = { t }
        XCTAssertFalse(c.stopArmed)
        XCTAssertEqual(c.startStopKeyAction(running: true), .arm)
        XCTAssertTrue(c.stopArmed, "the island says \"Press ⌥⌘V again to stop\"")
        XCTAssertEqual(c.overlay.state.status, .stopConfirm, "and draws it")
        t = now.addingTimeInterval(1.5)
        XCTAssertEqual(c.startStopKeyAction(running: true), .stop)
        XCTAssertFalse(c.stopArmed)
        XCTAssertNil(c.overlay.state.status, "the second press takes the message down")
        t = now.addingTimeInterval(30)
        XCTAssertEqual(c.startStopKeyAction(running: true), .arm, "a lone press long after is only an arm")
        XCTAssertEqual(c.startStopKeyAction(running: false), .start)
        XCTAssertFalse(c.stopArmed)
    }

    func testANoticeLeavesTheOverlayAlone() throws {
        let model = OverlayModel()
        model.sessionStarting(lang: "en", session: "s", app: nil)
        let before = model.state
        let notice = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"me_conflicts","items":[{"me":"m1","pack":"f1","topic":"x"}]}"#))
        model.apply(.brain(notice))
        model.apply(.brain(try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"from_the_future"}"#))))
        XCTAssertEqual(model.state, before, "an unknown message type changes nothing")
    }

    // MARK: hot keys

    @MainActor
    final class FakeRegistrar: HotKeyRegistrar {
        var live: [Int: (spec: HotKeySpec, id: UInt32, action: @MainActor () -> Void)] = [:]
        var refuse: Set<UInt32> = []
        /// Combinations another app holds, by key code (for the ⇧< fallbacks, which share one id).
        var refuseKeyCodes: Set<UInt32> = []
        private(set) var tried: [HotKeySpec] = []
        private var next = 1
        func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int? {
            tried.append(spec)
            if refuse.contains(id) || refuseKeyCodes.contains(spec.keyCode) { return nil }
            defer { next += 1 }
            live[next] = (spec, id, action)
            return next
        }
        func unregister(_ token: Int) { live[token] = nil }
        func press(_ id: UInt32) { live.values.first { $0.id == id }?.action() }
    }

    func testKeysAreOptionCommand() {
        XCTAssertEqual(HotKeySpec.startStop.modifiers, UInt32(0x0800 | 0x0100), "option + command")
        XCTAssertEqual(HotKeySpec.startStop.keyCode, 9, "V")
        XCTAssertEqual(HotKeySpec.cardNow.modifiers, HotKeySpec.startStop.modifiers)
        XCTAssertEqual(HotKeySpec.cardNow.keyCode, 36, "Return")
    }

    func testStartKeyIsAlwaysOnAndCardNowOnlyWhileASessionRuns() {
        let reg = FakeRegistrar()
        var presses: [String] = []
        let keys = GlobalHotKeys(registrar: reg, onStartStop: { presses.append("start") }, onCardNow: { presses.append("card") },
                                 lessThanKeyCodes: { [50] })
        XCTAssertTrue(keys.registerStartStop())
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID])
        XCTAssertFalse(keys.cardNowRegistered, "⌥⌘↩ belongs to other apps until a session runs")

        keys.setSessionRunning(true)
        XCTAssertTrue(keys.cardNowRegistered)
        XCTAssertEqual(Set(reg.live.values.map(\.id)), [GlobalHotKeys.startStopID, GlobalHotKeys.cardNowID,
                                                       GlobalHotKeys.earlierAnswerID, GlobalHotKeys.newerAnswerID,
                                                       GlobalHotKeys.earlierAnswerShiftID])
        keys.setSessionRunning(true)
        XCTAssertEqual(reg.live.count, 5, "registering twice does not duplicate")
        reg.press(GlobalHotKeys.startStopID)
        reg.press(GlobalHotKeys.cardNowID)
        XCTAssertEqual(presses, ["start", "card"])

        keys.setSessionRunning(false)
        XCTAssertFalse(keys.cardNowRegistered)
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID], "⌥⌘V stays")
        keys.setSessionRunning(false)
        keys.unregisterAll()
        XCTAssertTrue(reg.live.isEmpty)
    }

    func testAKeyTakenByAnotherAppIsReported() {
        let reg = FakeRegistrar()
        reg.refuse = [GlobalHotKeys.startStopID]
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {}, lessThanKeyCodes: { [50] })
        XCTAssertFalse(keys.registerStartStop())
        XCTAssertFalse(keys.startStopRegistered)
        keys.setSessionRunning(true)
        XCTAssertTrue(keys.cardNowRegistered, "the other key is independent")
        keys.unregisterAll()
    }

    func testAnswerKeysAreOptionCommandArrowsOnlyWhileASessionRunsAndATakenOneIsReported() {
        XCTAssertEqual(HotKeySpec.earlierAnswer.modifiers, HotKeySpec.startStop.modifiers)
        XCTAssertEqual(HotKeySpec.earlierAnswer.keyCode, 123, "left arrow")
        XCTAssertEqual(HotKeySpec.newerAnswer.keyCode, 124, "right arrow")

        let reg = FakeRegistrar()
        reg.refuse = [GlobalHotKeys.newerAnswerID]
        var presses: [String] = []
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {},
                                 onEarlierAnswer: { presses.append("earlier") }, onNewerAnswer: { presses.append("newer") },
                                 lessThanKeyCodes: { [50] })
        XCTAssertTrue(keys.registerStartStop())
        XCTAssertFalse(keys.earlierAnswerRegistered, "not before a session")
        XCTAssertTrue(keys.unavailableAnswerKeys.isEmpty)

        keys.setSessionRunning(true)
        XCTAssertTrue(keys.earlierAnswerRegistered)
        XCTAssertFalse(keys.newerAnswerRegistered)
        XCTAssertEqual(keys.unavailableAnswerKeys, [.newerAnswer])
        reg.press(GlobalHotKeys.earlierAnswerID)
        XCTAssertEqual(presses, ["earlier"])

        keys.setSessionRunning(false)
        XCTAssertFalse(keys.earlierAnswerRegistered)
        XCTAssertTrue(keys.unavailableAnswerKeys.isEmpty)
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID])
        keys.unregisterAll()
    }

    func testShiftLessThanIsBackOnlyWhileASessionRunsWithFallbacksTriedInOrder() {
        let reg = FakeRegistrar()
        var presses: [String] = []
        var lookups = 0
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {},
                                 onEarlierAnswer: { presses.append("earlier") }, onNewerAnswer: { presses.append("newer") },
                                 lessThanKeyCodes: { lookups += 1; return LessThanKey.fallbacks })
        reg.refuseKeyCodes = [0x0A]
        XCTAssertTrue(keys.registerStartStop())
        XCTAssertEqual(lookups, 0, "the layout is read when a session starts, not at launch")
        XCTAssertFalse(keys.earlierAnswerShiftRegistered)

        keys.setSessionRunning(true)
        XCTAssertEqual(lookups, 1)
        XCTAssertTrue(keys.earlierAnswerShiftRegistered)
        XCTAssertEqual(keys.earlierAnswerShiftSpec, HotKeySpec(keyCode: 0x32, modifiers: 0x0200), "⇧ + grave, after ⇧ + ISO was refused")
        XCTAssertEqual(reg.tried.filter(\.isShiftLessThan).map(\.keyCode), [0x0A, 0x32])
        XCTAssertTrue(keys.unavailableAnswerKeys.isEmpty)
        reg.press(GlobalHotKeys.earlierAnswerShiftID)
        XCTAssertEqual(presses, ["earlier"], "⇧< is Back, never Forward")

        keys.setSessionRunning(true)
        XCTAssertEqual(lookups, 1, "registering twice neither looks up nor duplicates")
        XCTAssertEqual(reg.live.values.filter { $0.id == GlobalHotKeys.earlierAnswerShiftID }.count, 1)

        keys.setSessionRunning(false)
        XCTAssertFalse(keys.earlierAnswerShiftRegistered)
        XCTAssertNil(keys.earlierAnswerShiftSpec)
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID])
        keys.unregisterAll()
    }

    func testShiftLessThanTakenByAnotherAppIsReported() {
        let reg = FakeRegistrar()
        reg.refuse = [GlobalHotKeys.earlierAnswerShiftID]
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {}, lessThanKeyCodes: { [50] })
        keys.setSessionRunning(true)
        XCTAssertFalse(keys.earlierAnswerShiftRegistered)
        XCTAssertEqual(keys.unavailableAnswerKeys, [.shiftLessThan(keyCode: 50)])
        XCTAssertEqual(VerseController.keyLabel(.shiftLessThan(keyCode: 50)), "⇧<")
        XCTAssertTrue(keys.earlierAnswerRegistered, "⌥⌘← still works")
        keys.setSessionRunning(false)
        XCTAssertTrue(keys.unavailableAnswerKeys.isEmpty)
    }

    func testLessThanKeyIsTheKeyThatTypesItUnshiftedElseTheFallbacks() {
        // A Turkish-like layout: `<` on the key left of Z (0x32 here), `>` only with ⇧, so not seen unshifted.
        let turkish: [UInt16: String] = [0x06: "z", 0x32: "<", 0x0A: "\"", 0x2B: "ö"]
        XCTAssertEqual(LessThanKey.candidates { turkish[$0] }, [0x32])
        // A layout where `<` sits on the ISO key.
        XCTAssertEqual(LessThanKey.candidates { $0 == 0x0A ? "<" : "a" }, [0x0A])
        // A US-like layout: `<` needs ⇧ (on the comma key), so no key types it alone.
        let us: [UInt16: String] = [0x2B: ",", 0x32: "`", 0x0A: "§"]
        XCTAssertEqual(LessThanKey.candidates { us[$0] }, [0x0A, 0x32])
        XCTAssertEqual(LessThanKey.fallbacks, [0x0A, 0x32], "kVK_ISO_Section, then kVK_ANSI_Grave")
        // No layout data at all.
        XCTAssertEqual(LessThanKey.candidates(layoutData: nil, keyboardType: 0), [0x0A, 0x32])
        XCTAssertEqual(LessThanKey.candidates(layoutData: Data(), keyboardType: 0), [0x0A, 0x32])
        XCTAssertEqual(HotKeySpec.shiftLessThan(keyCode: 0x32).modifiers, 0x0200, "shift alone")
    }

    /// The real Carbon registration, on a combination nobody uses (⌃⌥⌘F19), so it cannot collide with a running Verse.
    func testCarbonRegistrationRoundTrip() throws {
        let odd = HotKeySpec(keyCode: 80 /* F19 */, modifiers: UInt32(0x1000 | 0x0800 | 0x0100))
        // Every session key gets an unused combination too (F18, F17, F16): ⌥⌘← and ⌥⌘→ must never be taken from the
        // running app by a test.
        let keys = GlobalHotKeys(startStop: odd, cardNow: HotKeySpec(keyCode: 79 /* F18 */, modifiers: odd.modifiers),
                                 earlierAnswer: HotKeySpec(keyCode: 64 /* F17 */, modifiers: odd.modifiers),
                                 newerAnswer: HotKeySpec(keyCode: 106 /* F16 */, modifiers: odd.modifiers),
                                 onStartStop: {}, onCardNow: {},
                                 lessThanKeyCodes: { [113 /* F15, with ⇧ */] })
        guard keys.registerStartStop() else { throw XCTSkip("the system refused the test hot key in this process") }
        keys.setSessionRunning(true)
        XCTAssertTrue(keys.cardNowRegistered)
        keys.setSessionRunning(false)
        keys.unregisterAll()
        XCTAssertFalse(keys.startStopRegistered)
        // Registering again after a full release works (the shared handler was released and is installed anew).
        XCTAssertTrue(keys.registerStartStop())
        keys.unregisterAll()
    }
}
