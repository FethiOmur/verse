import Foundation
import VerseMeet
@testable import VerseUI
import XCTest

/// The visible side of calendar-aware selection: the one picker model of the menu and Home (G5), the calendar row (G2), the
/// background prep gate (owner decision 3), the run label (G12), the real-meeting preference (G13) and the event sidecar (G14).
/// Invented names only; time and the time zone are injected.
@MainActor
final class SessionPickerTests: XCTestCase {
    /// 2026-11-24 10:00:00 UTC, a Tuesday.
    private let ten = Date(timeIntervalSince1970: 1_795_514_400)
    private func at(_ minutes: Double) -> Date { ten.addingTimeInterval(minutes * 60) }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let guest = Attendee(name: "Dana Quill", email: "Dana@Example.com")

    private func meeting(_ id: String, _ title: String, start: Double, minutes: Double = 30) -> MeetingEvent {
        MeetingEvent(id: id, title: title, start: at(start), end: at(start + minutes), attendees: [guest])
    }

    private func build(sessions: [String], upcoming: [MeetingEvent] = [], matches: [String: String] = [:], target: MeetingEvent? = nil,
                       selected: String = "", manual: ManualChoice? = nil, sidecars: [String: EventSidecar] = [:],
                       createdAt: [String: Date] = [:], preparing: Set<String> = []) -> SessionPickerModel {
        SessionPickerModel.build(now: ten, sessions: sessions, upcoming: upcoming,
                                 matches: matches.mapValues { SessionMatch(session: $0, source: .occurrenceLink) },
                                 target: target, selected: selected, manual: manual, sidecars: sidecars, createdAt: createdAt,
                                 preparing: preparing, calendar: utc)
    }

    // MARK: picker model (G5)

    func testNextMeetingsComeFirstInEventOrderThenOtherSessionsNewestFirst() {
        let late = meeting("b", "Pricing call with Harbor Mills", start: 26 * 60)       // tomorrow 12:00
        let soon = meeting("a", "Design review", start: 240)                             // today 14:00
        let far = meeting("c", "Board prep", start: 2 * 24 * 60 + 60)                    // Thursday 11:00, outside nothing: the model lists what it is given
        let m = build(sessions: ["zeta-notes", "design-review", "harbor-pricing", "alpha-notes", "board-prep", "beta-notes"],
                      upcoming: [late, far, soon],
                      matches: [soon.occurrenceKey: "design-review", late.occurrenceKey: "harbor-pricing", far.occurrenceKey: "board-prep"],
                      createdAt: ["alpha-notes": at(-60), "beta-notes": at(-60), "zeta-notes": at(-10)])
        XCTAssertEqual(m.nextMeetings.map(\.session), ["design-review", "harbor-pricing", "board-prep"], "event order")
        XCTAssertEqual(m.nextMeetings.map(\.label), ["Today 14:00 · Design review", "Tomorrow 12:00 · Pricing call with Harbor Mills",
                                                     "Thu 26 Nov 11:00 · Board prep"])
        XCTAssertEqual(m.others.map(\.session), ["zeta-notes", "alpha-notes", "beta-notes"],
                       "newest first; equal times A-Z; matched sessions are not listed twice")
        XCTAssertEqual(m.others.map(\.label), ["zeta-notes", "alpha-notes", "beta-notes"], "no event.json: the folder name")
    }

    func testASessionMatchedByTwoMeetingsIsListedOnceUnderTheFirst() {
        let a = meeting("a", "Standup", start: 30), b = meeting("b", "Standup", start: 24 * 60 + 30)
        let m = build(sessions: ["standup"], upcoming: [b, a], matches: [a.occurrenceKey: "standup", b.occurrenceKey: "standup"])
        XCTAssertEqual(m.nextMeetings.map(\.label), ["Today 10:30 · Standup"])
        XCTAssertTrue(m.others.isEmpty)
    }

    func testASessionPreparedFromAnEventIsLabelledByItsTitleAndDate() {
        let sidecars = [
            "20261120-091500-ab12cd34": EventSidecar(occurrenceKey: "x@1", eventID: "x", title: "Intro with Coral Labs", start: at(-4 * 24 * 60)),
            "20261121-091500-ef56ab78": EventSidecar(occurrenceKey: "y@1", eventID: "y", title: "   ", start: at(-60)),
            "20261122-091500-0a0b0c0d": EventSidecar(occurrenceKey: "z@1", eventID: "z", title: "Catch-up", start: nil),
        ]
        let table: [(String, String)] = [
            ("20261120-091500-ab12cd34", "Intro with Coral Labs · Fri 20 Nov"),
            ("20261121-091500-ef56ab78", "20261121-091500-ef56ab78"),   // a blank title: the folder name
            ("20261122-091500-0a0b0c0d", "Catch-up"),                   // no date: the title alone
            ("plain-folder", "plain-folder"),
        ]
        let m = build(sessions: table.map(\.0), sidecars: sidecars)
        for (name, label) in table { XCTAssertEqual(m.label(of: name), label, name) }
    }

    func testTheSelectedRowSaysWhyItIsSelected() {
        let next = meeting("a", "Design review", start: 60)
        let base = (sessions: ["design-review", "other-notes"], upcoming: [next], matches: [next.occurrenceKey: "design-review"])
        let table: [(selected: String, manual: ManualChoice?, expect: [String: SessionPickerModel.Mark?])] = [
            ("design-review", nil, ["design-review": .nextMeeting, "other-notes": nil]),
            ("other-notes", ManualChoice(session: "other-notes", targetKey: next.occurrenceKey, at: ten), ["design-review": nil, "other-notes": .chosen]),
            // He picked the meeting's own session by hand: it is still the next meeting's.
            ("design-review", ManualChoice(session: "design-review", targetKey: next.occurrenceKey, at: ten), ["design-review": .nextMeeting]),
            // Kept from before (no match change, no manual pick): no reason to show.
            ("other-notes", nil, ["other-notes": nil, "design-review": nil]),
        ]
        for row in table {
            let m = build(sessions: base.sessions, upcoming: base.upcoming, matches: base.matches, target: next, selected: row.selected, manual: row.manual)
            for (s, mark) in row.expect {
                XCTAssertEqual(m.rows.first { $0.session == s }?.mark, mark, "\(row.selected) / \(s)")
            }
        }
        let m = build(sessions: base.sessions, upcoming: base.upcoming, matches: base.matches, target: next, selected: "design-review")
        XCTAssertEqual(m.nextMeetings.first?.display, "Today 11:00 · Design review (next meeting)")
        let chosen = build(sessions: base.sessions, upcoming: base.upcoming, matches: base.matches, target: next, selected: "other-notes",
                           manual: ManualChoice(session: "other-notes", targetKey: nil, at: ten))
        XCTAssertEqual(chosen.others.first?.display, "other-notes (chosen)")
    }

    func testTheNextMeetingWithoutASessionGetsItsOwnLine() {
        let next = meeting("a", "Pricing call", start: 90)
        XCTAssertEqual(build(sessions: ["old-notes"], upcoming: [next], target: next, selected: "old-notes").notPrepared?.label,
                       "Next: Pricing call Today 11:30 — not prepared")
        let busy = build(sessions: ["old-notes"], upcoming: [next], target: next, preparing: [next.occurrenceKey]).notPrepared
        XCTAssertEqual(busy?.label, "Next: Pricing call Today 11:30 — preparing…")
        XCTAssertEqual(busy?.preparing, true)
        XCTAssertNil(build(sessions: ["pricing"], upcoming: [next], matches: [next.occurrenceKey: "pricing"], target: next).notPrepared,
                     "prepared: no line")
        XCTAssertNil(build(sessions: ["old-notes"], upcoming: [], target: nil).notPrepared, "no meeting ahead: no line")
        // A match to a folder that is gone is no session.
        XCTAssertNotNil(build(sessions: ["old-notes"], upcoming: [next], matches: [next.occurrenceKey: "gone"], target: next).notPrepared)
    }

    func testDayTimeIsRelativeToNowInTheCalendarsTimeZone() {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        let table: [(Date, Calendar, String)] = [
            (at(0), utc, "Today 10:00"),
            (at(13 * 60 + 59), utc, "Today 23:59"),
            (at(14 * 60), utc, "Tomorrow 00:00"),
            (at(38 * 60), utc, "Thu 26 Nov 00:00"),
            (at(13 * 60 + 30), rome, "Tomorrow 00:30"),   // 23:30 UTC is already the next day in Rome
        ]
        for (d, cal, want) in table { XCTAssertEqual(SessionPickerModel.dayTime(d, now: ten, calendar: cal), want) }
    }

    // MARK: calendar row (G2, owner decision 4)

    func testTheCalendarRow() {
        typealias Row = (sessions: Bool, on: Bool, auth: CalendarAuthorization, running: Bool, done: Bool, want: CalendarNudge?)
        let table: [Row] = [
            (true, false, .notDetermined, false, false, .turnOn),
            (false, false, .notDetermined, false, false, nil),          // nothing to pick yet
            (true, false, .notDetermined, true, false, nil),            // never during a run
            (true, false, .denied, false, true, nil),                   // one time only
            (true, true, .fullAccess, false, false, nil),
            (true, true, .denied, false, false, .permissionMissing),
            (true, true, .writeOnly, true, true, .permissionMissing),   // said even during a run: no sheet is raised
            (false, true, .notDetermined, false, false, .permissionMissing),
        ]
        for r in table {
            XCTAssertEqual(CalendarNudge.state(hasSessions: r.sessions, useCalendar: r.on, authorization: r.auth, running: r.running, done: r.done),
                           r.want, "\(r)")
        }
    }

    // MARK: background prep (owner decision 3)

    func testTheAutoPrepGate() {
        let a = meeting("a", "Design review", start: 60), b = meeting("b", "Pricing call", start: 120)
        let running = meeting("r", "Ongoing", start: -10)
        let solo = MeetingEvent(id: "s", title: "Focus", start: at(30), end: at(90))
        let far = meeting("f", "Far away", start: 37 * 60)
        typealias Row = (enabled: Bool, busy: Bool, upcoming: [MeetingEvent], matched: Set<String>, attempted: Set<String>,
                         inFlight: Set<String>, want: String?, why: String)
        let table: [Row] = [
            (true, false, [b, a], [], [], [], "a", "the soonest unmatched meeting"),
            (false, false, [a], [], [], [], nil, "the setting is off"),
            (true, true, [a], [], [], [], nil, "a run, a stop, practice or a prompt is under way"),
            (true, false, [a, b], [a.occurrenceKey], [], [], "b", "a meeting with a session is skipped"),
            (true, false, [a, b], [], [a.occurrenceKey], [], "b", "once per occurrence"),
            (true, false, [a, b], [], [], [a.occurrenceKey], nil, "one prep at a time"),
            (true, false, [running, solo, far], [], [], [], nil, "started, not a real meeting, beyond the lookahead"),
        ]
        for r in table {
            let got = AutoPrepGate.candidate(now: ten, enabled: r.enabled, busy: r.busy, upcoming: r.upcoming, matched: r.matched,
                                             attempted: r.attempted, inFlight: r.inFlight)
            XCTAssertEqual(got?.id, r.want, r.why)
        }
        // Next week's occurrence of a tried series is its own meeting.
        let nextWeek = meeting("a", "Design review", start: 60 + 7 * 24 * 60)
        XCTAssertEqual(AutoPrepGate.candidate(now: at(7 * 24 * 60), enabled: true, busy: false, upcoming: [nextWeek], matched: [],
                                              attempted: [a.occurrenceKey], inFlight: [])?.occurrenceKey, nextWeek.occurrenceKey)
        XCTAssertEqual(AutoPrepGate.pruned([a.occurrenceKey: at(-4 * 24 * 60), b.occurrenceKey: at(-60)], now: ten).keys.sorted(),
                       [b.occurrenceKey], "old attempts are forgotten")
    }

    func testAutoPrepRunsOncePerOccurrenceAcrossRelaunchesAndNotWhileBusyOrOff() async throws {
        let settings = meetingSettings(calendar: true)
        let calls = PrepCounter()
        let root = try tempDir()
        let done = expectation(description: "prepared")
        var recorded: [(String, String)] = []
        func make(_ s: MeetingSettings) -> MeetingAutoPrep {
            MeetingAutoPrep(settings: s, prepare: { event, _ in
                calls.add()
                let dir = root.appendingPathComponent("prep-\(event.id)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }, language: { "en" }, onPrepared: { event, dir in
                recorded.append((event.occurrenceKey, dir.lastPathComponent))
                done.fulfill()
            }, log: { _ in })
        }
        let a = meeting("a", "Design review", start: 60)
        let prep = make(settings)
        XCTAssertNil(prep.consider(now: ten, busy: true, upcoming: [a], matched: []), "not while a run is active")
        XCTAssertEqual(prep.consider(now: ten, busy: false, upcoming: [a], matched: [])?.id, "a")
        XCTAssertTrue(prep.inFlight.contains(a.occurrenceKey), "the pickers show Preparing…")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(prep.inFlight.isEmpty)
        XCTAssertEqual(recorded.map(\.1), ["prep-a"])
        XCTAssertNil(prep.consider(now: at(1), busy: false, upcoming: [a], matched: []), "tried once")
        // A relaunch reads the same settings: still tried.
        XCTAssertNil(make(settings).consider(now: at(2), busy: false, upcoming: [a], matched: []))
        XCTAssertEqual(calls.value, 1)
        // The toggle off: nothing, even for a new meeting.
        settings.autoPrepare = false
        XCTAssertNil(make(settings).consider(now: at(2), busy: false, upcoming: [meeting("n", "New one", start: 90)], matched: []))
        // The calendar off: nothing either.
        settings.autoPrepare = true
        settings.useCalendar = false
        XCTAssertNil(make(settings).consider(now: at(2), busy: false, upcoming: [meeting("n", "New one", start: 90)], matched: []))
    }

    func testAPrepStartedElsewhereIsNotRepeatedInTheBackground() {
        let settings = meetingSettings(calendar: true)
        let prep = MeetingAutoPrep(settings: settings, prepare: neverPrepare, language: { "en" }, onPrepared: { _, _ in }, log: { _ in })
        let a = meeting("a", "Design review", start: 60)
        prep.noteAttempt(a, now: ten)
        XCTAssertNil(prep.consider(now: ten, busy: false, upcoming: [a], matched: []))
    }

    // MARK: the controller's prep, label and calendar row

    func testAFinishedPrepIsLinkedGetsItsSidecarAndIsSelectedForTheNextMeeting() throws {
        let root = try tempDir()
        for name in ["old-notes", "20261124-090000-ab12cd34"] {
            let d = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("pack".utf8).write(to: d.appendingPathComponent("pack.md"))
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        settings.sessionName = "old-notes"
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: ["verse"]))
        c.sessionsRoot = root
        c.eventSessions = EventSessionMap(url: root.appendingPathComponent("map.json"))
        // The events come in directly (never the real calendar, never the app's own settings), and the prep hooks are quiet.
        c.onEventPrepared = { _, _ in }
        c.clock = { self.ten }
        c.calendar = utc
        let next = meeting("a", "Pricing call", start: 60)
        c.selectionEvents = { _ in [next] }
        c.refreshSessions()
        c.selector.reevaluate()
        XCTAssertEqual(c.pickerModel().notPrepared?.event.id, "a")

        let dir = root.appendingPathComponent("20261124-090000-ab12cd34")
        c.eventPrepared(next, dir: dir)
        XCTAssertEqual(c.eventSessions.load()[next.occurrenceKey], "20261124-090000-ab12cd34")
        let sidecar = try XCTUnwrap(EventSidecar.read(sessionDir: dir))
        XCTAssertEqual(sidecar.occurrenceKey, next.occurrenceKey)
        XCTAssertEqual(sidecar.title, "Pricing call")
        XCTAssertEqual(sidecar.attendeeEmails, ["dana@example.com"])
        XCTAssertEqual(settings.sessionName, "20261124-090000-ab12cd34", "for the next meeting: selected")
        XCTAssertEqual(c.statusLine, "Ready · Today 11:00 · Pricing call")
        XCTAssertNil(c.pickerModel().notPrepared)
    }

    /// Design 4: a pick by hand holds until the target changes. The background prep neither starts for the meeting he chose a
    /// session for, nor replaces his pick when a prep for that meeting finishes anyway; a prep he asked for still does.
    func testTheBackgroundPrepLeavesALiveManualPickAlone() throws {
        let root = try tempDir()
        for name in ["old-notes", "20261124-090000-ab12cd34", "20261124-091500-cd34ef56"] {
            let d = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("pack".utf8).write(to: d.appendingPathComponent("pack.md"))
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        settings.sessionName = "20261124-091500-cd34ef56"
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: ["verse"]))
        // Never the app's own meeting settings: the calendar and the background prep are on in a throwaway suite.
        c.meeting = MeetingCoordinator(host: c, settings: meetingSettings(calendar: true))
        let calls = PrepCounter()
        c.eventPrepare = { _, _ in calls.add(); throw CancellationError() }
        c.sessionsRoot = root
        c.eventSessions = EventSessionMap(url: root.appendingPathComponent("map.json"))
        c.onEventPrepared = { _, _ in }
        c.clock = { self.ten }
        c.calendar = utc
        let next = meeting("a", "Pricing call", start: 60)
        c.selectionEvents = { _ in [next] }
        c.refreshSessions()
        c.selector.reevaluate()
        c.selector.choose("old-notes")

        c.considerAutoPrep()
        XCTAssertTrue(c.autoPrep.inFlight.isEmpty, "no paid prep for a meeting he chose a session for")
        XCTAssertEqual(calls.value, 0)

        // A prep for that meeting finishes anyway (it was under way before the pick): recorded, not selected.
        c.eventPrepared(next, dir: root.appendingPathComponent("20261124-090000-ab12cd34"))
        XCTAssertEqual(c.eventSessions.load()[next.occurrenceKey], "20261124-090000-ab12cd34")
        XCTAssertEqual(settings.sessionName, "old-notes", "his pick holds")
        XCTAssertEqual(settings.sessionPickManual?.session, "old-notes")
        c.selector.reevaluate()
        XCTAssertEqual(settings.sessionName, "old-notes", "and still holds on the next look")

        // A prep he asked for is his latest choice.
        XCTAssertTrue(c.selector.didPrepare("20261124-091500-cd34ef56", event: next, byHand: true))
        XCTAssertEqual(settings.sessionName, "20261124-091500-cd34ef56")
        XCTAssertNil(settings.sessionPickManual)
    }

    func testUseForThisMeetingLinksTheOccurrenceAndSelects() throws {
        let root = try tempDir()
        for name in ["old-notes", "draft-notes"] {
            let d = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("pack".utf8).write(to: d.appendingPathComponent("pack.md"))
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        settings.sessionName = "old-notes"
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: ["verse"]))
        c.sessionsRoot = root
        c.eventSessions = EventSessionMap(url: root.appendingPathComponent("map.json"))
        // The events come in directly (never the real calendar, never the app's own settings), and the prep hooks are quiet.
        c.onEventPrepared = { _, _ in }
        c.clock = { self.ten }
        c.calendar = utc
        let next = meeting("a", "Pricing call", start: 60)
        c.selectionEvents = { _ in [next] }
        c.refreshSessions()
        c.selector.reevaluate()
        c.useForNextMeeting("draft-notes")
        XCTAssertEqual(c.eventSessions.load()[next.occurrenceKey], "draft-notes")
        XCTAssertEqual(settings.sessionName, "draft-notes")
        let m = c.pickerModel()
        XCTAssertEqual(m.nextMeetings.map(\.display), ["Today 11:00 · Pricing call (next meeting)"])
        XCTAssertNil(m.notPrepared)
    }

    func testWhileRunningTheStatusLineNamesTheRunFolder() throws {
        let root = try tempDir()
        let d = root.appendingPathComponent("design-review")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("pack".utf8).write(to: d.appendingPathComponent("pack.md"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: ["verse"]))
        c.sessionsRoot = root
        settings.sessionName = "design-review"
        c.refreshSessions()
        c.setRunningForPreview(true, session: URL(fileURLWithPath: "/tmp/sessions/adhoc-20261124-1000-meeting"))
        XCTAssertEqual(c.runLabel, "Unprepared call")
        XCTAssertTrue(c.statusLine.hasPrefix("Listening · Unprepared call"), c.statusLine)
        c.setRunningForPreview(true, session: URL(fileURLWithPath: "/tmp/sessions/harbor-pricing"))
        XCTAssertTrue(c.statusLine.hasPrefix("Listening · harbor-pricing"), "the run's own folder, not the picker's: \(c.statusLine)")
        c.setRunningForPreview(false)
        XCTAssertEqual(c.runLabel, "design-review")
    }

    // MARK: real meetings first (G13)

    func testRealMeetingsArePreferredAndAWebexLocationCounts() {
        let focus = MeetingEvent(id: "f", title: "Focus", start: at(0), end: at(60))
        let call = meeting("c", "Pricing call", start: 0)
        XCTAssertEqual(RealMeeting.preferReal([focus, call]).map(\.id), ["c"])
        XCTAssertEqual(RealMeeting.preferReal([focus]).map(\.id), ["f"], "none is real: all of them")
        XCTAssertEqual(RealMeeting.callLink(in: "Room 2, https://acme.webex.com/meet/dana")?.host, "acme.webex.com")
        XCTAssertNil(RealMeeting.callLink(in: "Room 2"))

        struct Backend: CalendarBackend {
            let entry: CalendarEntry
            func authorization() -> CalendarAuthorization { .fullAccess }
            func requestFullAccess() async throws -> Bool { true }
            func accountCount() -> Int { 1 }
            func entries(from: Date, to: Date) -> [CalendarEntry] { [entry] }
        }
        let webex = CalendarEntry(id: "w", title: "Vendor sync", start: at(30), end: at(60), location: "https://acme.webex.com/meet/dana")
        let read = CalendarSource(backend: Backend(entry: webex)).events(overlapping: ten, at(120))
        XCTAssertEqual(read.count, 1)
        XCTAssertTrue(RealMeeting.isReal(read[0]), "the location's Webex link survives as the url")
        XCTAssertEqual(SessionAutoSelect.target(now: ten, events: read)?.id, "w")
    }
}

/// A count the prep closure (Sendable) can bump.
final class PrepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
