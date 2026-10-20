import Foundation
import SwiftUI
@testable import VerseUI
import XCTest

/// Move to Trash on the Sessions page. Scratch roots only; the Trash is a fake folder (`SessionTrashOps` is injected), so nothing
/// here touches the real Trash or the user's sessions.
@MainActor
final class SessionTrashTests: XCTestCase {
    private var root: URL!
    private var trashDir: URL!

    /// Records what the model asked of the Trash and moves the folder into `trashDir` the way `trashItem` would.
    private final class FakeTrash: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [URL] = []
        private var _failing: Set<String> = []
        let dir: URL
        init(dir: URL) { self.dir = dir }
        var calls: [URL] { lock.withLock { _calls } }
        func fail(_ name: String) { lock.withLock { _ = _failing.insert(name) } }

        var ops: SessionTrashOps {
            SessionTrashOps(
                trash: { [self] url in
                    struct Refused: Error {}
                    let refuse = lock.withLock { _calls.append(url); return _failing.contains(url.lastPathComponent) }
                    if refuse { throw Refused() }
                    let slot = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                    let dest = slot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                    try FileManager.default.moveItem(at: url, to: dest)
                    return dest
                },
                restore: { from, to in try FileManager.default.moveItem(at: from, to: to) })
        }
    }

    private struct Rig {
        var model: HomeSessionsModel
        var controller: VerseController
        var settings: AppSettings
        var router: HomeRouter
        var trash: FakeTrash
        var defaultsCleanup: () -> Void
    }

    override func setUp() async throws {
        root = try FolderFixtures.scratch()
        trashDir = try FolderFixtures.scratch()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trashDir)
    }

    private func rig(start: String? = nil) -> Rig {
        let (defaults, cleanup) = FolderFixtures.defaults()
        let settings = AppSettings(defaults: defaults)
        let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        controller.sessionsRoot = root
        let trash = FakeTrash(dir: trashDir)
        let model = HomeSessionsModel(root: root, defaults: defaults, trashOps: trash.ops,
                                      eventMap: EventSessionMap(url: root.appendingPathComponent("event-sessions.json")))
        let router = HomeRouter()
        model.hooks = .window(controller: controller, sim: nil, settings: settings, router: router)
        controller.refreshSessions()
        if let start { settings.sessionName = start }
        return Rig(model: model, controller: controller, settings: settings, router: router, trash: trash, defaultsCleanup: cleanup)
    }

    private func foldersJSON() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("folders.json"))) as? [String: Any] ?? [:]
    }

    private func undoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    // MARK: the folder goes to the Trash

    func testTheSessionFolderIsTrashedThroughTheInjectedOperationAndNothingElseMoves() throws {
        try FolderFixtures.session("acme-kickoff", in: root, files: ["notes.txt": "keep me"])
        let other = try FolderFixtures.session("northwind-intro", in: root)
        let before = try FolderFixtures.snapshot(root.appendingPathComponent("acme-kickoff"))
        let otherBefore = try FolderFixtures.snapshot(other)
        let r = rig()
        defer { r.defaultsCleanup() }
        XCTAssertEqual(Set(r.model.sessions.map(\.name)), ["acme-kickoff", "northwind-intro"])

        let outcome = r.model.trash(["acme-kickoff"])

        XCTAssertEqual(r.trash.calls.map(\.lastPathComponent), ["acme-kickoff"], "the injected operation was asked once")
        XCTAssertEqual(outcome.batch?.names, ["acme-kickoff"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("acme-kickoff").path))
        let landed = try XCTUnwrap(outcome.batch?.items.first?.trashed)
        XCTAssertEqual(try FolderFixtures.snapshot(landed), before, "the folder arrives in the Trash whole")
        XCTAssertEqual(try FolderFixtures.snapshot(other), otherBefore, "the other session is untouched")
        XCTAssertEqual(r.model.sessions.map(\.name), ["northwind-intro"])
        XCTAssertEqual(r.model.toast?.message, "Moved to Trash")
        XCTAssertEqual(r.model.toast?.undoable, true)
    }

    func testTheSourceNeverRemovesAFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VerseUI/SessionTrash.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("removeItem"), "Move to Trash must never delete")
        XCTAssertTrue(text.contains("trashItem"))
    }

    // MARK: what the app kept elsewhere

    func testTheFoldersEntryAndTheDismissedSuggestionsGoFromTheIndex() throws {
        try FolderFixtures.session("acme-kickoff", in: root)
        try FolderFixtures.session("acme-demo", in: root)
        let r = rig()
        defer { r.defaultsCleanup() }
        let acme = try r.model.folders.create(name: "Acme")
        try r.model.folders.move("acme-kickoff", to: acme.id)
        try r.model.folders.move("acme-demo", to: acme.id)
        try r.model.folders.dismissSuggestion("Ironwood", for: "acme-kickoff")

        r.model.trash(["acme-kickoff"])

        let json = try foldersJSON()
        XCTAssertEqual((json["assign"] as? [String: String])?["acme-kickoff"], nil)
        XCTAssertEqual((json["dismissed"] as? [String: [String]])?["acme-kickoff"], nil)
        XCTAssertEqual((json["assign"] as? [String: String])?["acme-demo"], acme.id, "a neighbour keeps its folder")
        XCTAssertEqual(r.model.folders.folders.map(\.name), ["Acme"], "the folder itself stays")
    }

    func testEveryEventMappedToTheSessionIsDropped() throws {
        try FolderFixtures.session("acme-kickoff", in: root)
        try FolderFixtures.session("northwind-intro", in: root)
        let r = rig()
        defer { r.defaultsCleanup() }
        r.model.eventMap.remember(eventID: "e1", session: "acme-kickoff")
        r.model.eventMap.remember(eventID: "e2", session: "acme-kickoff")
        r.model.eventMap.remember(eventID: "e3", session: "northwind-intro")

        r.model.trash(["acme-kickoff"])

        XCTAssertEqual(r.model.eventMap.load(), ["e3": "northwind-intro"])
    }

    func testTheModelNeverTouchesTheRealEventMapForAScratchRoot() {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let m = HomeSessionsModel(root: root, defaults: defaults)
        XCTAssertTrue(m.eventMap.url.path.hasPrefix(root.path), m.eventMap.url.path)
    }

    func testStartFallsBackTheWayARefreshDoesWhenItsSessionIsTrashed() throws {
        for n in ["a-call", "b-call", "c-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig(start: "b-call")
        defer { r.defaultsCleanup() }
        XCTAssertEqual(r.settings.sessionName, "b-call")

        r.model.trash(["b-call"])

        XCTAssertEqual(r.controller.sessions, ["a-call", "c-call"])
        XCTAssertEqual(r.settings.sessionName, "a-call", "the first remaining session, like refreshSessions")
    }

    func testTrashingAnotherSessionLeavesTheStartChoiceAlone() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig(start: "b-call")
        defer { r.defaultsCleanup() }
        r.model.trash(["a-call"])
        XCTAssertEqual(r.settings.sessionName, "b-call")
    }

    // MARK: blocked

    func testTheRecordingSessionCannotBeTrashed() throws {
        let dir = try FolderFixtures.session("live-call", in: root)
        try FolderFixtures.session("old-call", in: root)
        let r = rig()
        defer { r.defaultsCleanup() }
        r.controller.setRunningForPreview(true, session: dir)
        XCTAssertEqual(r.controller.recordingSessionName, "live-call")
        XCTAssertEqual(r.model.blockReason(for: "live-call"), .recording)
        XCTAssertNil(r.model.blockReason(for: "old-call"))
        XCTAssertEqual(r.model.deletable(["live-call", "old-call"]), ["old-call"])

        let outcome = r.model.trash(["live-call"])

        XCTAssertEqual(outcome.blocked, ["live-call": .recording])
        XCTAssertNil(outcome.batch)
        XCTAssertTrue(r.trash.calls.isEmpty, "the Trash was never asked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(r.model.toast)

        // A multi-selection trashes what it can and leaves the recording one.
        let both = r.model.trash(["live-call", "old-call"])
        XCTAssertEqual(both.batch?.names, ["old-call"])
        XCTAssertEqual(both.blocked.keys.sorted(), ["live-call"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        r.controller.setRunningForPreview(false)
        XCTAssertNil(r.model.blockReason(for: "live-call"), "free again when the call ends")
    }

    func testTheGeneralPrepIsNeverTrashable() {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let m = HomeSessionsModel(root: root, defaults: defaults)
        XCTAssertEqual(m.blockReason(for: GeneralPrep.name), .general)
        XCTAssertEqual(m.deletable([GeneralPrep.name]), [])
    }

    func testAFailedTrashLeavesTheSessionAndItsEntriesWhereTheyWere() throws {
        try FolderFixtures.session("acme-kickoff", in: root)
        let r = rig()
        defer { r.defaultsCleanup() }
        let acme = try r.model.folders.create(name: "Acme")
        try r.model.folders.move("acme-kickoff", to: acme.id)
        r.model.eventMap.remember(eventID: "e1", session: "acme-kickoff")
        r.trash.fail("acme-kickoff")

        let outcome = r.model.trash(["acme-kickoff"])

        XCTAssertEqual(outcome.failed, ["acme-kickoff"])
        XCTAssertNil(outcome.batch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("acme-kickoff").path))
        XCTAssertEqual(r.model.folders.folder(of: "acme-kickoff")?.id, acme.id)
        XCTAssertEqual(r.model.eventMap.load(), ["e1": "acme-kickoff"])
        XCTAssertEqual(r.model.toast?.isError, true)
        XCTAssertEqual(r.model.toast?.undoable, false)
    }

    // MARK: undo

    func testUndoBringsBackTheFolderItsIndexEntryItsEventAndItsStartChoice() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root, files: ["notes.txt": "kept \(n)"]) }
        let r = rig(start: "b-call")
        defer { r.defaultsCleanup() }
        let acme = try r.model.folders.create(name: "Acme")
        try r.model.folders.move("b-call", to: acme.id)
        try r.model.folders.dismissSuggestion("Ironwood", for: "b-call")
        r.model.eventMap.remember(eventID: "e1", session: "b-call")
        r.router.selectedSession = "b-call"
        let before = try FolderFixtures.snapshot(root.appendingPathComponent("b-call"))
        let um = undoManager()

        r.model.trash(["b-call"], undoManager: um)
        XCTAssertEqual(um.undoActionName, "Move to Trash", "Edit shows “Undo Move to Trash”")
        XCTAssertEqual(r.settings.sessionName, "a-call")
        XCTAssertEqual(r.router.selectedSession, "a-call", "the selection moved to the next row")
        XCTAssertNil(r.model.folders.folder(of: "b-call"))

        um.undo()

        XCTAssertEqual(try FolderFixtures.snapshot(root.appendingPathComponent("b-call")), before, "the folder is back, byte for byte")
        XCTAssertEqual(Set(r.model.sessions.map(\.name)), ["a-call", "b-call"])
        XCTAssertEqual(r.model.folders.folder(of: "b-call")?.id, acme.id, "its place in the folder")
        XCTAssertTrue(r.model.folders.isDismissed("Ironwood", for: "b-call"))
        XCTAssertEqual(r.model.eventMap.load(), ["e1": "b-call"])
        XCTAssertEqual(r.settings.sessionName, "b-call", "Start uses it again")
        XCTAssertEqual(r.router.selectedSession, "b-call")
        XCTAssertNil(r.model.toast, "the bar is gone once it is undone")
        XCTAssertTrue(um.canRedo)
        XCTAssertEqual(um.redoActionName, "Move to Trash")

        um.redo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b-call").path), "redo moves it to the Trash again")
        XCTAssertNil(r.model.folders.folder(of: "b-call"))
    }

    func testUndoKeepsALaterStartChoice() throws {
        for n in ["a-call", "b-call", "c-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig(start: "b-call")
        defer { r.defaultsCleanup() }
        let um = undoManager()
        r.model.trash(["b-call"], undoManager: um)
        r.settings.sessionName = "c-call"
        um.undo()
        XCTAssertEqual(r.settings.sessionName, "c-call", "he picked another one meanwhile; undo does not take that back")
    }

    func testUndoDoesNotRestoreAnEventThatPointsElsewhereNow() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        r.model.eventMap.remember(eventID: "e1", session: "b-call")
        let um = undoManager()
        r.model.trash(["b-call"], undoManager: um)
        r.model.eventMap.remember(eventID: "e1", session: "a-call")
        um.undo()
        XCTAssertEqual(r.model.eventMap.load(), ["e1": "a-call"])
    }

    func testTheToastUndoDoesWhatCommandZDoes() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        let um = undoManager()
        r.model.trash(["b-call"], undoManager: um)
        XCTAssertNotNil(r.model.toast)

        r.model.undoFromToast()

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b-call").path))
        XCTAssertFalse(um.canUndo, "it went through the window's undo manager")
        XCTAssertTrue(um.canRedo)
        XCTAssertNil(r.model.toast)
    }

    func testTheToastUndoWorksWithoutAnUndoManager() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        r.model.trash(["b-call"])
        r.model.undoFromToast()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b-call").path))
        XCTAssertEqual(Set(r.model.sessions.map(\.name)), ["a-call", "b-call"])
    }

    func testTheToastGoesAwayByItself() async throws {
        try FolderFixtures.session("a-call", in: root)
        let r = rig()
        defer { r.defaultsCleanup() }
        r.model.toastDuration = .milliseconds(60)
        r.model.trash(["a-call"])
        XCTAssertNotNil(r.model.toast)
        for _ in 0..<100 where r.model.toast != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(r.model.toast)
    }

    func testAnItemGoneFromTheTrashIsAnErrorNotACrash() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        let um = undoManager()
        let batch = try XCTUnwrap(r.model.trash(["b-call"], undoManager: um).batch)
        // Somebody emptied the Trash (this one is a scratch folder).
        try FileManager.default.removeItem(at: try XCTUnwrap(batch.items[0].trashed))

        um.undo()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b-call").path))
        XCTAssertEqual(r.model.sessions.map(\.name), ["a-call"])
        XCTAssertEqual(r.model.toast?.isError, true)
        XCTAssertEqual(r.model.toast?.message, "“B Call” is no longer in the Trash, so it could not be restored.")
        XCTAssertFalse(um.canRedo, "nothing came back, so there is nothing to redo")
    }

    func testAnItemThatTheSystemDidNotLocateIsAnErrorToo() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let bin = trashDir!
        let ops = SessionTrashOps(trash: { url in try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent)); return nil },
                                  restore: { _, _ in })
        let m = HomeSessionsModel(root: root, defaults: defaults, trashOps: ops, eventMap: nil)
        let batch = try XCTUnwrap(m.trash(["b-call"]).batch)
        XCTAssertEqual(m.restore(batch), [])
        XCTAssertEqual(m.toast?.isError, true)
    }

    func testAnUndoWhoseNameIsTakenAgainDoesNotOverwrite() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        let um = undoManager()
        r.model.trash(["b-call"], undoManager: um)
        try FolderFixtures.session("b-call", in: root, files: ["notes.txt": "a new one"])
        um.undo()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b-call/notes.txt"), encoding: .utf8), "a new one")
        XCTAssertEqual(r.model.toast?.isError, true)
    }

    // MARK: several at once

    func testSeveralSessionsGoAndComeBackTogether() throws {
        for n in ["a-call", "b-call", "c-call", "d-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        let acme = try r.model.folders.create(name: "Acme")
        try r.model.folders.move("b-call", to: acme.id)
        try r.model.folders.move("c-call", to: acme.id)
        r.model.marked = ["b-call", "c-call"]
        XCTAssertEqual(r.model.trashTargets(shown: "a-call").sorted(), ["b-call", "c-call"], "the ⌘-click set wins over the shown row")
        let um = undoManager()

        let outcome = r.model.trash(r.model.trashTargets(shown: "a-call"), undoManager: um)

        XCTAssertEqual(outcome.batch?.names.sorted(), ["b-call", "c-call"])
        XCTAssertEqual(r.trash.calls.count, 2)
        XCTAssertEqual(Set(r.model.sessions.map(\.name)), ["a-call", "d-call"])
        XCTAssertTrue(r.model.marked.isEmpty)
        XCTAssertEqual(r.model.folders.folders.map(\.name), ["Acme"])

        um.undo()

        XCTAssertEqual(Set(r.model.sessions.map(\.name)), ["a-call", "b-call", "c-call", "d-call"])
        XCTAssertEqual(r.model.folders.folder(of: "b-call")?.id, acme.id)
        XCTAssertEqual(r.model.folders.folder(of: "c-call")?.id, acme.id)
    }

    func testTargetsOfEachEntryPoint() throws {
        for n in ["a-call", "b-call", "c-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        // Keyboard, toolbar, Edit: the shown row.
        XCTAssertEqual(r.model.trashTargets(shown: "a-call"), ["a-call"])
        // A swipe or the context menu on another row acts on that row alone.
        XCTAssertEqual(r.model.trashTargets(shown: "a-call", clicked: "c-call"), ["c-call"])
        r.model.marked = ["a-call", "b-call"]
        XCTAssertEqual(r.model.trashTargets(shown: "a-call", clicked: "c-call"), ["c-call"], "outside the set: alone")
        XCTAssertEqual(r.model.trashTargets(shown: "a-call", clicked: "b-call").sorted(), ["a-call", "b-call"], "inside the set: the set")
        XCTAssertEqual(r.model.trashTargets(shown: nil).sorted(), ["a-call", "b-call"])
    }

    func testEveryEntryPointEndsInTheSameTrashCall() throws {
        // The page's one `performTrash` is `model.trash` over `model.deletable(...)`; swipe, context menu, ⌫, ⌘⌫, the toolbar button
        // and the More menu all pass their targets to it. The same targets give the same result whichever way they arrive.
        var results: [[String]] = []
        for _ in 0..<4 {
            try? FileManager.default.removeItem(at: root)
            root = try FolderFixtures.scratch()
            for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
            let r = rig()
            defer { r.defaultsCleanup() }
            let targets = results.count < 2 ? r.model.trashTargets(shown: "b-call") : r.model.trashTargets(shown: "a-call", clicked: "b-call")
            results.append(r.model.trash(r.model.deletable(targets)).batch?.names ?? [])
        }
        XCTAssertEqual(results, Array(repeating: ["b-call"], count: 4))
    }

    // MARK: selection

    func testSelectionMovesToTheNextRowThenThePreviousOne() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(SessionTrashRules.nextSelection(order: order, removed: ["b"], current: "b"), "c")
        XCTAssertEqual(SessionTrashRules.nextSelection(order: order, removed: ["d"], current: "d"), "c", "the last row: the one above")
        XCTAssertEqual(SessionTrashRules.nextSelection(order: order, removed: ["b", "c"], current: "b"), "d")
        XCTAssertEqual(SessionTrashRules.nextSelection(order: order, removed: ["c", "d"], current: "d"), "b")
        XCTAssertEqual(SessionTrashRules.nextSelection(order: order, removed: ["b"], current: "a"), "a", "another row stays selected")
        XCTAssertNil(SessionTrashRules.nextSelection(order: order, removed: Set(order), current: "a"))
    }

    func testTheShownRowMovesToTheNextRowInTheListsOrder() throws {
        let now = Date()
        try FolderFixtures.session("new-call", in: root, at: now)
        try FolderFixtures.session("mid-call", in: root, at: now.addingTimeInterval(-60))
        try FolderFixtures.session("old-call", in: root, at: now.addingTimeInterval(-120))
        let r = rig()
        defer { r.defaultsCleanup() }
        XCTAssertEqual(r.model.displayOrder, ["new-call", "mid-call", "old-call"])
        r.router.selectedSession = "mid-call"
        r.model.trash(["mid-call"])
        XCTAssertEqual(r.router.selectedSession, "old-call")
        r.model.trash(["old-call"])
        XCTAssertEqual(r.router.selectedSession, "new-call")
        r.router.selectedSession = "new-call"
        r.model.trash(["new-call"])
        XCTAssertNil(r.router.selectedSession, "no rows left")
    }

    func testTrashingAnotherRowKeepsTheSelection() throws {
        for n in ["a-call", "b-call"] { try FolderFixtures.session(n, in: root) }
        let r = rig()
        defer { r.defaultsCleanup() }
        r.router.selectedSession = "a-call"
        r.model.trash(["b-call"])
        XCTAssertEqual(r.router.selectedSession, "a-call")
    }

    // MARK: keyboard and swipe

    func testDeleteAndCommandDeleteTrashButNotInsideATextField() {
        XCTAssertTrue(SessionTrashRules.keyActs(on: .delete, modifiers: [], editingText: false), "⌫")
        XCTAssertTrue(SessionTrashRules.keyActs(on: .delete, modifiers: .command, editingText: false), "⌘⌫")
        XCTAssertTrue(SessionTrashRules.keyActs(on: .deleteForward, modifiers: [], editingText: false), "fn⌫")
        XCTAssertFalse(SessionTrashRules.keyActs(on: .delete, modifiers: [], editingText: true), "a text field keeps its ⌫")
        XCTAssertFalse(SessionTrashRules.keyActs(on: .delete, modifiers: .command, editingText: true), "and its ⌘⌫")
        XCTAssertFalse(SessionTrashRules.keyActs(on: .delete, modifiers: .option, editingText: false), "⌥⌫ is somebody else's")
        XCTAssertFalse(SessionTrashRules.keyActs(on: .delete, modifiers: .shift, editingText: false))
        XCTAssertFalse(SessionTrashRules.keyActs(on: .return, modifiers: [], editingText: false))
        XCTAssertFalse(SessionTrashRules.keyActs(on: "d", modifiers: .command, editingText: false))
    }

    func testASwipeRevealsPastAThresholdAndDeletesPastAFullSwipe() {
        let w: CGFloat = 236
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 10, rowWidth: w), .close)
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 35, rowWidth: w), .close)
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 36, rowWidth: w), .reveal)
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 100, rowWidth: w), .reveal)
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 130, rowWidth: w), .full)
        XCTAssertEqual(SessionTrashRules.resolveSwipe(offset: 236, rowWidth: w), .full)
    }

    // MARK: practice runs whose source is gone

    func testAPracticeRunKeepsLoadingWhenItsSourceSessionIsTrashed() throws {
        try FolderFixtures.session("harbor-kickoff", in: root)
        try FolderFixtures.session("sim-20261018-0900-harbor-kickoff", in: root,
                                   files: ["sim.json": #"{"source":"session","source_session":"harbor-kickoff","company":"Harbor Ledger"}"#,
                                           "report.html": "<html><body>report</body></html>"])
        let r = rig()
        defer { r.defaultsCleanup() }
        let harbor = try r.model.folders.create(name: "Harbor Ledger")
        try r.model.folders.move("harbor-kickoff", to: harbor.id)
        r.model.reload()
        XCTAssertEqual(r.model.folders.folder(of: "sim-20261018-0900-harbor-kickoff")?.id, harbor.id, "the run followed its source into the folder")

        r.model.trash(["harbor-kickoff"])
        r.model.reload()

        let run = try XCTUnwrap(r.model.session(named: "sim-20261018-0900-harbor-kickoff"))
        XCTAssertEqual(run.kind, .practice)
        XCTAssertEqual(run.folderSignals.sourceSession, "harbor-kickoff", "it still names a source that is gone")
        XCTAssertNotNil(run.reportURL)
        XCTAssertEqual(r.model.folders.folder(of: run.name)?.id, harbor.id, "its own folder entry stays")
        XCTAssertNil(FolderSuggester.autoAssignment(for: run.folderSignals, assigned: { r.model.folders.folder(of: $0)?.id }))
        _ = HomeSessionDetail.load(run)
        XCTAssertTrue(r.model.sections.flatMap(\.sessions).contains { $0.name == run.name })
    }

    func testAPracticeRunWithoutAFolderIsNotFiledFromATrashedSource() throws {
        try FolderFixtures.session("harbor-kickoff", in: root)
        try FolderFixtures.session("sim-20261018-0900-harbor-kickoff", in: root,
                                   files: ["sim.json": #"{"source":"session","source_session":"harbor-kickoff","company":"Harbor Ledger"}"#,
                                           "report.html": "<html></html>"])
        let r = rig()
        defer { r.defaultsCleanup() }
        r.model.trash(["harbor-kickoff"])
        r.model.reload()
        XCTAssertNil(r.model.folders.folder(of: "sim-20261018-0900-harbor-kickoff"))
        XCTAssertEqual(r.model.sessions.map(\.name), ["sim-20261018-0900-harbor-kickoff"])
    }
}
