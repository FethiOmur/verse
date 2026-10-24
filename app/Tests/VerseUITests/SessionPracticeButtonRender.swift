import AppKit
import Foundation
import SwiftUI
@testable import VerseUI
import XCTest

/// Renders the Sessions page with the Practise button on a prepared session and on a past meeting (dark mode), over the home
/// window's render scene and its fictional fixtures. Runs only when `VERSE_RENDER_PRACTICEBTN=<dir>` is set (otherwise skipped),
/// so the normal test run opens no window. The sessions are its own fictional temp folder; nothing real is read.
@MainActor
final class SessionPracticeButtonRender: XCTestCase {
    private static let pack = "## FACTS\n[f001] name | Fictional fact about the company. | x | prep:L1\n[f002] role | Fictional fact about the role. | x | prep:L2\n"

    private func makeSession(_ name: String, in root: URL, summary: Bool, at when: Date) throws {
        let fm = FileManager.default
        let d = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(Self.pack.utf8).write(to: d.appendingPathComponent("pack.md"))
        try Data(#"{"created_at":"\#(ISO8601DateFormatter().string(from: when))","languages":["en"]}"#.utf8).write(to: d.appendingPathComponent("meta.json"))
        var touched = ["pack.md", "meta.json"]
        if summary {
            try Data(HomeRender.Fixtures.summaryText.utf8).write(to: d.appendingPathComponent("summary.md"))
            try Data(HomeRender.Fixtures.transcript.utf8).write(to: d.appendingPathComponent("transcript.jsonl"))
            touched += ["summary.md", "transcript.jsonl"]
        }
        for f in touched { try fm.setAttributes([.modificationDate: when], ofItemAtPath: d.appendingPathComponent(f).path) }
    }

    func testRenderPractiseButtonOnTheSessionDetail() async throws {
        guard let out = ProcessInfo.processInfo.environment["VERSE_RENDER_PRACTICEBTN"], !out.isEmpty else {
            throw XCTSkip("VERSE_RENDER_PRACTICEBTN not set")
        }
        let outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        let root = fixtures.root.appendingPathComponent("practicebtn-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cal = Calendar.current
        func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let d = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }
        try makeSession("Larkspur Case Review", in: root, summary: false, at: at(daysAgo: 1, hour: 16, minute: 52))
        try makeSession("Northwind Labs technical", in: root, summary: false, at: at(daysAgo: 2, hour: 10, minute: 5))
        try makeSession("Harbor Pine intro call", in: root, summary: true, at: at(daysAgo: 3, hour: 15, minute: 0))
        try makeSession("Brightwave first call", in: root, summary: true, at: at(daysAgo: 6, hour: 9, minute: 30))
        let suite = "dev.example.verse.render-practicebtn-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = HomeSessionsModel(root: root, defaults: defaults)
        model.reload()

        for (name, selected) in [("prepared", "Larkspur Case Review"), ("past", "Harbor Pine intro call")] {
            let router = HomeRouter()
            router.page = .sessions
            router.selectedSession = selected
            let url = outDir.appendingPathComponent("home-sessions-practise-\(name)-dark.png")
            try await HomeRender.capture(HomeRender.Scene(context: fixtures.context(router: router, sessions: model), dark: true, override: nil),
                                         size: HomeRender.canvas, dark: true, to: url)
        }
    }
}
