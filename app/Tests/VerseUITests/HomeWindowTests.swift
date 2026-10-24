import AppKit
import Foundation
import SwiftUI
@testable import VerseUI
import VerseMeet
import XCTest

private func homeScratch() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-home-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class HomeSessionParsingTests: XCTestCase {
    func testFolderTitles() {
        XCTAssertEqual(HomeSession.title(forFolder: "mara-northwindlabs"), "Mara Northwindlabs")
        XCTAssertEqual(HomeSession.title(forFolder: "conv-20261015-1857-northwind-labs"), "Northwind Labs")
        XCTAssertEqual(HomeSession.title(forFolder: "sim-20261015-0930-brightwave"), "Practice · Brightwave")
        XCTAssertEqual(HomeSession.title(forFolder: "Brightwave case review"), "Brightwave case review", "a folder named like a title is kept")
    }

    func testSummarySectionsSkipHeaderNotesAndDuplicates() {
        let text = """
        # Meeting summary

        _generated 2026-10-14 23:40 · session x_

        > DRAFT: final merge pending

        ## Summary

        Mara wants one SaaS.

        ## Actions

        - Send the scope
        - Send the scope
        - Ask Marta

        ## Conflicts with the fact sheet

        - (none)
        """
        let s = HomeSessionDetail.parseSummary(text)
        XCTAssertEqual(s.map(\.title), ["Summary", "Actions"], "the empty conflicts section is dropped")
        XCTAssertEqual(s[0].items, ["Mara wants one SaaS."])
        XCTAssertTrue(s[0].isParagraph)
        XCTAssertEqual(s[1].items, ["Send the scope", "Ask Marta"])
        XCTAssertFalse(s[1].isParagraph)
    }

    func testQuestionsKeepTheLastTextOfATurnOnce() throws {
        let dir = try homeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("transcript.jsonl")
        try """
        {"kind":"fragment","text":"How","turn_id":"r1"}
        {"kind":"question","text":"How would you","turn_id":"r2"}
        {"kind":"question","text":"How would you scope a v1?","turn_id":"r2"}
        {"kind":"statement","text":"Okay.","turn_id":"r3"}
        {"kind":"question","text":"How would you scope a v1?","turn_id":"r4"}
        """.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(HomeSessionDetail.questions(transcript: f), ["How would you scope a v1?"])
    }
}

@MainActor
final class HomeSessionsModelTests: XCTestCase {
    func testListsSessionFoldersNewestFirstWithKindsAndSpend() throws {
        let root = try homeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func make(_ name: String, files: [String], at date: Date) throws {
            let d = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data().write(to: d.appendingPathComponent("pack.md"))
            for f in files {
                let u = d.appendingPathComponent(f)
                try Data("x".utf8).write(to: u)
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
            }
        }
        try make("old-meeting", files: ["summary.md"], at: Date(timeIntervalSinceNow: -86_400 * 3))
        try make("new-meeting", files: ["summary.md", "transcript.jsonl"], at: Date(timeIntervalSinceNow: -60))
        try make("sim-20261015-0930-acme", files: ["report.html"], at: Date(timeIntervalSinceNow: -3_600))
        try make("only-prepared", files: ["meta.json"], at: Date(timeIntervalSinceNow: -86_400 * 9))
        SpendLedger.record(sessionDir: root.appendingPathComponent("new-meeting"), startedAt: Date(), costUSD: 0.25)
        // A folder without pack.md is not a session.
        try fm.createDirectory(at: root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true)

        let model = HomeSessionsModel(root: root)
        XCTAssertEqual(model.sessions.map(\.name), ["new-meeting", "sim-20261015-0930-acme", "old-meeting", "only-prepared"])
        XCTAssertEqual(model.sessions.map(\.kind), [.meeting, .practice, .meeting, .prepared])
        XCTAssertNotNil(model.sessions[0].transcriptURL)
        XCTAssertNotNil(model.sessions[1].reportURL)
        XCTAssertEqual(model.sessions[0].spend, 0.25, accuracy: 0.0001)
        XCTAssertEqual(model.session(named: "old-meeting")?.title, "Old Meeting")
        XCTAssertNil(model.session(named: "missing"))
    }

    func testChecklistRemembersTickedItemsPerSession() {
        let suite = "dev.example.verse.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeChecklistStore(defaults: defaults)
        store.set("Send the scope", done: true, session: "a")
        store.set("Ask Marta", done: true, session: "a")
        store.set("Ask Marta", done: false, session: "a")
        XCTAssertEqual(store.done(session: "a"), ["Send the scope"])
        XCTAssertEqual(store.done(session: "b"), [])
    }
}

final class HomeReportStyleTests: XCTestCase {
    func testStylesheetMapsTheReportColoursToTheWindowInkInBothAppearances() {
        let light = HomeReportView.stylesheet(ink: VT.Window(dark: false))
        let dark = HomeReportView.stylesheet(ink: VT.Window(dark: true))
        for css in [light, dark] {
            XCTAssertTrue(css.contains("--bg:transparent"), "no opaque page background")
            XCTAssertTrue(css.contains(".answer{color:var(--ink)}"), "the hard-coded answer colour is replaced")
        }
        XCTAssertTrue(light.contains("--ink:rgba(0,0,0,0.860)"), light)
        XCTAssertTrue(dark.contains("--ink:rgba(255,255,255,0.920)"), dark)
        XCTAssertTrue(light.contains("color-scheme:light") && dark.contains("color-scheme:dark"))
    }

    func testOverridesComeLastInTheHead() throws {
        let dir = try homeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("report.html")
        try "<html><head><style>:root{--bg:#050405}</style></head><body><main>x</main></body></html>".write(to: f, atomically: true, encoding: .utf8)
        let page = try XCTUnwrap(HomeReportView.html(of: f, ink: VT.Window(dark: false)))
        let original = try XCTUnwrap(page.range(of: "#050405")), override = try XCTUnwrap(page.range(of: "--bg:transparent"))
        XCTAssertLessThan(original.lowerBound, override.lowerBound)
        XCTAssertLessThan(override.lowerBound, try XCTUnwrap(page.range(of: "</head>")).lowerBound)
        XCTAssertTrue(page.contains("<main>x</main>"), "the content is untouched")
    }
}

@MainActor
final class HomeRouterTests: XCTestCase {
    func testReportOpensSessionsOnItsFolder() {
        _ = NSApplication.shared
        let router = HomeRouter()
        router.showReport(URL(fileURLWithPath: "/tmp/x/sim-20261015-0930-acme/report.html"))
        XCTAssertEqual(router.page, .sessions)
        XCTAssertEqual(router.selectedSession, "sim-20261015-0930-acme")
    }

    func testPagesCoverTheFiveOldWindows() {
        XCTAssertEqual(HomePage.allCases.map(\.title), ["Prepare", "Me", "Sessions", "Practice", "Scripts", "Settings"])
        XCTAssertEqual(HomePage.me.symbol, "person.text.rectangle")
        XCTAssertEqual(HomePage.allCases.firstIndex(of: .me), (HomePage.allCases.firstIndex(of: .prepare) ?? 0) + 1,
                       "Me sits between Prepare and Sessions")
        XCTAssertEqual(ConversationWindow.id, HomeRouter.windowID, "the old conversation window id opens home")
    }
}

@MainActor
final class HomeUpNextTests: XCTestCase {
    private func makeModel(prepare: @escaping @Sendable (MeetingEvent, String) async throws -> URL,
                           onPrepared: @escaping @MainActor (String) -> Void = { _ in }) -> HomeUpNextModel {
        let defaults = UserDefaults(suiteName: "dev.example.verse.test-\(UUID().uuidString)")!
        return HomeUpNextModel(settings: AppSettings(defaults: defaults), meeting: MeetingSettings(defaults: defaults), sessions: { [] },
                               eventMap: EventSessionMap(url: FileManager.default.temporaryDirectory.appendingPathComponent("evmap-\(UUID().uuidString).json")),
                               prepare: prepare, onPrepared: onPrepared)
    }

    func testPrepareFromInviteReportsTheNewSession() async throws {
        var prepared: String?
        let model = makeModel(prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/mara-call") }, onPrepared: { prepared = $0 })
        let event = MeetingEvent(id: "e1", title: "Mara call", start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(3_600))
        model.setItems([HomeUpNextItem(id: "e1", title: "Mara call", meta: "Today", session: nil, event: event)])
        model.prepare(model.items[0])
        XCTAssertTrue(model.preparing.contains("e1"))
        for _ in 0..<100 where prepared == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(prepared, "mara-call")
        XCTAssertFalse(model.preparing.contains("e1"))
    }

    // MARK: event prep is the real run

    private func fixtureBrainDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("verse_brain"), withIntermediateDirectories: true)
        return d
    }

    private final class ArgvRecorder: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        var calls: [[String]] { lock.withLock { all } }
        func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
            lock.withLock { all.append(arguments) }
            return CommandResult(status: 0, stdout: "session: /tmp/sessions/from-invite\n", stderr: "")
        }
    }

    func testTheAppsEventPrepBuildsALivePrepNotTheFake() throws {
        let prep = EventPrep.live(URL(fileURLWithPath: "/tmp/brain"))
        XCTAssertFalse(prep.fake, "the real path must not default to the offline fake")
        XCTAssertEqual(prep.budgetUSD, 0.45)
    }

    func testPrepareClosureUsesTheInjectedPrepAndStaysOffline() async throws {
        let brain = try fixtureBrainDir()
        defer { try? FileManager.default.removeItem(at: brain) }
        let recorder = ArgvRecorder()
        let prepare = EventPrep.prepare(brainDir: brain, make: { dir in
            CalendarPrep(brainDir: dir, python: URL(fileURLWithPath: "/usr/bin/true"), fake: true, runner: recorder)
        })
        let event = MeetingEvent(id: "e9", title: "Invite", start: Date(), end: Date().addingTimeInterval(1_800))
        let dir = try await prepare(event, "en")
        XCTAssertEqual(dir.lastPathComponent, "from-invite")
        XCTAssertTrue(try XCTUnwrap(recorder.calls.first).contains("--fake"))
        // Without a brain folder the closure fails the same way the app always did.
        do {
            _ = try await EventPrep.prepare(brainDir: nil)(event, "en")
            XCTFail("expected brainDirNotFound")
        } catch {
            XCTAssertEqual(error as? CalendarPrepError, .brainDirNotFound("(not found)"))
        }
    }

    func testAMissingKeyReachesTheUpNextMessageAsAClearSentence() async throws {
        let model = makeModel(prepare: { _, _ in throw CalendarPrepError.apiKeyMissing })
        let event = MeetingEvent(id: "e3", title: "Review", start: Date(), end: Date().addingTimeInterval(1_800))
        model.setItems([HomeUpNextItem(id: "e3", title: "Review", meta: "Today", session: nil, event: event)])
        model.prepare(model.items[0])
        for _ in 0..<100 where model.message == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.message, "Could not prepare \"Review\": No Anthropic API key in the Keychain. Add it in Settings (Anthropic API key), then prepare again.")
    }

    // MARK: only real meetings

    private final class OneCalendar: CalendarBackend, @unchecked Sendable {
        let all: [CalendarEntry]
        init(_ all: [CalendarEntry]) { self.all = all }
        func authorization() -> CalendarAuthorization { .fullAccess }
        func requestFullAccess() async throws -> Bool { false }
        func accountCount() -> Int { 1 }
        func entries(from: Date, to: Date) -> [CalendarEntry] { all.filter { $0.end > from && $0.start < to } }
    }

    private func calendarModel(_ entries: [CalendarEntry]) -> HomeUpNextModel {
        let defaults = UserDefaults(suiteName: "dev.example.verse.test-\(UUID().uuidString)")!
        let meeting = MeetingSettings(defaults: defaults)
        meeting.useCalendar = true
        return HomeUpNextModel(settings: AppSettings(defaults: defaults), meeting: meeting, sessions: { [] },
                               calendar: CalendarSource(backend: OneCalendar(entries)),
                               eventMap: EventSessionMap(url: FileManager.default.temporaryDirectory.appendingPathComponent("evmap-\(UUID().uuidString).json")),
                               prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/x") })
    }

    func testUpNextAndUpcomingListOnlyRealMeetings() async throws {
        let me = Attendee(name: "Test Owner", email: "owner@example.invalid")
        let guest = Attendee(name: "Ingrid S", email: "ingrid@example.invalid")
        func e(_ id: String, minutes: Double, attendees: [Attendee] = [], url: String? = nil, allDay: Bool = false, mine: Bool = false) -> CalendarEntry {
            let start = Date().addingTimeInterval(minutes * 60)
            return CalendarEntry(id: id, title: "T-\(id)", start: start, end: start.addingTimeInterval(1_800), isAllDay: allDay, attendees: attendees,
                                 url: url.flatMap(URL.init(string:)), currentUser: mine ? me : nil)
        }
        let model = calendarModel([
            e("people", minutes: 10, attendees: [me, guest], mine: true),
            e("link", minutes: 20, url: "https://acme.webex.com/meet/someone"),
            e("solo", minutes: 30),
            e("self", minutes: 40, attendees: [me], mine: true),
            e("allday", minutes: 50, attendees: [guest], allDay: true),
        ])
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["people", "link"])
        let upcoming = await model.upcomingEvents(within: 14 * 86_400)
        XCTAssertEqual(upcoming.map(\.id), ["people", "link"])
    }

    func testPrepareFailureShowsAMessage() async throws {
        struct Boom: Error {}
        let model = makeModel(prepare: { _, _ in throw Boom() })
        let event = MeetingEvent(id: "e2", title: "Review", start: Date(), end: Date().addingTimeInterval(1_800))
        model.setItems([HomeUpNextItem(id: "e2", title: "Review", meta: "Today", session: nil, event: event)])
        model.prepare(model.items[0])
        for _ in 0..<100 where model.message == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.message?.contains("Review") == true)
        XCTAssertTrue(model.preparing.isEmpty)
    }

    func testMetaNamesTheDayAndTheCountdown() {
        let now = Date()
        let soon = MeetingEvent(id: "a", title: "A", start: now.addingTimeInterval(4 * 60 + 5), end: now.addingTimeInterval(3_600), provider: .zoom)
        XCTAssertTrue(HomeUpNextModel.meta(soon, now: now).hasPrefix("Today "))
        XCTAssertTrue(HomeUpNextModel.meta(soon, now: now).hasSuffix("Zoom · in 4 minutes"))
    }
}

/// Lays out every page offscreen. A Keychain query inside a view body once re-entered layout and aborted; this keeps
/// the pages free of that. Nothing is shown.
@MainActor
final class HomePagesLayoutTests: XCTestCase {
    func testEveryPageLaysOutInBothAppearances() throws {
        _ = NSApplication.shared
        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        for dark in [false, true] {
            for page in HomePage.allCases {
                let router = HomeRouter()
                router.page = page
                router.selectedSession = fixtures.selectedSession
                let root = HomeRoot(context: fixtures.context(router: router), a11yOverride: HomeA11yOverride(), inWindowGlass: true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root.frame(width: 1100, height: 680))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled], backing: .buffered, defer: true)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 1100, accuracy: 1, "\(page) \(dark ? "dark" : "light")")
                window.contentView = nil
            }
        }
    }
}
