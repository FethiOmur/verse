import Foundation
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// A call that the automatic pick started on the room route moves to the meeting route when a meeting app takes the microphone
/// after Start (`QuickStart.MeetingRouteUpgrade`, the coordinator's hook and the controller's start path).
@MainActor
final class MeetingRouteUpgradeTests: XCTestCase {
    // MARK: the decision

    func testAutoPickedRoomMovesToTheMeetingRoute() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: false)
        XCTAssertTrue(u.meetingDetected(route: .room))
        XCTAssertTrue(u.attempted)
    }

    func testRoomPickedByHandIsNeverChanged() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: false, rehearsal: false)
        XCTAssertFalse(u.meetingDetected(route: .room))
        XCTAssertFalse(u.attempted)
    }

    func testRouteChangedByHandDuringTheCallIsHis() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: false)
        u.routeChosenByHand()
        XCTAssertFalse(u.meetingDetected(route: .room), "a room route he went back to during the call stays")
    }

    func testCallAlreadyOnTheMeetingRouteIsUntouched() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: false)
        XCTAssertFalse(u.meetingDetected(route: .meeting))
        XCTAssertFalse(u.attempted)
    }

    func testRehearsalIsUntouched() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: true)
        XCTAssertFalse(u.meetingDetected(route: .room))
        var manual = QuickStart.MeetingRouteUpgrade(autoPicked: false, rehearsal: true)
        XCTAssertFalse(manual.meetingDetected(route: .room))
    }

    func testDetectionFiringTwiceSwitchesOnce() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: false)
        XCTAssertTrue(u.meetingDetected(route: .room))
        // The switch failed or has not landed yet: the route still reads room, and a second detection still does nothing.
        XCTAssertFalse(u.meetingDetected(route: .room))
        XCTAssertFalse(u.meetingDetected(route: .meeting))
    }

    func testDetectionDuringAnotherSwitchIsSkippedWithoutUsingTheMoveUp() {
        var u = QuickStart.MeetingRouteUpgrade(autoPicked: true, rehearsal: false)
        XCTAssertFalse(u.meetingDetected(route: .room, switching: true))
        XCTAssertFalse(u.attempted)
        XCTAssertTrue(u.meetingDetected(route: .room), "the next detection after the other change still moves the call")
    }

    // MARK: the coordinator tells the host

    private final class RunHost: MeetingHost {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let overlay = OverlayModel()
        var running = false
        var stopping = false
        var sessions: [String] = ["sample-call"]
        var detectedDuringRun: [String] = []
        func refreshSessions() {}
        func start() {}
        func startUnprepared() {}
        func showOverlayPanel() {}
        func hideOverlayPanel() {}
        func log(_ line: String) {}
        func meetingDetectedDuringRun(appName: String) { detectedDuringRun.append(appName) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func detect(_ host: RunHost) async throws {
        let map = try tempDir().appendingPathComponent("map.json")
        let table = MicTable()
        table.set([AudioProcessInfo(bundleID: "us.zoom.xos", pid: 3, isRunningInput: true, isRunningOutput: true)])
        let c = MeetingCoordinator(host: host, settings: meetingSettings(), calendar: CalendarSource(backend: NoCalendar()),
                                   detector: MeetingDetector(table: table), upcoming: { _ in [] },
                                   eventMap: EventSessionMap(url: map), now: { self.t0 })
        let d = MeetingDetector(table: table, eventLookup: { _ in [] })
        for s in 0...5 { for sig in await d.tick(at: t0.addingTimeInterval(Double(s))) { c.handle(sig) } }
    }

    func testMeetingDetectedWhileACallRunsTellsTheHostAndShowsNoPrompt() async throws {
        let host = RunHost()
        host.running = true
        try await detect(host)
        XCTAssertEqual(host.detectedDuringRun, ["Zoom"])
        XCTAssertNil(host.overlay.state.meetingPrompt)
    }

    func testNoHookWithoutARunningCallOrWhileItStops() async throws {
        let idle = RunHost()
        try await detect(idle)
        XCTAssertEqual(idle.detectedDuringRun, [], "no call: the prompt is the answer")
        XCTAssertNotNil(idle.overlay.state.meetingPrompt)

        let stopping = RunHost()
        stopping.running = true
        stopping.stopping = true
        try await detect(stopping)
        XCTAssertEqual(stopping.detectedDuringRun, [])
    }

    // MARK: the controller's start path

    private func controller(meetingAppHoldsMic: Bool) throws -> (VerseController, () -> [LaunchRequest]) {
        let root = try tempDir()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        c.sessionsRoot = root
        c.clock = { self.t0 }
        c.eventSessions = EventSessionMap(url: root.appendingPathComponent("event-sessions.json"))
        c.eventsAround = { _ in [] }
        c.routeFacts = { QuickStart.RouteFacts(phoneCallActive: false, meetingAppHoldsMic: meetingAppHoldsMic) }
        c.refreshSessions()
        var launches: [LaunchRequest] = []
        c.launchOverride = { launches.append($0) }
        return (c, { launches })
    }

    func testStartNowMarksTheAutomaticRoomPick() throws {
        let (c, launches) = try controller(meetingAppHoldsMic: false)
        c.startNow()
        let l = try XCTUnwrap(launches().last)
        XCTAssertEqual(l.route, .room)
        XCTAssertTrue(l.autoRoute, "no Audio source override: the room route may move to the meeting route later")
    }

    func testStartNowWithTheAudioSourceOverrideIsNotAutomatic() throws {
        let (c, launches) = try controller(meetingAppHoldsMic: false)
        c.chooseRoute(.room)
        c.startNow()
        let l = try XCTUnwrap(launches().last)
        XCTAssertEqual(l.route, .room)
        XCTAssertFalse(l.autoRoute, "a room route picked by hand is never changed")
    }

    func testTheHookDoesNothingWithoutARunningCall() throws {
        let (c, _) = try controller(meetingAppHoldsMic: false)
        c.meetingDetectedDuringRun(appName: "Zoom")
        XCTAssertFalse(c.routeUpgrade.attempted)
    }
}
