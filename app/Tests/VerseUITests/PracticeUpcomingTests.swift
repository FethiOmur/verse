import AppKit
import Combine
import Foundation
import SwiftUI
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

// Practice from an upcoming calendar meeting: the Meeting picker's Prepared and Upcoming groups, and "Build interview" for an
// event with no prepared session (event prep, then the practice interview). Everything is fictional (Harbor & Pine Analytics,
// Northwind Labs, Lantern Health) and the calendar is a fake backend: nothing here reads the user's calendar, sessions,
// settings or Keychain.

private var brainDir: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
}

private var fixtureSession: URL { brainDir.appendingPathComponent("tests/fixtures/sim_session", isDirectory: true) }

private func scratch() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-upcoming-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A prepared session folder under `root`.
@discardableResult
private func makeSession(_ name: String, in root: URL, bank: Int = 0, created: String? = nil) throws -> URL {
    let d = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try Data("## FACTS\n[f001] name | A fact. | x | prep:L1\n".utf8).write(to: d.appendingPathComponent("pack.md"))
    if bank > 0 {
        let lines = (1...bank).map { #"{"id":"b\#(String(format: "%03d", $0))","question":"Question \#($0)?"}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: d.appendingPathComponent("bank.jsonl"))
    }
    if let created { try Data(#"{"created_at":"\#(created)","languages":["en"]}"#.utf8).write(to: d.appendingPathComponent("meta.json")) }
    return d
}

/// Tuesday 20 October 2026, 12:00 local, and days/times around it.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
}

private let noon = at(20, 12)

private func event(_ id: String, _ title: String, start: Date, minutes: Double = 30) -> MeetingEvent {
    MeetingEvent(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60))
}

/// A real meeting by the Upcoming rule (it has a Meet link), so the lists keep it.
private func entry(_ id: String, _ title: String, start: Date, minutes: Double = 30) -> CalendarEntry {
    CalendarEntry(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                  url: URL(string: "https://meet.google.com/abc-defg-hij"))
}

/// The part of the calendar store the source needs, with nothing behind it. Counts the access prompts it was asked for.
private final class FakeCalendar: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let status: CalendarAuthorization
    private let all: [CalendarEntry]
    private var asked = 0
    var requests: Int { lock.withLock { asked } }

    init(status: CalendarAuthorization = .fullAccess, entries: [CalendarEntry] = []) {
        self.status = status
        self.all = entries
    }

    func authorization() -> CalendarAuthorization { status }
    func requestFullAccess() async throws -> Bool { lock.withLock { asked += 1 }; return false }
    func accountCount() -> Int { 1 }
    func entries(from: Date, to: Date) -> [CalendarEntry] { all.filter { $0.end > from && $0.start < to } }
}

@MainActor
private struct Rig {
    let sim: SimController
    let controller: VerseController
    let settings: AppSettings
    let upNext: HomeUpNextModel
    let eventMap: EventSessionMap
    let root: URL
    let calendar: FakeCalendar
    /// Session folder names `onPrepared` was told about.
    let prepared: PreparedLog
}

@MainActor
private final class PreparedLog { var names: [String] = [] }

@MainActor
private func makeRig(root: URL, calendar: FakeCalendar, useCalendar: Bool = true, fakeBrain: Bool = false,
                      prepare: @escaping @Sendable (MeetingEvent, String) async throws -> URL = { _, _ in
                          struct NotInTests: Error {}
                          throw NotInTests()
                      }) -> Rig {
    let defaults = UserDefaults(suiteName: "dev.example.verse.test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.useMeProfile = false
    settings.fakeBrain = fakeBrain
    let meetingSettings = MeetingSettings(defaults: defaults)
    meetingSettings.useCalendar = useCalendar
    let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
    controller.sessionsRoot = root
    let map = EventSessionMap(url: root.appendingPathComponent("event-sessions.json"))
    let log = PreparedLog()
    let upNext = HomeUpNextModel(settings: settings, meeting: meetingSettings, sessions: { [] }, calendar: CalendarSource(backend: calendar),
                                 eventMap: map, prepare: prepare, onPrepared: { log.names.append($0) })
    let sim = SimController(settings: settings, simSettings: SimSettings(defaults: defaults), meeting: controller,
                            meProfile: root.appendingPathComponent("no-profile"), now: { noon })
    sim.attachUpcoming(upNext)
    return Rig(sim: sim, controller: controller, settings: settings, upNext: upNext, eventMap: map, root: root, calendar: calendar,
               prepared: log)
}

// MARK: - the two groups

final class PracticeUpcomingTestsGroups: XCTestCase {
    private func prepared(_ names: [String], in root: URL) throws -> [PreparedMeeting] {
        for n in names { try makeSession(n, in: root) }
        return PracticeMeetings.list(root: root)
    }

    func testEventsWithoutASessionAreUpcomingAndEventsWithOneAppearOnceUnderPrepared() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try prepared(["northwind-labs-technical", "lantern-health-first-call", "harbor-pine-intro"], in: root)
        let events = [
            event("e-remembered", "Call with the Lantern team", start: at(22, 9)),
            event("e-named", "Northwind Labs technical", start: at(21, 15)),
            event("e-new1", "Design review with Ingrid", start: at(21, 10)),
            event("e-new2", "Tideline Studio first call", start: at(27, 16, 30)),
        ]
        let g = PracticeMeetings.groups(prepared: list, events: events, remembered: ["e-remembered": "lantern-health-first-call"], now: noon)
        XCTAssertEqual(g.upcoming.map(\.id), ["e-new1", "e-new2"], "soonest first; the two events with a session are not here")
        XCTAssertEqual(g.prepared.count, 3)
        XCTAssertEqual(g.prepared.first { $0.name == "lantern-health-first-call" }?.eventStart, at(22, 9), "remembered by event id")
        XCTAssertEqual(g.prepared.first { $0.name == "northwind-labs-technical" }?.eventStart, at(21, 15), "matched by name")
        XCTAssertNil(g.prepared.first { $0.name == "harbor-pine-intro" }?.eventStart, "a session with no event has no date")
        let all = g.prepared.map(\.name) + g.upcoming.map(\.id)
        XCTAssertEqual(Set(all).count, all.count, "nothing is listed twice")
    }

    func testTheWindowIsFourteenDays() throws {
        let window = PracticeMeetings.upcomingWindow
        XCTAssertEqual(window, 14 * 86_400)
        let events = [
            event("inside", "Inside", start: noon.addingTimeInterval(window - 60)),
            event("edge", "Edge", start: noon.addingTimeInterval(window)),
            event("outside", "Outside", start: noon.addingTimeInterval(window + 1)),
            event("running", "Running now", start: noon.addingTimeInterval(-600), minutes: 30),
            event("over", "Already over", start: noon.addingTimeInterval(-3_600), minutes: 30),
        ]
        let g = PracticeMeetings.groups(prepared: [], events: events, remembered: [:], now: noon)
        XCTAssertEqual(g.upcoming.map(\.id), ["running", "inside", "edge"])
    }

    func testARecurringEventIsListedOnceAtItsNextOccurrence() {
        let events = (0..<5).map { event("weekly", "Weekly sync with Mira", start: at(21 + $0, 10)) } + [event("one-off", "One-off", start: at(22, 8))]
        let g = PracticeMeetings.groups(prepared: [], events: events, remembered: [:], now: noon)
        XCTAssertEqual(g.upcoming.map(\.id), ["weekly", "one-off"])
        XCTAssertEqual(g.upcoming.first?.start, at(21, 10))
    }

    func testARecurringEventWithASessionShowsItsNextDate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try prepared(["weekly-sync"], in: root)
        let events = [event("weekly", "Weekly sync", start: at(23, 10)), event("weekly", "Weekly sync", start: at(21, 10))]
        let g = PracticeMeetings.groups(prepared: list, events: events, remembered: ["weekly": "weekly-sync"], now: noon)
        XCTAssertTrue(g.upcoming.isEmpty)
        XCTAssertEqual(g.prepared.first?.eventStart, at(21, 10), "the soonest occurrence")
    }

    func testNoEventsLeavesOnlyThePreparedGroup() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try prepared(["northwind-labs-technical"], in: root)
        let g = PracticeMeetings.groups(prepared: list, events: [], remembered: [:], now: noon)
        XCTAssertEqual(g.prepared.map(\.name), ["northwind-labs-technical"])
        XCTAssertTrue(g.upcoming.isEmpty)
        XCTAssertTrue(PracticeMeetings.groups(prepared: [], events: [], remembered: [:], now: noon).isEmpty)
        XCTAssertTrue(PracticeMeetings.menu(g, now: noon).upcoming.isEmpty)
    }

    func testRowsAreTitleThenDayAndTime() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = try prepared(["northwind-labs-technical", "harbor-pine-intro"], in: root)
        let events = [
            event("a", "Northwind Labs technical", start: at(20, 15)),
            event("b", "Design review with Ingrid", start: at(21, 10)),
            event("c", "Tideline Studio first call", start: at(23, 14, 30)),
        ]
        let g = PracticeMeetings.groups(prepared: list, events: events, remembered: [:], now: noon)
        let menu = PracticeMeetings.menu(g, now: noon)
        XCTAssertEqual(menu.prepared.map(\.label).sorted(), ["Harbor Pine Intro", "Northwind Labs Technical · Today 15:00"].sorted(),
                       "the prepared row carries its event's date; one with no event is just the title")
        XCTAssertEqual(menu.upcoming.map(\.label), ["Design review with Ingrid · Tomorrow 10:00",
                                                    "Tideline Studio first call · Fri 23 Oct 14:30"])
        XCTAssertEqual(menu.upcoming.map(\.id), [.upcoming("b"), .upcoming("c")])
        XCTAssertEqual(PracticeMeetings.label("Plain", at: nil, now: noon), "Plain")
    }

    func testAnEventWithoutATitleStillHasARow() {
        let g = PracticeMeetings.groups(prepared: [], events: [event("x", "  ", start: at(21, 9))], remembered: [:], now: noon)
        XCTAssertEqual(g.upcoming.first?.title, "Untitled event")
    }
}

// MARK: - the controller: reading the calendar

@MainActor
final class PracticeUpcomingTestsController: XCTestCase {
    private let events = [entry("e1", "Design review with Ingrid", start: at(21, 10)), entry("e2", "Tideline Studio first call", start: at(24, 16))]

    func testUpcomingGroupFillsFromTheCalendar() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root, bank: 3)
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: events))
        rig.sim.refreshMeetings()
        XCTAssertTrue(rig.sim.groups.upcoming.isEmpty, "nothing is read until the page asks")
        await rig.sim.refreshUpcoming()
        XCTAssertEqual(rig.sim.groups.upcoming.map(\.id), ["e1", "e2"])
        XCTAssertEqual(rig.sim.groups.prepared.map(\.name), ["northwind-labs-technical"])
        XCTAssertEqual(rig.sim.meetingName, "northwind-labs-technical", "the default pick is still a prepared meeting")
        XCTAssertNil(rig.sim.upcomingEventID)
        XCTAssertEqual(rig.sim.meetingPreview?.questions, 3)
    }

    func testNoCalendarAccessHidesTheGroupAndNothingBreaks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root)
        for status in [CalendarAuthorization.denied, .notDetermined, .writeOnly, .restricted] {
            let cal = FakeCalendar(status: status, entries: events)
            let rig = makeRig(root: root, calendar: cal)
            rig.sim.refreshMeetings()
            await rig.sim.refreshUpcoming()
            XCTAssertTrue(rig.sim.groups.upcoming.isEmpty, "\(status)")
            XCTAssertTrue(PracticeMeetings.menu(rig.sim.groups, now: noon).upcoming.isEmpty, "\(status)")
            XCTAssertEqual(rig.sim.meetingName, "northwind-labs-technical", "\(status)")
            XCTAssertEqual(cal.requests, 0, "the page never asks for calendar access (\(status))")
        }
    }

    func testCalendarOffAndNoEventsHideTheGroup() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root)
        let off = makeRig(root: root, calendar: FakeCalendar(entries: events), useCalendar: false)
        off.sim.refreshMeetings()
        await off.sim.refreshUpcoming()
        XCTAssertTrue(off.sim.groups.upcoming.isEmpty, "\"Use my calendar\" is off")
        let empty = makeRig(root: root, calendar: FakeCalendar(entries: []))
        empty.sim.refreshMeetings()
        await empty.sim.refreshUpcoming()
        XCTAssertTrue(empty.sim.groups.upcoming.isEmpty)
        XCTAssertFalse(empty.sim.groups.isEmpty, "the prepared group is still there")
        // No source at all (the page was never wired): the same.
        let bare = makeRig(root: root, calendar: FakeCalendar(entries: events))
        bare.sim.attachUpcoming(nil)
        await bare.sim.refreshUpcoming()
        XCTAssertTrue(bare.sim.groups.upcoming.isEmpty)
    }

    func testChoosingAnUpcomingEventShowsTheNotPreparedStateAndEnablesBuild() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root, bank: 3)
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: events))
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        rig.sim.choose(.upcoming("e1"))
        XCTAssertEqual(rig.sim.choice, .upcoming("e1"))
        XCTAssertEqual(rig.sim.selectedUpcoming?.title, "Design review with Ingrid")
        XCTAssertNil(rig.sim.meetingName)
        XCTAssertNil(rig.sim.meetingPreview, "no counts: there is no prep to count")
        XCTAssertNil(rig.sim.selectedMeeting)
        XCTAssertTrue(rig.sim.canPrepare, "Build interview runs the invite prep first")
        // Back to a prepared one.
        rig.sim.choose(.prepared("northwind-labs-technical"))
        XCTAssertNil(rig.sim.upcomingEventID)
        XCTAssertEqual(rig.sim.meetingPreview?.questions, 3)
        // A refresh keeps an upcoming choice, and an unknown event changes nothing.
        rig.sim.choose(.upcoming("e2"))
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        XCTAssertEqual(rig.sim.choice, .upcoming("e2"))
        rig.sim.choose(.upcoming("nope"))
        XCTAssertEqual(rig.sim.choice, .upcoming("e2"))
    }

    func testOnlyUpcomingEventsStillOfferAMeeting() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: events))
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        XCTAssertEqual(rig.sim.setup.source, .posting, "nothing prepared: the default stays the job posting")
        XCTAssertTrue(rig.sim.meetings.isEmpty)
        rig.sim.chooseSource(.meeting)
        XCTAssertEqual(rig.sim.setup.source, .meeting)
        XCTAssertEqual(rig.sim.choice, .upcoming("e1"), "the soonest event is selected")
        rig.sim.refreshMeetings()
        XCTAssertEqual(rig.sim.setup.source, .meeting, "kept: the popup has rows")
        // No prepared meeting and no calendar events: the old fallback.
        let none = makeRig(root: root, calendar: FakeCalendar(entries: []))
        none.sim.chooseSource(.meeting)
        none.sim.refreshMeetings()
        XCTAssertEqual(none.sim.setup.source, .posting)
    }

    func testAnEventThatGetsASessionMovesFromUpcomingToPrepared() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root)
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: events))
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        rig.sim.choose(.upcoming("e1"))
        // Prepared elsewhere (the Prepare page's button): the map now knows the event.
        try makeSession("design-review-ingrid", in: root)
        rig.eventMap.remember(eventID: "e1", session: "design-review-ingrid")
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        XCTAssertEqual(rig.sim.groups.upcoming.map(\.id), ["e2"])
        XCTAssertEqual(rig.sim.groups.prepared.first { $0.name == "design-review-ingrid" }?.eventStart, at(21, 10))
        XCTAssertNil(rig.sim.upcomingEventID, "the stale upcoming choice is dropped")
        XCTAssertNotNil(rig.sim.meetingName)
    }

    /// The page wires the model itself: hosting it reads the calendar and fills the popup.
    func testThePageReadsTheCalendarWhenItAppears() async throws {
        _ = NSApplication.shared
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession("northwind-labs-technical", in: root)
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: events))
        rig.sim.attachUpcoming(nil)
        let router = HomeRouter()
        let view = SimSetupView(sim: rig.sim, meeting: rig.controller, upNext: rig.upNext, router: router)
            .environment(\.colorScheme, .light).frame(width: 900, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<150 where rig.sim.groups.upcoming.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.sim.groups.upcoming.map(\.id), ["e1", "e2"])
    }
}

// MARK: - the shared event prep

@MainActor
final class PracticeUpcomingTestsEventPrep: XCTestCase {
    func testPrepareSessionRemembersTheEventAndTellsTheApp() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(root: root, calendar: FakeCalendar(), prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/20261020-100000-abcd1234") })
        let dir = try await rig.upNext.prepareSession(for: event("e9", "Design review", start: at(21, 10)))
        XCTAssertEqual(dir.lastPathComponent, "20261020-100000-abcd1234")
        XCTAssertEqual(rig.eventMap.load()["e9"], "20261020-100000-abcd1234")
        XCTAssertEqual(rig.upNext.rememberedSessions["e9"], "20261020-100000-abcd1234")
        XCTAssertEqual(rig.prepared.names, ["20261020-100000-abcd1234"])
    }

    func testTheUpNextButtonStillGoesThroughTheSamePath() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(root: root, calendar: FakeCalendar(), prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/design-review") })
        let e = event("e10", "Design review", start: at(21, 10))
        rig.upNext.setItems([HomeUpNextItem(id: "e10", title: "Design review", meta: "Tomorrow", session: nil, event: e)])
        rig.upNext.prepare(rig.upNext.items[0])
        for _ in 0..<150 where rig.prepared.names.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.prepared.names, ["design-review"])
        XCTAssertEqual(rig.eventMap.load()["e10"], "design-review")
    }

    func testUpcomingEventsAreGatedOnTheCalendarSettingAndAccess() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [entry("a", "A", start: at(21, 10)), entry("b", "B", start: at(30, 10, 0, month: 11))]
        let on = makeRig(root: root, calendar: FakeCalendar(entries: entries))
        let got = await on.upNext.upcomingEvents(within: PracticeMeetings.upcomingWindow, now: noon)
        XCTAssertEqual(got.map(\.id), ["a"], "only what the window reaches")
        let denied = makeRig(root: root, calendar: FakeCalendar(status: .denied, entries: entries))
        let none = await denied.upNext.upcomingEvents(within: PracticeMeetings.upcomingWindow, now: noon)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(denied.calendar.requests, 0)
    }

    /// Step 1's command line: the event travels as a file; neither its notes nor its attendees are on the line.
    func testEventPrepArgvGoldenAndNothingPersonalOnTheLine() async throws {
        final class Recorder: CommandRunning, @unchecked Sendable {
            private let lock = NSLock()
            var calls: [[String]] = []
            var eventFileText = ""
            func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
                lock.withLock { calls.append(arguments) }
                if let i = arguments.firstIndex(of: "--from-event") {
                    let text = (try? String(contentsOfFile: arguments[i + 1], encoding: .utf8)) ?? ""
                    lock.withLock { eventFileText = text }
                }
                return CommandResult(status: 0, stdout: "session: /tmp/sessions/design-review\n", stderr: "")
            }
        }
        let recorder = Recorder()
        let prep = CalendarPrep(brainDir: brainDir, python: URL(fileURLWithPath: "/usr/bin/true"), outRoot: URL(fileURLWithPath: "/tmp/sessions"),
                                fake: true, runner: recorder)
        var e = event("e11", "Design review with Ingrid", start: at(21, 10))
        e.notes = "SECRET-NOTES-4711 agenda"
        e.attendees = [Attendee(name: "Ingrid Solberg", email: "ingrid@example.invalid")]
        let dir = try await prep.makeSession(for: e, lang: "en")
        XCTAssertEqual(dir.path, "/tmp/sessions/design-review")
        let argv = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(argv.count, 9, "\(argv)")
        XCTAssertEqual(Array(argv[0..<3]), ["-m", "verse_brain.prep", "--from-event"])
        XCTAssertTrue(argv[3].hasSuffix("/event.json"), argv[3])
        XCTAssertEqual(Array(argv[4...]), ["--lang", "en", "--out", "/tmp/sessions", "--fake"])
        let line = argv.joined(separator: " ")
        for banned in ["SECRET-NOTES", "Ingrid", "ingrid@example", "Design review", "sk-ant", "api-key", "--key"] {
            XCTAssertFalse(line.contains(banned), "\(banned) is on the line: \(line)")
        }
        XCTAssertTrue(recorder.eventFileText.contains("SECRET-NOTES-4711"), "the event reaches prep through its file")
    }

    /// The app's real path: no `--fake`, the spend cap instead, still no key, notes or attendees on the line.
    func testLiveEventPrepArgvGoldenHasNoKey() async throws {
        final class Recorder: CommandRunning, @unchecked Sendable {
            private let lock = NSLock()
            var calls: [[String]] = []
            func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
                lock.withLock { calls.append(arguments) }
                return CommandResult(status: 0, stdout: "session: /tmp/sessions/design-review\n", stderr: "")
            }
        }
        let recorder = Recorder()
        let prep = CalendarPrep.live(brainDir: brainDir, python: URL(fileURLWithPath: "/usr/bin/true"),
                                     outRoot: URL(fileURLWithPath: "/tmp/sessions"), runner: recorder)
        XCTAssertFalse(prep.fake)
        var e = event("e12", "Design review with Ingrid", start: at(21, 10))
        e.notes = "SECRET-NOTES-4711 agenda"
        e.attendees = [Attendee(name: "Ingrid Solberg", email: "ingrid@example.invalid")]
        _ = try await prep.makeSession(for: e, lang: "en")
        let argv = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(Array(argv[0..<3]), ["-m", "verse_brain.prep", "--from-event"])
        XCTAssertEqual(Array(argv[4...]), ["--lang", "en", "--out", "/tmp/sessions", "--budget-usd", "0.45"], "\(argv)")
        let line = argv.joined(separator: " ")
        for banned in ["--fake", "SECRET-NOTES", "Ingrid", "ingrid@example", "sk-ant", "api-key", "--key", "ANTHROPIC"] {
            XCTAssertFalse(line.contains(banned), "\(banned) is on the line: \(line)")
        }
    }

    /// Step 2's command line for the session step 1 made: paths and choices only, nothing from the profile or the pack.
    func testInterviewArgvGoldenForTheSessionTheInviteMade() {
        var s = SimSetup(postingText: "")
        s.source = .meeting
        s.meetingSession = URL(fileURLWithPath: "/tmp/sessions/20261020-100000-abcd1234")
        s.meFile = URL(fileURLWithPath: "/tmp/profile/me.md")
        s.fake = true
        let a = s.prepArguments(sessionDir: s.meetingSession!, out: URL(fileURLWithPath: "/tmp/sessions"))
        XCTAssertEqual(a, ["-u", "-m", "verse_brain.prep", "--sim", "--from-session", "/tmp/sessions/20261020-100000-abcd1234", "--me",
                           "/tmp/profile/me.md", "--out", "/tmp/sessions", "--type", "mixed", "--difficulty", "standard", "--length", "30",
                           "--fake"])
    }
}

// MARK: - the two-step flow, offline

@MainActor
final class PracticeUpcomingTestsFlow: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("VERSE_BRAIN_DIR", brainDir.path, 1)
    }

    override func tearDown() {
        unsetenv("VERSE_BRAIN_DIR")
        super.tearDown()
    }

    private func requireBrain() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: brainDir.appendingPathComponent(".venv/bin/python").path), "brain/.venv missing")
    }

    private func simFolders(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("sim-") }.sorted()
    }

    private func waitForEnd(_ sim: SimController) async throws {
        for _ in 0..<600 where sim.phase == .preparing { try await Task.sleep(for: .milliseconds(100)) }
    }

    /// Event prep (a copy of the brain's fictional prepared session stands in for the offline event prep) and then the real
    /// `--sim --from-session --fake` prep: ends in a sim folder built from the new session, with both steps shown.
    func testBuildInterviewForAnUpcomingEventRunsBothSteps() async throws {
        try requireBrain()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let newSession = root.appendingPathComponent("20261020-100000-abcd1234", isDirectory: true)
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: [entry("e1", "Harbor & Pine Analytics intro", start: at(22, 10))]), fakeBrain: true,
                          prepare: { _, _ in
                              try FileManager.default.copyItem(at: fixtureSession, to: newSession)
                              return newSession
                          })
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        rig.sim.chooseSource(.meeting)
        XCTAssertEqual(rig.sim.choice, .upcoming("e1"))
        XCTAssertTrue(rig.sim.canPrepare)
        var steps: [SimController.PrepStep?] = []
        let sub = rig.sim.$prepStep.sink { steps.append($0) }
        defer { sub.cancel() }

        rig.sim.prepare()
        XCTAssertEqual(rig.sim.phase, .preparing)
        XCTAssertEqual(rig.sim.prepStep, .invite, "step 1 shows at once")
        try await waitForEnd(rig.sim)

        XCTAssertEqual(rig.sim.phase, .prepared, "\(rig.sim.prepError ?? "") \(rig.sim.prepLines.suffix(3))")
        XCTAssertEqual(steps.compactMap { $0 }, [.invite, .interview], "both steps were shown, in order: \(steps)")
        XCTAssertNil(rig.sim.prepStep, "cleared at the end")
        let dir = try XCTUnwrap(rig.sim.sessionDir)
        XCTAssertEqual(simFolders(root), [dir.lastPathComponent])
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("sim-") && dir.lastPathComponent.hasSuffix("-20261020-100000-abcd1234"), dir.lastPathComponent)
        XCTAssertEqual(rig.sim.summary?.sourceSession, "20261020-100000-abcd1234", "built from the session step 1 made")
        // Step 1 left the event mapped to its session, and the popup now lists it under Prepared.
        XCTAssertEqual(rig.eventMap.load()["e1"], "20261020-100000-abcd1234")
        XCTAssertEqual(rig.prepared.names, ["20261020-100000-abcd1234"])
        XCTAssertEqual(rig.sim.meetingName, "20261020-100000-abcd1234")
        XCTAssertNil(rig.sim.upcomingEventID)
        XCTAssertTrue(rig.sim.groups.upcoming.isEmpty)
        XCTAssertEqual(rig.sim.groups.prepared.first?.eventStart, at(22, 10), "the date follows the session")
    }

    func testAFailedInvitePrepStopsBeforeTheInterview() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        struct NoInvite: Error {}
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: [entry("e1", "Harbor & Pine Analytics intro", start: at(22, 10))]), fakeBrain: true,
                          prepare: { _, _ in throw NoInvite() })
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        rig.sim.chooseSource(.meeting)
        rig.sim.prepare()
        try await waitForEnd(rig.sim)
        XCTAssertEqual(rig.sim.phase, .setup)
        XCTAssertNil(rig.sim.prepStep)
        XCTAssertTrue(rig.sim.prepError?.contains("Harbor & Pine Analytics intro") == true, rig.sim.prepError ?? "nil")
        XCTAssertEqual(rig.sim.choice, .upcoming("e1"), "the choice stays so he can try again")
        XCTAssertEqual(simFolders(root), [])
        XCTAssertTrue(rig.eventMap.load().isEmpty)
    }

    func testCancelDuringTheInviteStepStopsTheFlow() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: [entry("e1", "Harbor & Pine Analytics intro", start: at(22, 10))]), fakeBrain: true,
                          prepare: { _, _ in
                              try await Task.sleep(for: .milliseconds(400))
                              return URL(fileURLWithPath: "/tmp/never/20261020-100000-abcd1234")
                          })
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        rig.sim.chooseSource(.meeting)
        rig.sim.prepare()
        XCTAssertEqual(rig.sim.prepStep, .invite)
        rig.sim.cancelPrep()
        XCTAssertEqual(rig.sim.phase, .setup)
        XCTAssertNil(rig.sim.prepStep)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(rig.sim.phase, .setup, "the invite prep finishing later does not start the interview")
        XCTAssertNil(rig.sim.prepStep)
        XCTAssertEqual(simFolders(root), [])
    }

    /// A prepared meeting is still one step: no step list, same result as F4c.
    func testAPreparedMeetingStaysOneStep() async throws {
        try requireBrain()
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixtureSession, to: root.appendingPathComponent("harbor-pine-intro", isDirectory: true))
        let rig = makeRig(root: root, calendar: FakeCalendar(entries: []), fakeBrain: true)
        rig.sim.refreshMeetings()
        await rig.sim.refreshUpcoming()
        XCTAssertEqual(rig.sim.choice, .prepared("harbor-pine-intro"))
        var steps: [SimController.PrepStep?] = []
        let sub = rig.sim.$prepStep.sink { steps.append($0) }
        defer { sub.cancel() }
        rig.sim.prepare()
        XCTAssertNil(rig.sim.prepStep)
        try await waitForEnd(rig.sim)
        XCTAssertEqual(rig.sim.phase, .prepared, "\(rig.sim.prepError ?? "")")
        XCTAssertEqual(steps.compactMap { $0 }, [], "no step was ever shown")
        XCTAssertEqual(rig.sim.summary?.sourceSession, "harbor-pine-intro")
        XCTAssertTrue(rig.prepared.names.isEmpty, "no event prep ran")
    }
}
