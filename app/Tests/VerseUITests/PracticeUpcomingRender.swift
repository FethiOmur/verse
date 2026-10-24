import AppKit
import Foundation
import SwiftUI
import VerseMeet
@testable import VerseUI
import XCTest

/// Renders the Practice page's Meeting picker with prepared sessions and upcoming calendar events, over the home window's
/// render scene. Runs only when `VERSE_RENDER_UPCOMING=<dir>` is set (otherwise skipped), so the normal test run opens no
/// window. Everything is fictional: the sessions are written into a temporary folder and the calendar is a fake backend
/// (the user's sessions and calendar are never read). `VERSE_BRAIN_DIR` must point at the brain.
///
/// The native pop-up menu is a window of its own that the offscreen capture does not include, so the "open" images draw the
/// menu (`MenuMock`) from the same `PracticeMeetings.menu` rows the real control lists: same labels, sections and order.
@MainActor
final class PracticeUpcomingRender: XCTestCase {
    private final class Calendar_: CalendarBackend, @unchecked Sendable {
        let all: [CalendarEntry]
        init(_ all: [CalendarEntry]) { self.all = all }
        func authorization() -> CalendarAuthorization { .fullAccess }
        func requestFullAccess() async throws -> Bool { false }
        func accountCount() -> Int { 1 }
        func entries(from: Date, to: Date) -> [CalendarEntry] { all.filter { $0.end > from && $0.start < to } }
    }

    private static let packFacts = (1...9).map { "[f\(String(format: "%03d", $0))] name | Fictional fact number \($0) about the company. | x | prep:L\($0)" }

    private func makeMeeting(_ name: String, in root: URL, questions: Int, daysAgo: Int) throws {
        let fm = FileManager.default
        let d = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let pack = "## FACTS\n" + Self.packFacts.joined(separator: "\n") + "\n\n## ANSWER BANK\n[b001] Q (en): Can you tell me about yourself?\nSAY: Sure.\n"
        try Data(pack.utf8).write(to: d.appendingPathComponent("pack.md"))
        let bank = (1...questions).map { #"{"id":"b\#(String(format: "%03d", $0))","question":"Question \#($0)?","points":["p"]}"# }.joined(separator: "\n")
        try Data((bank + "\n").utf8).write(to: d.appendingPathComponent("bank.jsonl"))
        let when = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try Data(#"{"created_at":"\#(ISO8601DateFormatter().string(from: when))","languages":["en"],"conversation":{"kind":"conversation","company":"Fictional"}}"#.utf8)
            .write(to: d.appendingPathComponent("meta.json"))
        for f in ["pack.md", "bank.jsonl", "meta.json"] { try fm.setAttributes([.modificationDate: when], ofItemAtPath: d.appendingPathComponent(f).path) }
    }

    /// Today (or `days` from now) at a fixed hour, so the rows read the same on every run.
    private func when(days: Int, hour: Int, minute: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private func entry(_ id: String, _ title: String, start: Date) -> CalendarEntry {
        CalendarEntry(id: id, title: title, start: start, end: start.addingTimeInterval(1_800),
                      url: URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    func testRenderThePickerWithUpcomingMeetings() async throws {
        guard let out = ProcessInfo.processInfo.environment["VERSE_RENDER_UPCOMING"], !out.isEmpty else { throw XCTSkip("VERSE_RENDER_UPCOMING not set") }
        let outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        let root = fixtures.root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMeeting("Northwind Labs technical", in: root, questions: 11, daysAgo: 2)
        try makeMeeting("Harbor & Pine intro call", in: root, questions: 14, daysAgo: 4)
        try makeMeeting("Lantern Health first call", in: root, questions: 9, daysAgo: 7)
        fixtures.controller.sessionsRoot = root

        let defaults = UserDefaults(suiteName: "dev.example.verse.render-upcoming-\(UUID().uuidString)")!
        let meetingSettings = MeetingSettings(defaults: defaults)
        meetingSettings.useCalendar = true
        let calendar = Calendar_([
            entry("n", "Northwind Labs technical", start: when(days: 0, hour: 17)),
            entry("d", "Design review with Ingrid", start: when(days: 1, hour: 10)),
            entry("t", "Tideline Studio first call", start: when(days: 3, hour: 14, minute: 30)),
            entry("q", "Quarterly planning with Mira", start: when(days: 9, hour: 11)),
        ])
        let upNext = HomeUpNextModel(settings: fixtures.settings, meeting: meetingSettings, sessions: { [] },
                                     calendar: CalendarSource(backend: calendar),
                                     eventMap: EventSessionMap(url: fixtures.root.appendingPathComponent("event-sessions.json")),
                                     prepare: { _, _ in
                                         try await Task.sleep(for: .seconds(4))
                                         throw CancellationError()
                                     })
        func context(_ router: HomeRouter) -> HomeContext {
            HomeContext(settings: fixtures.settings, controller: fixtures.controller, simSettings: fixtures.simSettings, sim: fixtures.sim,
                        conversation: fixtures.conversation, sessions: fixtures.sessions, upNext: upNext, me: fixtures.meModel(stale: false), router: router)
        }
        let sim = fixtures.sim
        func page() -> HomeRouter {
            let r = HomeRouter()
            r.page = .practice
            return r
        }
        func scene(dark: Bool) -> HomeRender.Scene { HomeRender.Scene(context: context(page()), dark: dark, override: nil) }
        func menuX() -> CGFloat { CGFloat(Double(ProcessInfo.processInfo.environment["VERSE_RENDER_MENU_X"] ?? "") ?? 688) }
        func menuY() -> CGFloat { CGFloat(Double(ProcessInfo.processInfo.environment["VERSE_RENDER_MENU_Y"] ?? "") ?? 252) }

        // Load the page's state once (the page does the same when it appears), then render.
        sim.attachUpcoming(upNext)
        sim.refreshMeetings()
        await sim.refreshUpcoming()
        XCTAssertEqual(sim.groups.upcoming.count, 3)
        XCTAssertEqual(sim.groups.prepared.count, 3)
        let menu = PracticeMeetings.menu(sim.groups, now: Date())

        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            // 1. The page as it opens: a prepared meeting selected (closed popup).
            try await HomeRender.capture(scene(dark: dark), size: HomeRender.canvas, dark: dark,
                                         to: outDir.appendingPathComponent("practice-upcoming-closed-\(name).png"))
            // 2. The picker open: both groups.
            try await HomeRender.capture(OpenMenuScene(base: scene(dark: dark), menu: menu, selected: sim.choice, dark: dark,
                                                      origin: CGPoint(x: menuX(), y: menuY())),
                                         size: HomeRender.canvas, dark: dark, to: outDir.appendingPathComponent("practice-upcoming-open-\(name).png"))
        }

        // 3. An upcoming event chosen: the preview line says it is not prepared yet.
        sim.choose(.upcoming("d"))
        XCTAssertEqual(sim.selectedUpcoming?.title, "Design review with Ingrid")
        for dark in [true, false] {
            try await HomeRender.capture(scene(dark: dark), size: HomeRender.canvas, dark: dark,
                                         to: outDir.appendingPathComponent("practice-upcoming-notprepared-\(dark ? "dark" : "light").png"))
        }

        // 4. Build interview: step 1 of 2 running (the event prep is a four-second stand-in here).
        setenv("VERSE_BRAIN_DIR", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain").path, 1)
        defer { unsetenv("VERSE_BRAIN_DIR") }
        sim.prepare()
        XCTAssertEqual(sim.prepStep, .invite)
        for dark in [true, false] {
            try await HomeRender.capture(scene(dark: dark), size: HomeRender.canvas, dark: dark,
                                         to: outDir.appendingPathComponent("practice-upcoming-step1-\(dark ? "dark" : "light").png"))
        }
        sim.cancelPrep()
    }
}

/// The page with the open pop-up menu drawn over it at `origin` (canvas points, top-left).
private struct OpenMenuScene: View {
    var base: HomeRender.Scene
    var menu: PracticeMeetings.PickerMenu
    var selected: MeetingChoice?
    var dark: Bool
    var origin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            base
            MenuMock(menu: menu, selected: selected, dark: dark).offset(x: origin.x, y: origin.y)
        }
        .frame(width: HomeRender.canvas.width, height: HomeRender.canvas.height, alignment: .topLeading)
    }
}

/// A drawing of a macOS pop-up menu with two titled sections. Only the render uses it.
private struct MenuMock: View {
    var menu: PracticeMeetings.PickerMenu
    var selected: MeetingChoice?
    var dark: Bool

    private var primary: Color { dark ? .white.opacity(0.92) : .black.opacity(0.88) }
    private var secondary: Color { dark ? .white.opacity(0.5) : .black.opacity(0.45) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            section("Prepared", menu.prepared)
            Rectangle().fill(secondary.opacity(0.25)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 6)
            section("Upcoming", menu.upcoming)
        }
        .padding(.vertical, 6).padding(.horizontal, 5)
        .frame(width: 340, alignment: .leading)
        .background(dark ? Color(white: 0.17).opacity(0.97) : Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(dark ? .white.opacity(0.14) : .black.opacity(0.12)))
        .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 18, y: 8)
    }

    @ViewBuilder private func section(_ title: String, _ rows: [PracticeMeetings.PickerMenu.Entry]) -> some View {
        Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(secondary).padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 2)
        ForEach(rows) { r in
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(r.id == selected ? 1 : 0).frame(width: 12)
                Text(verbatim: r.label).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(primary)
            .padding(.horizontal, 8).frame(height: 24)
        }
    }
}
