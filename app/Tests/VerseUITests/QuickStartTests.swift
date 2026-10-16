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
        t = now.addingTimeInterval(1.5)
        XCTAssertEqual(c.startStopKeyAction(running: true), .stop)
        XCTAssertFalse(c.stopArmed)
        t = now.addingTimeInterval(30)
        XCTAssertEqual(c.startStopKeyAction(running: true), .arm, "a lone press long after is only an arm")
        XCTAssertEqual(c.startStopKeyAction(running: false), .start)
        XCTAssertFalse(c.stopArmed)
    }

    // MARK: card now bridge

    func testCardNowBridgeOpensACardForTheNowTurn() throws {
        var b = CardNowBridge()
        b.noteOutbound(["type": .string("partial"), "turn_id": .string("r1"), "speaker": .string("room"), "text": .string("so what about the budget")])
        b.noteOutbound(["type": .string("partial"), "turn_id": .string("m1"), "speaker": .string("me"), "text": .string("my own words")])
        let delta: [String: JSONValue] = ["type": .string("delta"), "turn_id": .string("now-1"), "id": .string("F-now-1"), "tier": .string("F"), "text": .string("SAY: ")]
        let opening = try XCTUnwrap(b.opening(for: delta))
        guard case .outbound(let o) = opening else { return XCTFail("an outbound turn expected") }
        XCTAssertEqual(o[string: "turn_id"], "now-1")
        XCTAssertEqual(o[string: "text"], "so what about the budget", "the other side's words, not the owner's")
        XCTAssertEqual(o[string: "kind"], "question")
        XCTAssertEqual(o[string: "speaker"], "remote")
        XCTAssertNil(b.opening(for: delta), "once per now-turn")
        XCTAssertNil(b.opening(for: ["type": .string("delta"), "turn_id": .string("r1"), "id": .string("F1")]), "ordinary turns have their own")
        XCTAssertNil(b.opening(for: ["type": .string("status"), "state": .string("ready")]))

        // The overlay opens a card from it.
        let model = OverlayModel()
        model.sessionStarting(lang: "en", session: "adhoc", app: nil)
        model.apply(opening)
        XCTAssertNotNil(model.state.card)
        XCTAssertEqual(model.state.card?.turnID, "now-1")
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
        private var next = 1
        func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int? {
            if refuse.contains(id) { return nil }
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
        let keys = GlobalHotKeys(registrar: reg, onStartStop: { presses.append("start") }, onCardNow: { presses.append("card") })
        XCTAssertTrue(keys.registerStartStop())
        XCTAssertEqual(reg.live.values.map(\.id), [GlobalHotKeys.startStopID])
        XCTAssertFalse(keys.cardNowRegistered, "⌥⌘↩ belongs to other apps until a session runs")

        keys.setSessionRunning(true)
        XCTAssertTrue(keys.cardNowRegistered)
        XCTAssertEqual(Set(reg.live.values.map(\.id)), [GlobalHotKeys.startStopID, GlobalHotKeys.cardNowID])
        keys.setSessionRunning(true)
        XCTAssertEqual(reg.live.count, 2, "registering twice does not duplicate")
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
        let keys = GlobalHotKeys(registrar: reg, onStartStop: {}, onCardNow: {})
        XCTAssertFalse(keys.registerStartStop())
        XCTAssertFalse(keys.startStopRegistered)
        keys.setSessionRunning(true)
        XCTAssertTrue(keys.cardNowRegistered, "the other key is independent")
        keys.unregisterAll()
    }

    /// The real Carbon registration, on a combination nobody uses (⌃⌥⌘F19), so it cannot collide with a running Verse.
    func testCarbonRegistrationRoundTrip() throws {
        let odd = HotKeySpec(keyCode: 80 /* F19 */, modifiers: UInt32(0x1000 | 0x0800 | 0x0100))
        let keys = GlobalHotKeys(startStop: odd, cardNow: HotKeySpec(keyCode: 79 /* F18 */, modifiers: odd.modifiers),
                                 onStartStop: {}, onCardNow: {})
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
