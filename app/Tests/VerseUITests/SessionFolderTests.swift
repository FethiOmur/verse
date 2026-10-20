import Foundation
@testable import VerseUI
import XCTest

@MainActor
final class SessionFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try FolderFixtures.scratch() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store(now: @escaping () -> Date = Date.init) -> SessionFolderStore { SessionFolderStore(root: root, now: now) }

    // MARK: round trips

    func testCreateRenameMoveDeleteRoundTripThroughTheFile() throws {
        try FolderFixtures.session("ironwood-lena", in: root)
        try FolderFixtures.session("acme-kickoff", in: root)
        let a = store()
        let acme = try a.create(name: "  Acme ")
        let plural = try a.create(name: "Ironwood")
        XCTAssertEqual(acme.name, "Acme", "names are trimmed")
        XCTAssertTrue(acme.id.range(of: "^f-[0-9a-z]{8}$", options: .regularExpression) != nil, acme.id)
        try a.move("ironwood-lena", to: plural.id)
        try a.move("acme-kickoff", to: acme.id)

        // A fresh store reads the same index back.
        let b = store()
        XCTAssertEqual(b.folders.map(\.name), ["Acme", "Ironwood"])
        XCTAssertEqual(b.folder(of: "ironwood-lena")?.name, "Ironwood")
        XCTAssertEqual(b.folder(of: "acme-kickoff")?.id, acme.id)

        try b.rename(acme.id, to: "Acme Corp")
        XCTAssertEqual(store().folder(of: "acme-kickoff")?.name, "Acme Corp", "a rename keeps the assignments")

        try b.move("acme-kickoff", to: nil)
        XCTAssertNil(store().folder(of: "acme-kickoff"))

        try b.delete(plural.id)
        let c = store()
        XCTAssertEqual(c.folders.map(\.name), ["Acme Corp"])
        XCTAssertNil(c.folder(of: "ironwood-lena"))
    }

    func testTheFileHasTheDocumentedShape() throws {
        try FolderFixtures.session("ironwood-lena", in: root)
        let at = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!
        let s = store(now: { at })
        let f = try s.create(name: "Acme")
        try s.move("ironwood-lena", to: f.id)
        try s.dismissSuggestion("Ironwood", for: "ironwood-lena")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("folders.json"))) as! [String: Any]
        XCTAssertEqual(obj["version"] as? Int, 1)
        let folders = obj["folders"] as! [[String: Any]]
        XCTAssertEqual(folders[0]["created_at"] as? String, "2026-10-20T10:00:00Z")
        XCTAssertEqual(folders[0]["used_at"] as? String, "2026-10-20T10:00:00Z")
        XCTAssertEqual((obj["assign"] as? [String: String])?["ironwood-lena"], f.id)
        XCTAssertEqual((obj["dismissed"] as? [String: [String]])?["ironwood-lena"], ["Ironwood"])
    }

    func testUnknownKeysAreIgnoredOnRead() throws {
        try FolderFixtures.session("ironwood-lena", in: root)
        let json = #"{"version":1,"future":{"x":1},"folders":[{"id":"f-aaaaaaaa","name":"Acme","created_at":"2026-10-20T10:00:00Z","used_at":"2026-10-20T10:05:00Z","color":"red"}],"assign":{"ironwood-lena":"f-aaaaaaaa"}}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("folders.json"))
        let s = store()
        XCTAssertEqual(s.folders.map(\.name), ["Acme"])
        XCTAssertEqual(s.folder(of: "ironwood-lena")?.name, "Acme")
        XCTAssertNil(s.notice)
    }

    func testUsedAtFollowsMovesIntoAFolder() throws {
        try FolderFixtures.session("a", in: root)
        var clock = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!
        let s = store(now: { clock })
        let f = try s.create(name: "Acme")
        clock = clock.addingTimeInterval(600)
        try s.move("a", to: f.id)
        XCTAssertEqual(s.folders[0].usedAt, clock)
        XCTAssertLessThan(s.folders[0].createdAt, s.folders[0].usedAt)
    }

    // MARK: sessions are never touched

    func testDeletingAFolderLeavesEverySessionFolderAndFileUntouched() throws {
        let fm = FileManager.default
        try FolderFixtures.session("ironwood-lena", in: root, files: ["transcript.jsonl": #"{"text":"hi"}"#, "events.jsonl": "{}"])
        try FolderFixtures.session("acme-kickoff", in: root)
        let s = store()
        let f = try s.create(name: "Ironwood")
        try s.move("ironwood-lena", to: f.id)
        let before = try FolderFixtures.snapshot(root).filter { !$0.key.hasSuffix("folders.json") }
        XCTAssertTrue(before.keys.contains("/ironwood-lena/transcript.jsonl"))

        try s.rename(f.id, to: "Ironwood Lena")
        try s.delete(f.id)

        let after = try FolderFixtures.snapshot(root).filter { !$0.key.hasSuffix("folders.json") }
        XCTAssertEqual(before, after, "directory listing and hashes are the same")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ironwood-lena/pack.md").path))
        XCTAssertNil(store().folder(of: "ironwood-lena"))
    }

    func testSessionCatalogListIsUnchangedByFoldersJson() throws {
        try FolderFixtures.session("b-session", in: root)
        try FolderFixtures.session("a-session", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true)
        let before = SessionCatalog.list(root: root)
        let s = store()
        let f = try s.create(name: "Acme")
        try s.move("a-session", to: f.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folders.json").path))
        XCTAssertEqual(SessionCatalog.list(root: root), before)
        XCTAssertEqual(before, ["a-session", "b-session"])
    }

    // MARK: names

    func testDuplicateNamesAfterFoldingAreRefused() throws {
        let s = store()
        try s.create(name: "Café Müller")
        for dup in ["café müller", "CAFE MULLER", "  Cafe Müller  "] {
            XCTAssertThrowsError(try s.create(name: dup)) { XCTAssertEqual($0 as? FolderError, .duplicateName, dup) }
        }
        let other = try s.create(name: "Acme")
        XCTAssertThrowsError(try s.rename(other.id, to: "cafe muller")) { XCTAssertEqual($0 as? FolderError, .duplicateName) }
        XCTAssertNoThrow(try s.rename(other.id, to: "ACME"), "a folder may change its own case")
        XCTAssertEqual(s.folders.map(\.name), ["Café Müller", "ACME"])
    }

    func testEmptyAndTooLongNamesAreRefused() throws {
        let s = store()
        for empty in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try s.create(name: empty)) { XCTAssertEqual($0 as? FolderError, .emptyName) }
        }
        XCTAssertThrowsError(try s.create(name: String(repeating: "a", count: 61))) { XCTAssertEqual($0 as? FolderError, .tooLong) }
        XCTAssertNoThrow(try s.create(name: String(repeating: "b", count: 60)))
        XCTAssertEqual(s.folders.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("folders.json").path) && s.folders.isEmpty)
    }

    // MARK: pruning and bad files

    func testAssignmentsToVanishedSessionsArePrunedOnTheNextWrite() throws {
        try FolderFixtures.session("stays", in: root)
        try FolderFixtures.session("goes", in: root)
        let s = store()
        let f = try s.create(name: "Acme")
        try s.move("stays", to: f.id)
        try s.move("goes", to: f.id)
        try s.dismissSuggestion("Other", for: "goes")
        XCTAssertEqual(s.file.assign.count, 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("goes"))
        try s.rename(f.id, to: "Acme Inc")
        XCTAssertEqual(Set(s.file.assign.keys), ["stays"])
        XCTAssertNil(s.file.dismissed["goes"])
        XCTAssertEqual(Set(store().file.assign.keys), ["stays"], "pruned on disk too")
    }

    func testAnUnreadableFileIsRenamedNotDeleted() throws {
        let url = root.appendingPathComponent("folders.json")
        let junk = "{ this is not json"
        try Data(junk.utf8).write(to: url)
        let s = store()
        XCTAssertTrue(s.folders.isEmpty)
        XCTAssertNotNil(s.notice, "a note is shown once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("folders.json.unreadable-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(kept[0]), encoding: .utf8), junk, "its bytes are kept")

        _ = try s.create(name: "Acme")
        XCTAssertNil(s.notice, "the note goes with the next change")
        XCTAssertNil(store().notice)
    }

    func testAMissingFileMeansNoFoldersAndNoNote() {
        let s = store()
        XCTAssertTrue(s.folders.isEmpty)
        XCTAssertNil(s.notice)
    }

    // MARK: the model: grouping, mode, derived practice runs

    private func model(_ defaults: UserDefaults) -> HomeSessionsModel { HomeSessionsModel(root: root, defaults: defaults) }

    func testGroupingOrdersByNewestSessionThenEmptyFoldersThenNoFolder() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let now = Date()
        try FolderFixtures.session("harbor-kickoff", in: root, at: now.addingTimeInterval(-86_400 * 5))
        try FolderFixtures.session("harbor-pricing", in: root, at: now.addingTimeInterval(-86_400 * 4))
        try FolderFixtures.session("northwind-intro", in: root, at: now.addingTimeInterval(-60))
        try FolderFixtures.session("tideline-demo", in: root, at: now.addingTimeInterval(-86_400 * 2))
        try FolderFixtures.session("loose-old", in: root, at: now.addingTimeInterval(-86_400 * 9))
        try FolderFixtures.session("loose-new", in: root, at: now.addingTimeInterval(-3_600))
        let m = model(defaults)
        let harbor = try m.folders.create(name: "Harbor Ledger")
        let northwind = try m.folders.create(name: "Northwind")
        let tideline = try m.folders.create(name: "Tideline")
        _ = try m.folders.create(name: "Zeta")
        _ = try m.folders.create(name: "Alpha")
        try m.folders.move("harbor-kickoff", to: harbor.id)
        try m.folders.move("harbor-pricing", to: harbor.id)
        try m.folders.move("northwind-intro", to: northwind.id)
        try m.folders.move("tideline-demo", to: tideline.id)

        let sections = m.sections
        XCTAssertEqual(sections.map { $0.folder?.name ?? "-" }, ["Northwind", "Tideline", "Harbor Ledger", "Alpha", "Zeta", "-"])
        XCTAssertEqual(sections.last?.id, HomeSessionSection.noFolderID)
        XCTAssertEqual(sections.last?.sessions.map(\.name), ["loose-new", "loose-old"], "newest first")
        XCTAssertEqual(sections[2].sessions.map(\.name), ["harbor-pricing", "harbor-kickoff"])
        XCTAssertEqual(m.sessionCount(in: harbor.id), 2)
    }

    func testNoFolderSectionIsOmittedWhenEverySessionIsFiled() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        try FolderFixtures.session("only", in: root)
        let m = model(defaults)
        let f = try m.folders.create(name: "Acme")
        try m.folders.move("only", to: f.id)
        XCTAssertEqual(m.sections.map(\.id), [f.id])
    }

    func testListModeDefaultsToFoldersOnceOneExistsAndIsRemembered() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        try FolderFixtures.session("a", in: root)
        let m = model(defaults)
        XCTAssertEqual(m.mode, .recent, "no folder yet")
        XCTAssertNil(m.createFolder(named: "Acme", filing: "a"))
        XCTAssertEqual(m.mode, .folders)
        m.setMode(.recent)
        XCTAssertEqual(model(defaults).mode, .recent, "remembered")
        m.toggleCollapsed(m.folders.folders[0].id)
        XCTAssertTrue(model(defaults).isCollapsed(m.folders.folders[0].id), "collapsed sections are remembered")
        m.deleteFolder(m.folders.folders[0].id)
        XCTAssertTrue(model(defaults).collapsed.isEmpty, "a deleted folder's collapse state goes with it")
        XCTAssertEqual(model(defaults).mode, .recent)
    }

    func testAPracticeRunBuiltFromAFiledSessionGoesIntoThatFolderOnce() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let now = Date()
        try FolderFixtures.session("harbor-kickoff", in: root, at: now.addingTimeInterval(-3_600))
        let simName = "sim-20261020-0900-harbor-kickoff"
        try FolderFixtures.session(simName, in: root, at: now, files: ["report.html": "<html></html>",
            "sim.json": #"{"source":"session","source_session":"harbor-kickoff","company":"Harbor Ledger","posting_url":null}"#])
        let loose = "sim-20261020-0930-stray"
        try FolderFixtures.session(loose, in: root, at: now, files: ["report.html": "<html></html>", "sim.json": #"{"company":"Unknown company"}"#])

        let m = model(defaults)
        let f = try m.folders.create(name: "Harbor Ledger")
        XCTAssertNil(m.folder(of: m.session(named: simName)!), "unfiled until the source is in a folder")
        try m.folders.move("harbor-kickoff", to: f.id)
        m.reload()
        XCTAssertEqual(m.folders.folder(of: simName)?.id, f.id, "auto-assigned, no question")
        XCTAssertNil(m.folders.folder(of: loose), "a run with no source session is left alone")
        XCTAssertEqual(store().folder(of: simName)?.id, f.id, "and it is written")

        // He takes it out: it does not come back on the next reload.
        m.move(simName, to: nil)
        m.reload()
        XCTAssertNil(m.folders.folder(of: simName))
        // Moving it back by hand clears that.
        m.move(simName, to: f.id)
        XCTAssertEqual(m.folders.folder(of: simName)?.id, f.id)
    }

    func testRemovingAFiledSessionDoesNotSuggestTheSameFolderAgain() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        try FolderFixtures.session("ironwood-lena", in: root)
        let m = model(defaults)
        let f = try m.folders.create(name: "Ironwood")
        let s = m.session(named: "ironwood-lena")!
        XCTAssertEqual(m.suggestion(for: s), .existing(f))
        m.accept(.existing(f), for: s.name)
        XCTAssertNil(m.suggestion(for: s), "filed sessions get no chip")
        m.move(s.name, to: nil)
        XCTAssertNil(m.suggestion(for: s), "taking it out is a no")
    }

    func testAcceptingANewFolderSuggestionCreatesAndFilesInOneStep() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        try FolderFixtures.session("conv-20261015-1857-northwind-labs", in: root,
                                   files: ["meta.json": #"{"conversation":{"company":"Northwind Labs","people":["Dana"]}}"#])
        let m = model(defaults)
        let s = m.session(named: "conv-20261015-1857-northwind-labs")!
        XCTAssertEqual(m.suggestion(for: s), .new("Northwind Labs"))
        m.accept(.new("Northwind Labs"), for: s.name)
        XCTAssertEqual(m.folders.folders.map(\.name), ["Northwind Labs"])
        XCTAssertEqual(m.folders.folder(of: s.name)?.name, "Northwind Labs")
        XCTAssertEqual(m.mode, .folders)
    }

    func testCreatingFromTheModelReportsValidationErrors() {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let m = model(defaults)
        XCTAssertNil(m.createFolder(named: "Acme"))
        XCTAssertEqual(m.createFolder(named: "acme"), .duplicateName)
        XCTAssertEqual(m.createFolder(named: " "), .emptyName)
        XCTAssertEqual(m.renameFolder(m.folders.folders[0].id, to: String(repeating: "x", count: 61)), .tooLong)
        XCTAssertFalse(FolderError.duplicateName.message.isEmpty)
    }

    func testMovingAnUnknownSessionIsIgnored() throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let m = model(defaults)
        let f = try m.folders.create(name: "Acme")
        m.move("no-such-session", to: f.id)
        XCTAssertTrue(m.folders.file.assign.isEmpty)
    }
}
