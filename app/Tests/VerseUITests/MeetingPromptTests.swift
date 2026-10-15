import Foundation
import VerseMeet
@testable import VerseUI
import VerseTurns
import XCTest

/// A process table the test controls.
final class MicTable: AudioProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [AudioProcessInfo] = []
    func set(_ p: [AudioProcessInfo]) { lock.withLock { procs = p } }
    func snapshot() -> [AudioProcessInfo] { lock.withLock { procs } }
}

/// Tests never run the real prep (it would write into the user's sessions folder).
let neverPrepare: @Sendable (MeetingEvent, String) async throws -> URL = { _, _ in
    struct NotInTests: Error {}
    throw NotInTests()
}

struct NoCalendar: CalendarBackend {
    func authorization() -> CalendarAuthorization { .denied }
    func requestFullAccess() async throws -> Bool { false }
    func accountCount() -> Int { 0 }
    func entries(from: Date, to: Date) -> [CalendarEntry] { [] }
}

/// The app controller as the coordinator sees it.
@MainActor
final class FakeHost: MeetingHost {
    let settings: AppSettings
    let overlay = OverlayModel()
    var running = false
    var stopping = false
    var sessions: [String]
    var startCount = 0
    var startedWith: [String] = []
    var panelShown = 0
    var panelHidden = 0
    var logs: [String] = []

    init(sessions: [String] = ["mara-northwindlabs", "sample-interview"], selected: String = "sample-interview") {
        self.sessions = sessions
        settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        settings.sessionName = selected
    }

    func refreshSessions() {}
    func start() {
        startCount += 1
        startedWith.append(settings.sessionName)
        // What the real controller does: the overlay starts a session, which replaces any prompt.
        overlay.sessionStarting(lang: settings.language, session: settings.sessionName, app: nil)
        running = true
    }
    func showOverlayPanel() { panelShown += 1 }
    func hideOverlayPanel() { panelHidden += 1 }
    func log(_ line: String) { logs.append(line) }
}

@MainActor
func meetingSettings(detect: Bool = true, calendar: Bool = false, vault: Bool = false, vaultPath: String = "~/nowhere") -> MeetingSettings {
    let s = MeetingSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
    s.detectMeetings = detect
    s.useCalendar = calendar
    s.offerSummaryToVault = vault
    s.vaultPath = vaultPath
    return s
}

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("verse-w2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Meeting detection -> the notch prompt, and what the buttons do.
@MainActor
final class MeetingPromptTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    let cometMic = AudioProcessInfo(bundleID: "ai.perplexity.comet.helper", pid: 7, isRunningInput: true, isRunningOutput: true)
    let cometOnlyAudio = AudioProcessInfo(bundleID: "ai.perplexity.comet.helper", pid: 7, isRunningInput: false, isRunningOutput: true)

    private func event(_ title: String = "Mara / Northwind Labs call", id: String = "ev1") -> MeetingEvent {
        MeetingEvent(id: id, title: title, start: at(-60), end: at(1800), attendees: [], notes: nil,
                     url: URL(string: "https://meet.google.com/abc-defg-hij"), provider: .meet)
    }

    private func make(_ host: FakeHost, detect: Bool = true, prepare: (@Sendable (MeetingEvent, String) async throws -> URL)? = nil,
                      map: URL? = nil) throws -> MeetingCoordinator {
        let url: URL
        if let map { url = map } else { url = try tempDir().appendingPathComponent("map.json") }
        return MeetingCoordinator(host: host, settings: meetingSettings(detect: detect), calendar: CalendarSource(backend: NoCalendar()),
                                  detector: MeetingDetector(table: MicTable()), prepare: prepare ?? neverPrepare, upcoming: { _ in [] },
                                  eventMap: EventSessionMap(url: url), now: { self.t0 })
    }

    /// Runs the real detector over a fake process table and feeds its signals to the coordinator.
    private func detector(_ table: MicTable, event: MeetingEvent? = nil) -> MeetingDetector {
        MeetingDetector(table: table, eventLookup: { _ in event.map { [$0] } ?? [] })
    }

    private func detect(_ c: MeetingCoordinator, table: MicTable, event: MeetingEvent?, seconds: ClosedRange<Int>,
                        with d: MeetingDetector? = nil) async {
        let d = d ?? detector(table, event: event)
        for s in seconds { for sig in await d.tick(at: at(Double(s))) { c.handle(sig) } }
    }

    // MARK: detector -> prompt

    func testCometMicrophoneMakesThePromptAndStartsNothing() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 0...5)
        let p = try XCTUnwrap(host.overlay.state.meetingPrompt)
        XCTAssertEqual(p.title, "Meeting detected · Start Verse?")
        XCTAssertEqual(p.kind, .detected)
        XCTAssertEqual(p.acceptLabel, "Start")
        XCTAssertEqual(p.dismissLabel, "Dismiss")
        XCTAssertTrue(p.subtitle.contains("Comet"), p.subtitle)
        XCTAssertEqual(host.startCount, 0, "never starts without a click")
        XCTAssertGreaterThan(host.panelShown, 0, "the notch panel is shown for the question")
    }

    func testANormalTabPlayingAudioNeverPrompts() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        table.set([cometOnlyAudio])
        await detect(c, table: table, event: nil, seconds: 0...60)
        XCTAssertNil(host.overlay.state.meetingPrompt)
        // Mic use for less than the debounce is not a call either.
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 100...101)
        XCTAssertNil(host.overlay.state.meetingPrompt)
    }

    func testZoomAndTeamsAreDetectedToo() async throws {
        for (bundle, name) in [("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams")] {
            let host = FakeHost()
            let c = try make(host)
            let table = MicTable()
            table.set([AudioProcessInfo(bundleID: bundle, pid: 3, isRunningInput: true, isRunningOutput: true)])
            await detect(c, table: table, event: nil, seconds: 0...5)
            XCTAssertTrue(host.overlay.state.meetingPrompt?.subtitle.contains(name) ?? false, "\(name): \(String(describing: host.overlay.state.meetingPrompt))")
        }
    }

    func testMatchingCalendarEventIsNamedAndItsPreparedSessionUsed() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: event(), seconds: 0...5)
        let p = try XCTUnwrap(host.overlay.state.meetingPrompt)
        XCTAssertTrue(p.subtitle.contains("Mara / Northwind Labs call"), "names the event: \(p.subtitle)")
        XCTAssertTrue(p.subtitle.contains("session mara-northwindlabs"), "uses the session named like the event: \(p.subtitle)")
    }

    func testNoPromptWhileASessionRunsOrDetectionIsOff() async throws {
        let table = MicTable()
        table.set([cometMic])
        let busy = FakeHost()
        busy.running = true
        await detect(try make(busy), table: table, event: nil, seconds: 0...5)
        XCTAssertNil(busy.overlay.state.meetingPrompt)

        let off = FakeHost()
        await detect(try make(off, detect: false), table: table, event: nil, seconds: 0...5)
        XCTAssertNil(off.overlay.state.meetingPrompt)

        let practice = FakeHost()
        practice.overlay.simStarting(voice: "apple", showCaption: true)
        await detect(try make(practice), table: table, event: nil, seconds: 0...5)
        XCTAssertNil(practice.overlay.state.meetingPrompt, "a practice interview is running")
    }

    func testTheCallEndingBeforeAClickTakesTheQuestionBack() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        let d = detector(table)
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 0...5, with: d)
        XCTAssertNotNil(host.overlay.state.meetingPrompt)
        table.set([cometOnlyAudio])
        await detect(c, table: table, event: nil, seconds: 6...30, with: d)
        XCTAssertNil(host.overlay.state.meetingPrompt)
    }

    // MARK: buttons

    func testStartWithAPreparedSessionSelectsItStartsAndLeadsIntoTheReadyPanel() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: event(), seconds: 0...5)
        host.overlay.promptAction(.accept)
        XCTAssertEqual(host.startCount, 1)
        XCTAssertEqual(host.startedWith, ["mara-northwindlabs"])
        XCTAssertNil(host.overlay.state.meetingPrompt, "the prompt gives way to the session")
        guard case .starting? = host.overlay.state.startup?.phase else { return XCTFail("the start-up (Ready) panel takes over") }
        XCTAssertEqual(host.overlay.state.startup?.session, "mara-northwindlabs")
    }

    func testStartWithoutAnEventUsesTheSessionChosenInTheMenu() async throws {
        let host = FakeHost(selected: "sample-interview")
        let c = try make(host)
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 0...5)
        XCTAssertTrue(host.overlay.state.meetingPrompt?.subtitle.contains("session sample-interview") ?? false)
        host.overlay.promptAction(.accept)
        XCTAssertEqual(host.startedWith, ["sample-interview"])
    }

    func testDismissClosesWithoutStartingAndTheSameEventDoesNotAskAgain() async throws {
        let host = FakeHost()
        let c = try make(host)
        let table = MicTable()
        let d = detector(table, event: event())
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 0...5, with: d)
        host.overlay.promptAction(.dismiss)
        XCTAssertNil(host.overlay.state.meetingPrompt)
        XCTAssertEqual(host.startCount, 0)
        // The call drops and he rejoins the same meeting: the dismissed event stays dismissed.
        table.set([])
        await detect(c, table: table, event: nil, seconds: 6...30, with: d)
        table.set([cometMic])
        await detect(c, table: table, event: nil, seconds: 40...50, with: d)
        XCTAssertNil(host.overlay.state.meetingPrompt)
        let active = await d.activeMeetings
        XCTAssertEqual(active.count, 1, "the detector did see the second call")
    }

    func testStartWithoutAPreparedSessionPreparesFromTheInviteFirst() async throws {
        let host = FakeHost(sessions: ["sample-interview"])
        let prepared = expectation(description: "prepared")
        let root = try tempDir()
        let map = root.appendingPathComponent("map.json")
        let c = try make(host, prepare: { ev, lang in
            XCTAssertEqual(ev.title, "Quarterly review")
            XCTAssertEqual(lang, "en")
            prepared.fulfill()
            return root.appendingPathComponent("20261015-120000-abc123")
        }, map: map)
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: event("Quarterly review", id: "ev9"), seconds: 0...5)
        XCTAssertTrue(host.overlay.state.meetingPrompt?.subtitle.contains("prepares a session from the invite") ?? false)
        host.sessions.append("20261015-120000-abc123")   // the folder now exists
        host.overlay.promptAction(.accept)
        XCTAssertTrue(host.overlay.state.meetingPrompt?.busy ?? false, "preparing…")
        XCTAssertEqual(host.startCount, 0, "not started before the session exists")
        await fulfillment(of: [prepared], timeout: 5)
        for _ in 0..<100 where host.startCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.startedWith, ["20261015-120000-abc123"])
        XCTAssertEqual(EventSessionMap(url: map).load()["ev9"], "20261015-120000-abc123", "remembered for the next time")
    }

    func testAFailedPrepFallsBackToTheMenuSession() async throws {
        let host = FakeHost(sessions: ["sample-interview"], selected: "sample-interview")
        struct Boom: Error {}
        let c = try make(host, prepare: { _, _ in throw Boom() })
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: event("Quarterly review", id: "ev9"), seconds: 0...5)
        host.overlay.promptAction(.accept)
        for _ in 0..<100 where host.startCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.startedWith, ["sample-interview"])
    }

    func testDismissWhilePreparingCancelsTheStart() async throws {
        let host = FakeHost(sessions: ["sample-interview"])
        let c = try make(host, prepare: { _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return URL(fileURLWithPath: "/tmp/never")
        })
        let table = MicTable()
        table.set([cometMic])
        await detect(c, table: table, event: event("Quarterly review", id: "ev9"), seconds: 0...5)
        host.overlay.promptAction(.accept)
        XCTAssertTrue(host.overlay.state.meetingPrompt?.busy ?? false)
        host.overlay.promptAction(.dismiss)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(host.startCount, 0)
        XCTAssertNil(host.overlay.state.meetingPrompt)
    }

    // MARK: resolver

    func testResolver() {
        let sessions = ["mara-northwindlabs", "sample-interview"]
        func plan(_ title: String?, remembered: [String: String] = [:]) -> MeetingPrompt.SessionPlan {
            MeetingSessionResolver.plan(for: title.map { event($0) }, sessions: sessions, remembered: remembered, selected: "sample-interview")
        }
        XCTAssertEqual(plan("Mara / Northwind Labs call"), .prepared("mara-northwindlabs"))
        XCTAssertEqual(plan("Sample Interview"), .prepared("sample-interview"))
        XCTAssertEqual(plan("Quarterly review"), .fromInvite)
        XCTAssertEqual(plan("Quarterly review", remembered: ["ev1": "mara-northwindlabs"]), .prepared("mara-northwindlabs"))
        XCTAssertEqual(plan("Quarterly review", remembered: ["ev1": "gone"]), .fromInvite, "a remembered folder that is gone")
        XCTAssertEqual(plan(nil), .selected("sample-interview"))
        XCTAssertEqual(MeetingSessionResolver.plan(for: nil, sessions: [], remembered: [:], selected: nil), .selected(nil))
    }

    // MARK: upcoming meetings (ready before he joins)

    func testAnUpcomingMeetingWithAVideoLinkIsOfferedOnce() async throws {
        let host = FakeHost()
        let soon = MeetingEvent(id: "u1", title: "Mara / Northwind Labs call", start: at(240), end: at(2400), attendees: [], notes: nil,
                                url: URL(string: "https://zoom.us/j/123"), provider: .zoom)
        let noLink = MeetingEvent(id: "u2", title: "Lunch", start: at(60), end: at(900), provider: .other)
        let c = MeetingCoordinator(host: host, settings: meetingSettings(calendar: true), calendar: CalendarSource(backend: NoCalendar()),
                                   detector: MeetingDetector(table: MicTable()), prepare: neverPrepare, upcoming: { _ in [noLink, soon] },
                                   eventMap: EventSessionMap(url: try tempDir().appendingPathComponent("m.json")), now: { self.t0 })
        await c.pollUpcoming()
        let p = try XCTUnwrap(host.overlay.state.meetingPrompt)
        XCTAssertEqual(p.kind, .upcoming)
        XCTAssertEqual(p.title, "Meeting in 4 min · Start Verse?")
        XCTAssertTrue(p.subtitle.contains("session mara-northwindlabs"))
        XCTAssertEqual(host.startCount, 0)
        host.overlay.promptAction(.dismiss)
        await c.pollUpcoming()
        XCTAssertNil(host.overlay.state.meetingPrompt, "offered once")
    }

    func testNothingUpcomingWithoutTheCalendarSetting() async throws {
        let host = FakeHost()
        let soon = MeetingEvent(id: "u1", title: "Call", start: at(60), end: at(900), url: nil, provider: .meet)
        let c = MeetingCoordinator(host: host, settings: meetingSettings(calendar: false), calendar: CalendarSource(backend: NoCalendar()),
                                   detector: MeetingDetector(table: MicTable()), prepare: neverPrepare, upcoming: { _ in [soon] },
                                   eventMap: EventSessionMap(url: try tempDir().appendingPathComponent("m.json")), now: { self.t0 })
        await c.pollUpcoming()
        XCTAssertNil(host.overlay.state.meetingPrompt)
    }
}
