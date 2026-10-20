import AppKit
import Foundation
import SwiftUI
@testable import VerseUI
import XCTest

/// Renders the Practice page's "from a meeting" flow with fictional sessions, over the home window's render scene.
/// Runs only when `VERSE_RENDER_F4C=<dir>` is set (otherwise skipped), so the normal test run opens no window.
/// It reuses `HomeRender.Fixtures` and points the meeting controller's sessions folder at its own temp folder, so no real
/// session is read. `VERSE_BRAIN_DIR` must point at the brain (the prepared state runs prep with the offline fake model).
@MainActor
final class PracticeFromSessionRender: XCTestCase {
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
        let created = ISO8601DateFormatter().string(from: when)
        try Data(#"{"created_at":"\#(created)","languages":["en"],"conversation":{"kind":"conversation","company":"Fictional"}}"#.utf8)
            .write(to: d.appendingPathComponent("meta.json"))
        for f in ["pack.md", "bank.jsonl", "meta.json"] { try fm.setAttributes([.modificationDate: when], ofItemAtPath: d.appendingPathComponent(f).path) }
    }

    func testRenderPracticeFromAMeeting() async throws {
        guard let out = ProcessInfo.processInfo.environment["VERSE_RENDER_F4C"], !out.isEmpty else { throw XCTSkip("VERSE_RENDER_F4C not set") }
        let outDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let fixtures = try HomeRender.Fixtures()
        defer { fixtures.cleanUp() }
        let root = fixtures.root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMeeting("Harbor & Pine intro call", in: root, questions: 14, daysAgo: 1)
        try makeMeeting("Northwind Labs technical", in: root, questions: 11, daysAgo: 3)
        try makeMeeting("Lantern Health first call", in: root, questions: 9, daysAgo: 6)
        fixtures.controller.sessionsRoot = root
        fixtures.upNext.setItems([
            HomeUpNextItem(id: "a", title: "Northwind Labs technical", meta: "Today 15:00 · Zoom · in 40 minutes", session: "Northwind Labs technical"),
            HomeUpNextItem(id: "b", title: "Design review with Ingrid", meta: "Tomorrow 10:00 · Meet", session: nil),
        ])
        // The page picks "A meeting" and the nearest Up next session when it appears (setup); the render shows that state.
        for dark in [false, true] {
            let router = HomeRouter()
            router.page = .practice
            let url = outDir.appendingPathComponent("home-practice-meeting-\(dark ? "dark" : "light").png")
            try await HomeRender.capture(HomeRender.Scene(context: fixtures.context(router: router), dark: dark, override: nil), size: HomeRender.canvas, dark: dark, to: url)
            // Up next with the Practise button.
            let prep = HomeRouter()
            prep.page = .prepare
            let up = outDir.appendingPathComponent("home-prepare-upnext-practise-\(dark ? "dark" : "light").png")
            try await HomeRender.capture(HomeRender.Scene(context: fixtures.context(router: prep), dark: dark, override: nil), size: HomeRender.canvas, dark: dark, to: up)
        }

        // Built: prep over the fictional session with the offline model.
        fixtures.settings.fakeBrain = true
        fixtures.sim.selectMeeting("Harbor & Pine intro call")
        fixtures.sim.prepare()
        for _ in 0..<300 where fixtures.sim.phase == .preparing { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(fixtures.sim.phase, .prepared, "prep: \(fixtures.sim.prepError ?? "") \(fixtures.sim.prepLines.suffix(3))")
        for dark in [false, true] {
            let router = HomeRouter()
            router.page = .practice
            let url = outDir.appendingPathComponent("home-practice-meeting-built-\(dark ? "dark" : "light").png")
            try await HomeRender.capture(HomeRender.Scene(context: fixtures.context(router: router), dark: dark, override: nil), size: HomeRender.canvas, dark: dark, to: url)
        }
    }
}
