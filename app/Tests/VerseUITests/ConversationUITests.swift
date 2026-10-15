import Foundation
import VersePosting
@testable import VerseUI
import XCTest

private var brainDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
}

private func scratchRoot() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-conv-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeSession(_ root: URL, name: String, cost: Double = 0.31, warnings: [String] = []) throws -> URL {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("## FACTS\n".utf8).write(to: dir.appendingPathComponent("pack.md"))
    let meta: [String: Any] = [
        "warnings": warnings, "stats": ["bank_entries": 12],
        "conversation": ["company": "Acme Ltd", "people": ["Ann Lee"], "searches": 6, "facts_sourced": 14, "facts_unverified": 3,
                         "cost_usd": ["total": cost]],
    ]
    try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
    return dir
}

/// A runner that records what it was given and returns a canned outcome.
final class FakeRunner: ConversationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var setups: [ConversationSetup] = []
    let outcome: ConversationOutcome
    let lines: [String]
    init(_ outcome: ConversationOutcome, lines: [String] = []) {
        self.outcome = outcome
        self.lines = lines
    }
    func run(_ setup: ConversationSetup, brainDir: URL, root: URL, onLine: @escaping @Sendable (String) -> Void) async -> ConversationOutcome {
        lock.withLock { setups.append(setup) }
        for l in lines { onLine(l) }
        return outcome
    }
    func cancel() {}
}

final class ConversationSetupTests: XCTestCase {
    func testArgumentsCarryPathsOnly() {
        var s = ConversationSetup(thread: "Ann: hello, my rate is 420 EUR")
        s.postingURL = URL(string: "https://jobs.example/1")
        s.companyURL = "acme.example"
        s.owner = "Alex"
        s.fake = true
        let a = s.prepArguments(threadFile: URL(fileURLWithPath: "/tmp/t/thread.txt"), postingFile: URL(fileURLWithPath: "/tmp/t/posting.txt"),
                                noteFile: URL(fileURLWithPath: "/tmp/t/note.md"), out: URL(fileURLWithPath: "/tmp/sessions"))
        XCTAssertEqual(Array(a.prefix(5)), ["-u", "-m", "verse_brain.prep", "conversation", "--thread"])
        XCTAssertEqual(a[a.firstIndex(of: "--thread")! + 1], "/tmp/t/thread.txt")
        XCTAssertEqual(a[a.firstIndex(of: "--posting-file")! + 1], "/tmp/t/posting.txt")
        XCTAssertEqual(a[a.firstIndex(of: "--note")! + 1], "/tmp/t/note.md")
        XCTAssertEqual(a[a.firstIndex(of: "--company-url")! + 1], "https://acme.example")
        XCTAssertEqual(a[a.firstIndex(of: "--posting-url")! + 1], "https://jobs.example/1")
        XCTAssertEqual(a[a.firstIndex(of: "--me")! + 1], "Alex")
        XCTAssertTrue(a.contains("--fake"))
        XCTAssertFalse(a.contains { $0.contains("420 EUR") || $0.contains("sk-ant") || $0.lowercased().contains("key") },
                       "no thread text and no key on the command line")
        let bare = ConversationSetup(thread: "x").prepArguments(threadFile: URL(fileURLWithPath: "/t"), postingFile: nil, noteFile: nil,
                                                                out: URL(fileURLWithPath: "/o"))
        XCTAssertFalse(bare.contains("--posting-file") || bare.contains("--note") || bare.contains("--company-url") || bare.contains("--fake"))
    }

    func testValidatedAcceptsOnlyConvFoldersWithAPack() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ok = try makeSession(root, name: "conv-20261015-1405-acme")
        XCTAssertEqual(ConversationSessionFolder.validated(ok.path + "\n", root: root)?.lastPathComponent, "conv-20261015-1405-acme")
        let sim = try makeSession(root, name: "sim-20261015-1405-acme")
        XCTAssertNil(ConversationSessionFolder.validated(sim.path, root: root), "not a conv- folder")
        let empty = root.appendingPathComponent("conv-20261015-1406-none")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(ConversationSessionFolder.validated(empty.path, root: root), "no pack.md")
        XCTAssertNil(ConversationSessionFolder.validated("/etc", root: root))
        XCTAssertNil(ConversationSessionFolder.validated("", root: root))
    }

    func testSummaryReadsTheConversationBlock() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession(root, name: "conv-20261015-1405-acme", cost: 0.42, warnings: ["3 research fact(s) are unverified"])
        let s = try XCTUnwrap(ConversationSummary.load(sessionDir: dir))
        XCTAssertEqual(s, ConversationSummary(company: "Acme Ltd", people: ["Ann Lee"], searches: 6, sourced: 14, unverified: 3,
                                              bankEntries: 12, costUSD: 0.42, warnings: ["3 research fact(s) are unverified"]))
        XCTAssertNil(ConversationSummary.load(sessionDir: root), "a session without a conversation block")
    }
}

@MainActor
final class ConversationControllerTests: XCTestCase {
    private func controller(root: URL, runner: FakeRunner, fake: Bool = false, brain: URL? = URL(fileURLWithPath: "/brain"),
                            fetcher: (@Sendable (URL) async throws -> Posting)? = nil,
                            selected: SelectLog, spend: SpendLog) -> ConversationController {
        ConversationController(
            owner: { "Alex" }, fake: { fake }, brainDir: { brain }, root: root, makeRunner: { runner },
            fetcher: fetcher ?? { _ in throw PostingError.network },
            selectSession: { selected.names.append($0); return true },
            recordSpend: { spend.records.append(($0.lastPathComponent, $2)) })
    }

    private func waitDone(_ c: ConversationController) async {
        for _ in 0..<200 where c.phase == .preparing { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testPrepareRunsTheRunnerAndSelectsTheSession() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession(root, name: "conv-20261015-1405-acme", warnings: ["2 research fact(s) are unverified"])
        let runner = FakeRunner(.done(dir), lines: ["extract: Acme", "warning: 2 research fact(s) are unverified", "cost: $0.31"])
        let selected = SelectLog(), spend = SpendLog()
        let c = controller(root: root, runner: runner, selected: selected, spend: spend)
        XCTAssertFalse(c.canPrepare, "an empty paste box cannot be prepared")
        c.thread = "Ann: please tell me about your RAG work"
        c.postingPaste = "Role: Applied AI Engineer"
        c.companyURL = " acme.example "
        c.note = "keep it short"
        c.prepare()
        XCTAssertEqual(c.phase, .preparing)
        XCTAssertFalse(c.canPrepare, "a second Prepare while running is ignored")
        await waitDone(c)
        XCTAssertEqual(c.phase, .done)
        XCTAssertEqual(c.sessionDir, dir)
        XCTAssertEqual(selected.names, ["conv-20261015-1405-acme"], "the new session becomes the current one")
        XCTAssertEqual(c.summary?.sourced, 14)
        XCTAssertEqual(c.warnings, ["2 research fact(s) are unverified"])
        XCTAssertEqual(spend.records.count, 1)
        XCTAssertEqual(spend.records.first?.0, "conv-20261015-1405-acme")
        XCTAssertEqual(try XCTUnwrap(spend.records.first).1, 0.31, accuracy: 1e-9)
        let s = try XCTUnwrap(runner.setups.first)
        XCTAssertEqual(s.thread, "Ann: please tell me about your RAG work")
        XCTAssertEqual(s.postingText, "Role: Applied AI Engineer")
        XCTAssertEqual(s.companyURL, "acme.example")
        XCTAssertEqual(s.note, "keep it short")
        XCTAssertEqual(s.owner, "Alex")
        XCTAssertFalse(s.fake)
        c.another()
        XCTAssertEqual(c.phase, .setup)
        XCTAssertEqual(c.thread, "")
    }

    func testFakeBrainRunDoesNotCountSpend() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession(root, name: "conv-20261015-1405-acme")
        let selected = SelectLog(), spend = SpendLog()
        let runner = FakeRunner(.done(dir))
        let c = controller(root: root, runner: runner, fake: true, selected: selected, spend: spend)
        c.thread = "Ann: hi there, can we talk"
        c.prepare()
        await waitDone(c)
        XCTAssertEqual(c.phase, .done)
        XCTAssertTrue(spend.records.isEmpty)
        XCTAssertTrue(try XCTUnwrap(runner.setups.first).fake)
    }

    func testFailureShowsTheErrorAndSelectsNothing() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = SelectLog(), spend = SpendLog()
        let c = controller(root: root, runner: FakeRunner(.failed("error: web search is not enabled for this organization")),
                           selected: selected, spend: spend)
        c.thread = "Ann: hello there, my friend"
        c.prepare()
        await waitDone(c)
        XCTAssertEqual(c.phase, .setup)
        XCTAssertEqual(c.error, "error: web search is not enabled for this organization")
        XCTAssertTrue(selected.names.isEmpty && spend.records.isEmpty)
        XCTAssertNil(c.sessionDir)
    }

    func testMissingBrainFolderIsReported() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = controller(root: root, runner: FakeRunner(.cancelled), brain: nil, selected: SelectLog(), spend: SpendLog())
        c.thread = "Ann: hello there, my friend"
        c.prepare()
        XCTAssertEqual(c.phase, .setup)
        XCTAssertNotNil(c.error)
    }

    func testFetchedPostingGoesToPrepInsteadOfThePasteBox() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeSession(root, name: "conv-20261015-1405-acme")
        let runner = FakeRunner(.done(dir))
        let posting = Posting(url: URL(string: "https://jobs.example/1"), title: "Applied AI Engineer", company: "Acme",
                              text: "Build an assistant.", source: .page)
        let c = controller(root: root, runner: runner, fetcher: { _ in posting }, selected: SelectLog(), spend: SpendLog())
        c.postingLink = "jobs.example/1"
        c.postingPaste = "stale pasted text"
        c.fetchPosting()
        for _ in 0..<200 where c.fetching || c.posting == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.posting?.title, "Applied AI Engineer")
        XCTAssertEqual(c.postingPaste, "", "the fetched posting replaces the paste box")
        c.thread = "Ann: hello there, my friend"
        c.prepare()
        await waitDone(c)
        let s = try XCTUnwrap(runner.setups.first)
        XCTAssertEqual(s.postingText, "Build an assistant.")
        XCTAssertEqual(s.postingURL?.absoluteString, "https://jobs.example/1")
    }

    func testBadLinkAndNetworkFailureMessages() async {
        let c = ConversationController(owner: { "Alex" }, fake: { false }, brainDir: { nil }, root: URL(fileURLWithPath: "/tmp"),
                                       fetcher: { _ in throw PostingError.network }, selectSession: { _ in true })
        c.postingLink = "not a link"
        c.fetchPosting()
        XCTAssertEqual(c.fetchMessage, "That is not a link. Paste the posting text below instead.")
        c.postingLink = "https://jobs.example/1"
        c.fetchPosting()
        for _ in 0..<200 where c.fetching || c.fetchMessage == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(c.fetchMessage, "Could not reach the page. Check the link, or paste the posting text below.")
    }
}

@MainActor final class SelectLog { var names: [String] = [] }
@MainActor final class SpendLog { var records: [(String, Double)] = [] }

/// The real runner, against a stub "python" so the temp files can be inspected while prep runs, and against the real
/// brain with `--fake`.
final class ConversationPrepProcessTests: XCTestCase {
    /// The stub records the mode of the thread file and of its folder, copies the text, and exits 1 with an error line.
    func testThreadReachesPrepThroughAPrivateTempFileThatIsRemoved() async throws {
        let brain = try scratchRoot()
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: brain); try? FileManager.default.removeItem(at: root) }
        let bin = brain.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = brain.appendingPathComponent("record.txt")
        let script = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--thread" ]; then f="$2"; fi
          shift
        done
        echo "file_mode=$(stat -f %Lp "$f")" > "\(record.path)"
        echo "dir_mode=$(stat -f %Lp "$(dirname "$f")")" >> "\(record.path)"
        echo "text=$(cat "$f")" >> "\(record.path)"
        echo "dir=$(dirname "$f")" >> "\(record.path)"
        echo "error: stub stops here" >&2
        exit 1
        """
        let py = bin.appendingPathComponent("python")
        try Data(script.utf8).write(to: py)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        var s = ConversationSetup(thread: "Ann: a private thread")
        s.postingText = "posting body"
        let lines = LineSink()
        let outcome = await ConversationPrep().run(s, brainDir: brain, root: root, onLine: { lines.add($0) })
        XCTAssertEqual(outcome, .failed("error: stub stops here"))
        let rec = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(rec.contains("file_mode=600"), rec)
        XCTAssertTrue(rec.contains("dir_mode=700"), rec)
        XCTAssertTrue(rec.contains("text=Ann: a private thread"), rec)
        let dir = try XCTUnwrap(rec.split(separator: "\n").first { $0.hasPrefix("dir=") }).dropFirst(4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(dir)), "the private temp folder is removed afterwards")
    }

    /// `--fake` prep through the app's runner: a conv- session folder appears and the temp copy is gone.
    func testFakePrepCreatesAConversationSession() async throws {
        let python = brainDirectory.appendingPathComponent(".venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "brain/.venv missing")
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = try String(contentsOf: brainDirectory.appendingPathComponent("tests/fixtures/conversation/thread_fictional.md"), encoding: .utf8)
        var s = ConversationSetup(thread: thread)
        s.fake = true
        s.note = "Ask about the API docs."
        let lines = LineSink()
        let outcome = await ConversationPrep().run(s, brainDir: brainDirectory, root: root, onLine: { lines.add($0) })
        guard case .done(let dir) = outcome else { return XCTFail("prep: \(outcome) \(lines.all)") }
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("conv-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("research.md").path))
        let sum = try XCTUnwrap(ConversationSummary.load(sessionDir: dir))
        XCTAssertEqual(sum.sourced, 2)
        XCTAssertEqual(sum.unverified, 2)
        XCTAssertTrue(SessionCatalog.list(root: root).contains(dir.lastPathComponent), "the session list sees it")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("verse-conversation-") }
        XCTAssertEqual(leftovers, [])
    }
}
