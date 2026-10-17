import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The standing general prep: seeding unprepared folders, and keeping `general-core` out of the pickers.
@MainActor
final class GeneralPrepTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-16T14:32:10Z")! }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-general-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A fictional general prep: pack, bank (2 answers), glossary; no facts or snippets.
    private func makeGeneral(_ r: URL, pack: String = "# Fixture pack\nAcme Widgets\n") throws {
        let d = r.appendingPathComponent("general-core", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try pack.write(to: d.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        try "{\"q\":\"Why Acme?\"}\n{\"q\":\"Describe a widget.\"}\n".write(to: d.appendingPathComponent("bank.jsonl"), atomically: true, encoding: .utf8)
        try "{\"term\":\"widget\"}\n".write(to: d.appendingPathComponent("glossary.jsonl"), atomically: true, encoding: .utf8)
    }

    private func read(_ r: URL, _ name: String, _ f: String) -> String? {
        try? String(contentsOf: r.appendingPathComponent(name).appendingPathComponent(f), encoding: .utf8)
    }

    func testAdhocFolderIsSeededFromGeneralPrep() throws {
        let r = try root()
        try makeGeneral(r)
        let n = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: r, timeZone: utc, useGeneralPrep: true)
        XCTAssertEqual(read(r, n, "pack.md"), "# Fixture pack\nAcme Widgets\n")
        XCTAssertEqual(read(r, n, "bank.jsonl")?.split(separator: "\n").count, 2)
        XCTAssertNotNil(read(r, n, "glossary.jsonl"))
        XCTAssertNil(read(r, n, "facts.jsonl"), "files that do not exist in general-core are not invented")
        let meta = AdhocMeta.read(sessionDir: SessionCatalog.url(n, root: r))
        XCTAssertEqual(meta?.base, "general-core")
        XCTAssertEqual(meta?.mode, "unprepared")
        // A copy: a later rebuild of general-core leaves the past session alone.
        try "changed".write(to: r.appendingPathComponent("general-core/pack.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(read(r, n, "pack.md"), "# Fixture pack\nAcme Widgets\n")
        let row = HomeSession.load(name: n, root: r)
        XCTAssertTrue(row.unprepared)
    }

    func testToggleOffOrMissingOrEmptyGivesAnEmptyPack() throws {
        let r = try root()
        try makeGeneral(r)
        let off = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: r, timeZone: utc, useGeneralPrep: false)
        XCTAssertEqual(read(r, off, "pack.md"), "")
        XCTAssertNil(AdhocMeta.read(sessionDir: SessionCatalog.url(off, root: r))?.base)

        let empty = try root()
        let none = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: empty, timeZone: utc, useGeneralPrep: true)
        XCTAssertEqual(read(empty, none, "pack.md"), "")
        XCTAssertNil(AdhocMeta.read(sessionDir: SessionCatalog.url(none, root: empty))?.base)

        let blank = try root()
        try makeGeneral(blank, pack: "")
        let b = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: blank, timeZone: utc, useGeneralPrep: true)
        XCTAssertEqual(read(blank, b, "pack.md"), "")
        XCTAssertNil(read(blank, b, "bank.jsonl"))
    }

    func testPlanSeedsOnlyUnpreparedSessions() throws {
        let r = try root()
        try makeGeneral(r)
        let plan = try QuickStart.plan(now: now, facts: .init(), events: [], remembered: [:], sessions: [], lang: "en", root: r,
                                       timeZone: utc, useGeneralPrep: true)
        XCTAssertEqual(plan.mode, .unprepared)
        XCTAssertEqual(read(r, plan.session, "bank.jsonl")?.split(separator: "\n").count, 2)
    }

    func testGeneralCoreIsHiddenFromPickerAndSessionsPage() throws {
        let r = try root()
        try makeGeneral(r)
        let other = r.appendingPathComponent("acme-interview", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "pack".write(to: other.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        let c = VerseController(settings: AppSettings(defaults: UserDefaults(suiteName: "verse-general-\(UUID().uuidString)")))
        c.sessionsRoot = r
        c.refreshSessions()
        // The picker, the calendar mapping and Start prepared all read this list.
        XCTAssertEqual(c.sessions, ["acme-interview"])
        XCTAssertEqual(HomeSessionsModel(root: r).sessions.map(\.name), ["acme-interview"])
    }

    func testStatusText() throws {
        let r = try root()
        XCTAssertNil(GeneralPrep.status(root: r))
        try makeGeneral(r)
        let s = try XCTUnwrap(GeneralPrep.status(root: r))
        XCTAssertEqual(s.answers, 2)
        XCTAssertTrue(s.text().hasPrefix("2 answers · built "))
    }

    func testSettingDefaultsOn() {
        let d = UserDefaults(suiteName: "verse-general-\(UUID().uuidString)")!
        XCTAssertTrue(AppSettings(defaults: d).useGeneralPrep)
    }
}
