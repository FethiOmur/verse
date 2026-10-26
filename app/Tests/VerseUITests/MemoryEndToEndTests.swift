import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The whole memory path with the real brain process (`python -m verse_brain.runtime --fake`): the app's own factories start the index
/// writer and the memory Ask process; a temp copy of the fictional fixture sessions is indexed, a question is answered with sources that
/// resolve to a fixture session, Move to Trash plus a sync takes that session out of the answers, and Undo plus a sync brings it back
/// with the same key. Skipped when the brain's Python is missing (`VERSE_PY`, or `brain/.venv/bin/python` of this tree).
///
/// `--fake` answers every question with canned text that cites nothing in memory mode, so a one-file `sitecustomize.py` on the child's
/// `PYTHONPATH` swaps in a responder that cites the first transcript line of every excerpt block. Everything else is the shipped code: the
/// index, the search, the citation validation and the wire.
@MainActor
final class MemoryEndToEndTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!
    private var restore: [(String, String?)] = []
    private var tempBrain: URL?

    override func tearDown() async throws {
        for (k, v) in restore { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        restore = []
        scratch?.remove()
        if let tempBrain { try? FileManager.default.removeItem(at: tempBrain) }
    }

    private func setEnv(_ key: String, _ value: String) {
        restore.append((key, ProcessInfo.processInfo.environment[key]))
        setenv(key, value, 1)
    }

    /// `VERSE_PY`, else this tree's `brain/.venv/bin/python`.
    private func python() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["VERSE_PY"], fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let own = repo.appendingPathComponent("brain/.venv/bin/python")
        return fm.isExecutableFile(atPath: own.path) ? own : nil
    }

    private static let shim = """
    import os, re, sys
    _b = os.environ.get("VERSE_E2E_BRAIN")
    if _b and _b not in sys.path:
        sys.path.insert(0, _b)
    from verse_brain.runtime import ask as _ask

    def _text(msg):
        c = msg.get("content")
        if isinstance(c, str):
            return c
        return "\\n".join(p.get("text", "") for p in c if isinstance(p, dict))

    def _responder(request, n):
        tail = _text(request["messages"][-1])
        cites, key = [], None
        for ln in tail.splitlines():
            m = re.match(r"^== (s[0-9a-z]{6,8}) ", ln)
            if m:
                key = m.group(1)
                continue
            s = re.match(r"^\\[(\\d{1,2}:\\d{2}(?::\\d{2})?)\\] ", ln)
            if s and key:
                cites.append("[%s %s]" % (key, s.group(1)))
                key = None
        text = "Fake memory answer %d: " % n + ("it came up in " + ", ".join(cites) + "." if cites else "nothing found.")
        return _ask.words_script(text, model=request.get("model"))

    _ask.default_ask_responder = _responder
    """

    func testIndexAskTrashUndoWithTheRealBrain() async throws {
        guard let python = python() else { throw XCTSkip("no brain Python: set VERSE_PY or create brain/.venv") }
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brainSource = repo.appendingPathComponent("brain")
        try XCTSkipUnless(fm.fileExists(atPath: brainSource.appendingPathComponent("verse_brain").path), "no brain sources")

        // A brain folder the app's factories accept: the sources of this tree and the venv of the given Python.
        let temp = fm.temporaryDirectory.appendingPathComponent("verse-e2e-\(UUID().uuidString)", isDirectory: true)
        tempBrain = temp
        let brain = temp.appendingPathComponent("brain", isDirectory: true)
        let shimDir = temp.appendingPathComponent("shim", isDirectory: true)
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        try fm.createDirectory(at: shimDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: brain.appendingPathComponent("verse_brain"), withDestinationURL: brainSource.appendingPathComponent("verse_brain"))
        let venv = python.deletingLastPathComponent().deletingLastPathComponent()
        try fm.createSymbolicLink(at: brain.appendingPathComponent(".venv"), withDestinationURL: venv)
        try Self.shim.write(to: shimDir.appendingPathComponent("sitecustomize.py"), atomically: true, encoding: .utf8)
        setEnv("VERSE_BRAIN_DIR", brain.path)
        setEnv("VERSE_E2E_BRAIN", brain.path)
        setEnv("PYTHONPATH", shimDir.path)
        XCTAssertEqual(VerseController.brainDir()?.path, brain.path)

        scratch = try MemoryFixtures.scratch()
        let memory = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                                   makeBrain: { try MemoryService.makeBrainProcess(fake: true) },
                                   makeIndexBrain: { try MemoryService.makeBrainProcess(fake: true, indexOnly: true) })
        memory.indexStall = .seconds(90)

        // 1. Index the fixture tree.
        let synced = await memory.syncNow(timeout: .seconds(120))
        XCTAssertTrue(synced, "the real index writer finished: \(memory.phase)")
        XCTAssertEqual(memory.indexedSessions, 3)
        XCTAssertTrue(fm.fileExists(atPath: scratch.paths.db.path))

        // 2. A question in the all-meetings scope: sources that resolve to a fixture session.
        let ask = AskSession(makeBrain: { try AskSession.makeBrainProcess(fake: true) })
        let controller = AskScopeController(ask: ask, memory: memory, people: nil)
        controller.ownerName = { "Dana" }
        let question = "What did Marta say about the pilot plan?"

        func answer(_ q: String) async throws -> ChatAnswer {
            ask.send(q)
            let id = try XCTUnwrap(ask.turns.last?.id)
            let done = await eventually(90) { ask.turns.first(where: { $0.id == id })?.phase == .answered || ask.turns.first(where: { $0.id == id })?.phase == .failed }
            XCTAssertTrue(done, "no answer: \(String(describing: ask.turns.last))")
            XCTAssertEqual(ask.turns.first(where: { $0.id == id })?.phase, .answered, "failure: \(String(describing: ask.turns.last?.failure))")
            return try XCTUnwrap(ask.turns.first(where: { $0.id == id })?.answer)
        }
        func reopen() async {
            controller.close()
            XCTAssertTrue(controller.openMemory(.all))
            let up = await eventually(90) { ask.isRunning }
            XCTAssertTrue(up, "the memory Ask process started")
        }

        XCTAssertTrue(controller.openMemory(.all))
        let running = await eventually(90) { ask.isRunning }
        XCTAssertTrue(running, "the memory Ask process started")
        let first = try await answer(question)
        let fixtureNames: Set<String> = ["halden-kickoff", "corvo-design-call", "halden-weekly-prep"]
        XCTAssertFalse(first.sources.isEmpty, "the answer cites sources: \(first.text)")
        XCTAssertTrue(first.sources.allSatisfy { fixtureNames.contains($0.session) }, "every source resolves to a fixture session")
        let kickoff = try XCTUnwrap(first.sources.first { $0.session == "halden-kickoff" }, "the kickoff is among them: \(first.sources.map(\.session))")
        XCTAssertEqual(kickoff.kind, "turn")
        XCTAssertFalse((kickoff.text ?? "").isEmpty)
        XCTAssertEqual(AskAnswerParser.memoryBlocks(first.text, sources: first.sources).cited.count, first.sources.count, "the marks resolve")
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.memory).map(\.kind), ["ask"], "the cost went to memory/spend.json")

        // 3. Move to Trash plus a sync: the same question returns nothing from that session.
        let trash = scratch.top.appendingPathComponent("trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: scratch.sessions.appendingPathComponent("halden-kickoff"), to: trash.appendingPathComponent("halden-kickoff"))
        let afterTrash = await memory.syncNow(timeout: .seconds(120))
        XCTAssertTrue(afterTrash, "sync after the trash: \(memory.phase)")
        XCTAssertEqual(memory.indexedSessions, 2)
        await reopen()
        let second = try await answer(question)
        XCTAssertFalse(second.sources.contains { $0.session == "halden-kickoff" }, "nothing from the trashed session: \(second.sources.map(\.session))")
        XCTAssertFalse(second.text.contains(kickoff.key), "and no mark of its key")

        // 4. Undo plus a sync: it answers again, with the same key.
        try fm.moveItem(at: trash.appendingPathComponent("halden-kickoff"), to: scratch.sessions.appendingPathComponent("halden-kickoff"))
        let afterUndo = await memory.syncNow(timeout: .seconds(120))
        XCTAssertTrue(afterUndo, "sync after the undo: \(memory.phase)")
        XCTAssertEqual(memory.indexedSessions, 3)
        await reopen()
        let third = try await answer(question)
        let back = try XCTUnwrap(third.sources.first { $0.session == "halden-kickoff" }, "the kickoff is back: \(third.sources.map(\.session))")
        XCTAssertEqual(back.key, kickoff.key, "the key depends only on the folder name")
        controller.close()
    }
}
