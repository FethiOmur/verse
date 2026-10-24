import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The Me page's model. Fixtures are the fictional "Dana Reyes" of the brain's tests; the owner profile is pinned to the generic one (OwnerPin.swift: notes heading MY NOTES, source tag `owner`).
@MainActor
final class MeModelTests: XCTestCase {
    static let meMD = """
    ## WHO I AM
    [m001] Backend and machine-learning engineer in Lisbon with six years in production systems. | file:dana_profile.md#L3
    [m002] Likes small services that do one job well. | file:dana_profile.md#L20

    ## EXPERIENCE
    [m101] 2019-2022 | Backend engineer | Northwind Freight | Built the payment and invoicing services of a freight marketplace. | file:dana_profile.md#L7
    [m102] 2022-now | Machine-learning engineer | Larkspur Health | Owns the claims-triage model and its serving stack. | file:dana_profile.md#L8

    ## PROJECTS
    [m201] Harbor Ledger | Payments reconciliation service | designed and led it | Python, PostgreSQL, Kafka | about 41,000 payments a month | file:dana_profile.md#L13

    ## SKILLS
    [m301] Python | Harbor Ledger, Trailhead and the claims-triage model | file:dana_profile.md#L13

    ## NUMBERS
    [m401] number | Harbor Ledger processed about 41,000 payments a month. | 41000 | file:dana_profile.md#L13
    [m402] number | Harbor Ledger cut the month-end close from 6 days to 2 days. | 2 | file:dana_profile.md#L13

    ## STORIES
    [m501] Double-posted payments | In March 2021 a nightly job posted 300 payments twice. Dana found the missing idempotency key within an hour. | file:dana_profile.md#L24

    ## LOOKING FOR
    [m601] Senior machine-learning engineer role in Lisbon or remote in Europe, available from January 2027. | file:dana_profile.md#L28

    ## MY NOTES
    [m701] Prefers to answer in short sentences. | owner

    """

    private func profile(md: String? = MeModelTests.meMD, sources: Bool = true, built: String = "2026-10-16T09:00:00+00:00",
                         extraMeta: [String: Any] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-me-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if let md { try md.write(to: dir.appendingPathComponent("me.md"), atomically: true, encoding: .utf8) }
        var meta: [String: Any] = ["model": "claude-sonnet-5-5", "built_at": built, "tokens": 3140, "spend_usd_total": 0.07,
                                   "lines": ["m001": ["sha": "x", "key": "y"], "m402": ["sha": "x", "key": "y"]],
                                   "deleted": [["id": "m403", "key": "k"]], "notes_issued": ["m701", "m702"],
                                   "quotes": ["m401": ["kind": "file", "ref": "file:dana_profile.md#L13", "quote": "It processed about 41,000 payments a month"]]]
        for (k, v) in extraMeta { meta[k] = v }
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("me.meta.json"))
        if sources {
            let src: [[String: Any]] = [
                ["id": "s1", "kind": "file", "path": "/fixtures/dana_profile.md", "label": "dana_profile.md", "enabled": true],
                ["id": "s2", "kind": "vault", "path": "/fixtures/vault/Harbor Ledger.md", "label": "300-Projects/Harbor Ledger/Harbor Ledger.md", "enabled": true],
                ["id": "s3", "kind": "sessions", "path": "/fixtures/sessions", "label": "facts of earlier meeting preps", "enabled": false],
            ]
            try JSONSerialization.data(withJSONObject: src, options: .prettyPrinted).write(to: dir.appendingPathComponent("me.sources.json"))
        }
        return dir
    }

    private func model(_ dir: URL, runner: (any MeRunning)? = nil, now: Date = ISO8601DateFormatter().date(from: "2026-10-17T09:00:00Z")!) -> MeModel {
        MeModel(directory: dir, runner: { runner ?? FakeMeRunner() }, brainDir: { URL(fileURLWithPath: "/brain") }, fake: { false }, now: { now })
    }

    // MARK: parse

    func testParsesTheSectionsLinesAndIds() throws {
        let m = model(try profile())
        XCTAssertTrue(m.hasProfile)
        XCTAssertEqual(MeSection.allCases.map(\.rawValue),
                       ["WHO I AM", "EXPERIENCE", "PROJECTS", "SKILLS", "NUMBERS", "STORIES", "LOOKING FOR", "MY NOTES"])
        XCTAssertEqual(m.lines(.who).map(\.id), ["m001", "m002"])
        XCTAssertEqual(m.lines(.numbers).map(\.id), ["m401", "m402"])
        let exp = try XCTUnwrap(m.line(id: "m102"))
        XCTAssertEqual(exp.fields, ["2022-now", "Machine-learning engineer", "Larkspur Health", "Owns the claims-triage model and its serving stack."])
        XCTAssertEqual(exp.source, "file:dana_profile.md#L8")
        XCTAssertEqual(exp.text, "2022-now · Machine-learning engineer · Larkspur Health · Owns the claims-triage model and its serving stack.")
        XCTAssertEqual(exp.editable, "2022-now | Machine-learning engineer | Larkspur Health | Owns the claims-triage model and its serving stack.")
        XCTAssertEqual(m.line(id: "m701")?.source, "owner")
        XCTAssertEqual(m.lines(.projects).first?.fields.count, 5)
    }

    func testRenderingAnUntouchedFileGivesTheFileBack() throws {
        let m = model(try profile())
        XCTAssertEqual(MeFile.render(m.sections), Self.meMD, "prep tells an edited line by its hash, so untouched lines are written as they were")
    }

    func testALineTypedByHandWithoutAnIdSurvives() throws {
        let md = Self.meMD.replacingOccurrences(of: "## SKILLS\n", with: "## SKILLS\nSwift | typed by hand\n")
        let m = model(try profile(md: md))
        XCTAssertEqual(m.lines(.skills).count, 2)
        XCTAssertEqual(m.lines(.skills).last?.hasID, false)
        XCTAssertTrue(MeFile.render(m.sections).contains("Swift | typed by hand"))
    }

    func testNoProfileYet() throws {
        let m = model(try profile(md: nil, sources: false))
        XCTAssertFalse(m.hasProfile)
        XCTAssertTrue(m.lines(.who).isEmpty)
        XCTAssertFalse(m.hasSourcesFile)
    }

    // MARK: meta

    func testTheBuiltLine() throws {
        let m = model(try profile())
        XCTAssertEqual(m.meta?.summary, "Built 16 Oct · 3,140 tokens · $0.07")
    }

    // MARK: edit

    func testAnInlineEditKeepsTheIdAndTheSourceAndTouchesNothingElse() throws {
        let dir = try profile()
        let m = model(dir)
        let result = m.edit(id: "m102", to: "2022-now | Machine-learning engineer | Larkspur Health | Owns the claims-triage model, its serving stack and the on-call rota.")
        XCTAssertNil(result.failure)
        let text = try String(contentsOf: dir.appendingPathComponent("me.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("[m102] 2022-now | Machine-learning engineer | Larkspur Health | Owns the claims-triage model, its serving stack and the on-call rota. | file:dana_profile.md#L8"))
        XCTAssertEqual(text.replacingOccurrences(of: "Owns the claims-triage model, its serving stack and the on-call rota.", with: "Owns the claims-triage model and its serving stack."),
                       Self.meMD, "every other byte is the same")
        XCTAssertEqual(m.line(id: "m102")?.fields[3], "Owns the claims-triage model, its serving stack and the on-call rota.")
        XCTAssertEqual(m.line(id: "m102")?.source, "file:dana_profile.md#L8")
    }

    func testAnEditOfALineWithOnePartCannotCarryTheSeparator() throws {
        let m = model(try profile())
        XCTAssertNil(m.edit(id: "m001", to: "Backend | and ML engineer").failure)
        XCTAssertEqual(m.line(id: "m001")?.fields, ["Backend | and ML engineer".replacingOccurrences(of: " | ", with: " / ")])
    }

    func testAnEditWithTheWrongNumberOfPartsIsRefusedAndNothingIsWritten() throws {
        let dir = try profile()
        let m = model(dir)
        XCTAssertEqual(m.edit(id: "m201", to: "Harbor Ledger | only two | parts").failure, .parts(expected: 5))
        XCTAssertEqual(m.edit(id: "m001", to: "   ").failure, .empty)
        XCTAssertEqual(m.edit(id: "m999", to: "x").failure, .unknownLine)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("me.md"), encoding: .utf8), Self.meMD)
    }

    func testEditingANumberRewritesTheFactsFileKeepingTheQuote() throws {
        let dir = try profile()
        let m = model(dir)
        XCTAssertNil(m.edit(id: "m401", to: "number | Harbor Ledger processed about 43,000 payments a month. | 43000").failure)
        let facts = try String(contentsOf: dir.appendingPathComponent("me.facts.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(facts.count, 2)
        let first = try XCTUnwrap(JSONValue.decodeObject(String(facts[0])))
        XCTAssertEqual(first[string: "id"], "m401")
        XCTAssertEqual(first[string: "kind"], "number")
        XCTAssertEqual(first[string: "value"], "43000")
        let src = try XCTUnwrap(first["sources"]?.array?.first)
        guard case .object(let q) = src else { return XCTFail("a source object") }
        XCTAssertEqual(q[string: "ref"], "file:dana_profile.md#L13", "the line keeps the quote it was generated with")
        let second = try XCTUnwrap(JSONValue.decodeObject(String(facts[1])))
        XCTAssertEqual(second[string: "id"], "m402")
        XCTAssertEqual(second["sources"]?.array?.count, 1)
        // And the session reads it as chips: the facts file is the schema FactIndex loads.
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("verse-me-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: session) }
        let index = try FactIndex.load(sessionDir: session, meFacts: dir.appendingPathComponent("me.facts.jsonl"))
        XCTAssertEqual(index.chips(in: "it handled 43,000 payments").map(\.id), ["m401"])
    }

    // MARK: delete

    func testADeletedLineIsGoneAndTheRestStays() throws {
        let dir = try profile()
        let m = model(dir)
        XCTAssertNil(m.delete(id: "m402").failure)
        let text = try String(contentsOf: dir.appendingPathComponent("me.md"), encoding: .utf8)
        XCTAssertFalse(text.contains("[m402]"))
        XCTAssertEqual(text.replacingOccurrences(of: "[m401]", with: "[m401]").components(separatedBy: "\n").filter { $0.hasPrefix("[m") }.count, 10)
        XCTAssertNil(m.line(id: "m402"))
        let facts = try String(contentsOf: dir.appendingPathComponent("me.facts.jsonl"), encoding: .utf8)
        XCTAssertFalse(facts.contains("m402"))
        XCTAssertTrue(facts.contains("m401"))
    }

    // MARK: notes

    func testANewNoteTakesTheNextNoteIdNeverOneAlreadyIssuedOrDeleted() throws {
        let dir = try profile(extraMeta: ["deleted": [["id": "m703", "key": "k"]]])
        let m = model(dir)
        // m701 is in the file, m702 was issued before, m703 was deleted: the next is m704.
        XCTAssertEqual(try m.addNote("Prefers   mornings   for interviews").get(), "m704")
        let line = try XCTUnwrap(m.line(id: "m704"))
        XCTAssertEqual(line.section, .notes)
        XCTAssertEqual(line.fields, ["Prefers mornings for interviews"])
        XCTAssertEqual(line.raw, "[m704] Prefers mornings for interviews | owner")
        XCTAssertEqual(m.lines(.notes).map(\.id), ["m701", "m704"])
        XCTAssertEqual(m.addNote("").failure, .empty)
    }

    func testNotesNeedAProfileFirst() throws {
        let m = model(try profile(md: nil, sources: false))
        XCTAssertEqual(m.addNote("hello").failure, .noProfile)
    }

    // MARK: sources

    func testSourcesToggleAddAndRemove() throws {
        let dir = try profile()
        let m = model(dir)
        XCTAssertEqual(m.sources.map(\.label), ["dana_profile.md", "300-Projects/Harbor Ledger/Harbor Ledger.md", "facts of earlier meeting preps"])
        XCTAssertEqual(m.sources.map(\.enabled), [true, true, false])
        XCTAssertNil(m.setSource("s3", enabled: true).failure)
        XCTAssertEqual(m.sources.map(\.enabled), [true, true, true])

        let file = dir.appendingPathComponent("cv.pdf")
        try Data("pdf".utf8).write(to: file)
        XCTAssertNil(m.addSource(file: file).failure)
        XCTAssertEqual(m.sources.last?.label, "cv.pdf")
        XCTAssertEqual(m.sources.last?.id, "s4")
        XCTAssertEqual(m.sources.last?.kind, "file")
        XCTAssertNil(m.addSource(file: file).failure, "the same file twice is one source")
        XCTAssertEqual(m.sources.count, 4)
        XCTAssertNil(m.removeSource("s4").failure)
        XCTAssertEqual(m.sources.count, 3)
        XCTAssertEqual(m.addSource(file: dir.appendingPathComponent("missing.md")).failure, .notFound(dir.appendingPathComponent("missing.md").path))
    }

    func testUnknownKeysOfTheSourcesFileSurviveAToggle() throws {
        let dir = try profile()
        let url = dir.appendingPathComponent("me.sources.json")
        var arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        arr[0]["note"] = "mine"
        try JSONSerialization.data(withJSONObject: arr).write(to: url)
        let m = model(dir)
        XCTAssertNil(m.setSource("s1", enabled: false).failure)
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(again[0]["note"] as? String, "mine")
        XCTAssertEqual(again[0]["enabled"] as? Bool, false)
    }

    func testSourcesCannotChangeBeforeTheFirstBuild() throws {
        let m = model(try profile(md: nil, sources: false))
        XCTAssertEqual(m.setSource("s1", enabled: false).failure, .noSourcesFile)
        XCTAssertEqual(m.addSource(file: URL(fileURLWithPath: "/etc/hosts")).failure, .noSourcesFile)
    }

    // MARK: show output and the 7-day rule

    func testShowOutputGivesTheChangedSources() {
        let report = """
        profile: /x
        built: 2026-10-09T09:00:00+00:00 | model claude-sonnet-5-5 | tokens 3140 / cap 3500 | spend $0.0700 total
        sections: WHO I AM 2 | EXPERIENCE 2
        sources:
          S1 file     dana_profile.md (changed)
          S2 vault    300-Projects/Harbor Ledger/Harbor Ledger.md
        stale sources: dana_profile.md, (removed) s9
        """
        XCTAssertEqual(MeShow.parse(report).staleSources, ["dana_profile.md", "(removed) s9"])
        XCTAssertEqual(MeShow.parse("stale sources: none").staleSources, [])
        XCTAssertEqual(MeShow.parse("nothing useful").staleSources, [])
    }

    func testSourcesChangedShowsOnlyWhenTheBuildIsOlderThanSevenDays() async throws {
        let runner = FakeMeRunner()
        runner.showOutput = "stale sources: dana_profile.md"
        // Built 16 Oct; now 17 Oct: a change is not worth a banner yet.
        let young = model(try profile(), runner: runner)
        await young.checkSources()
        XCTAssertEqual(young.staleSources, ["dana_profile.md"])
        XCTAssertFalse(young.showSourcesChanged)
        XCTAssertEqual(young.sources.first?.changed, true, "the source row still says it changed")
        // Built 16 Oct; now 24 Oct 10:00: more than 7 days.
        let oldNow = ISO8601DateFormatter().date(from: "2026-10-23T10:00:00Z")!
        let old = model(try profile(), runner: runner, now: oldNow)
        await old.checkSources()
        XCTAssertTrue(old.showSourcesChanged)
        // Nothing changed: no banner however old.
        runner.showOutput = "stale sources: none"
        await old.checkSources()
        XCTAssertFalse(old.showSourcesChanged)
    }

    // MARK: runner (fake)

    func testRefreshRunsRefreshWhenAProfileExistsAndBuildWhenNot() async throws {
        let runner = FakeMeRunner()
        let withProfile = model(try profile(), runner: runner)
        await withProfile.refresh()
        XCTAssertEqual(runner.calls.map(\.action), [.refresh, .show])
        XCTAssertEqual(runner.calls.first?.dir, withProfile.directory)
        XCTAssertEqual(runner.calls.first?.brain.path, "/brain")
        XCTAssertEqual(withProfile.phase, .idle)

        let none = FakeMeRunner()
        let fresh = model(try profile(md: nil, sources: false), runner: none)
        await fresh.refresh()
        XCTAssertEqual(none.calls.map(\.action), [.build], "no profile yet: build (and no show, there is nothing to compare)")
    }

    func testARefreshThatChangesNothingSaysSoAndSpendsNothing() async throws {
        let runner = FakeMeRunner()
        runner.refreshLog = ["no source changed since the last build: nothing to do, nothing spent"]
        let m = model(try profile(), runner: runner)
        await m.refresh()
        XCTAssertEqual(m.message, "No source changed since the last build: nothing to do, nothing spent")
    }

    func testARefreshThatWritesShowsTheNewNumbers() async throws {
        let dir = try profile()
        let runner = FakeMeRunner()
        runner.onRun = { action, dir in
            guard action == .refresh else { return }
            // What prep does: new meta, new file.
            let meta: [String: Any] = ["built_at": "2026-10-17T08:00:00+00:00", "tokens": 3300, "spend_usd_total": 0.14]
            try? JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("me.meta.json"))
            try? Self.meMD.replacingOccurrences(of: "six years", with: "seven years").write(to: dir.appendingPathComponent("me.md"), atomically: true, encoding: .utf8)
        }
        let m = model(dir, runner: runner)
        await m.refresh()
        XCTAssertEqual(m.meta?.summary, "Built 17 Oct · 3,300 tokens · $0.14")
        XCTAssertTrue(m.line(id: "m001")?.text.contains("seven years") == true, "the page reads the new file")
        XCTAssertEqual(m.message, "Done · built 17 Oct · 3,300 tokens · $0.14")
    }

    func testAFailedRunShowsPrepsLastLineAndAllowsAnotherTry() async throws {
        let runner = FakeMeRunner()
        runner.outcome = .failed("error: no readable source: add one to me.sources.json or the Me page")
        let m = model(try profile(), runner: runner)
        await m.refresh()
        XCTAssertEqual(m.phase, .failed("error: no readable source: add one to me.sources.json or the Me page"))
        XCTAssertFalse(m.isRunning)
        runner.outcome = nil
        await m.refresh()
        XCTAssertEqual(m.phase, .idle)
    }

    func testNoBrainFolderIsAMessageNotACrash() async throws {
        let m = MeModel(directory: try profile(), runner: { FakeMeRunner() }, brainDir: { nil }, fake: { false })
        await m.refresh()
        XCTAssertEqual(m.phase, .failed("The brain folder was not found."))
    }

    func testEditsAreRefusedWhileTheRunnerWritesTheFiles() async throws {
        let runner = FakeMeRunner()
        let gate = AsyncGate()
        runner.gate = gate
        let m = model(try profile(), runner: runner)
        let run = Task { await m.refresh() }
        while !m.isRunning { await Task.yield() }
        XCTAssertEqual(m.phase, .running(.refresh))
        XCTAssertEqual(m.edit(id: "m001", to: "x").failure, .busy)
        XCTAssertEqual(m.delete(id: "m001").failure, .busy)
        XCTAssertEqual(m.addNote("x").failure, .busy)
        XCTAssertEqual(m.setSource("s1", enabled: false).failure, .busy)
        XCTAssertFalse(m.canEdit)
        await gate.open()
        await run.value
        XCTAssertTrue(m.canEdit)
        XCTAssertNil(m.edit(id: "m001", to: "A short who line.").failure)
    }

    func testTheProgressLineShowsWhileRunning() async throws {
        let runner = FakeMeRunner()
        let gate = AsyncGate()
        runner.gate = gate
        runner.progress = ["reading 3 sources"]
        let m = model(try profile(), runner: runner)
        let run = Task { await m.refresh() }
        while m.progress == nil { await Task.yield() }
        XCTAssertEqual(m.progress, "reading 3 sources")
        await gate.open()
        await run.value
        XCTAssertNil(m.progress)
    }

    // MARK: the command line

    func testTheArgumentsCarryNoKeyAndNoProfileText() {
        let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/Verse/profile")
        XCTAssertEqual(MePrep.arguments(.refresh, profileDir: dir, fake: false),
                       ["-u", "-m", "verse_brain.prep", "me", "refresh", "--profile-dir", dir.path])
        XCTAssertEqual(MePrep.arguments(.build, profileDir: dir, fake: true),
                       ["-u", "-m", "verse_brain.prep", "me", "build", "--profile-dir", dir.path, "--fake"])
        XCTAssertFalse(MePrep.arguments(.show, profileDir: dir, fake: true).contains("--fake"), "show has no fake mode")
    }

    /// Real process, real brain code, offline `--fake`, on the fictional fixture only. Runs when VERSE_BRAIN_PYTHON points at the
    /// brain's interpreter.
    func testTheRealPrepBuildsRefreshesAndShowsOnAFictionalSource() async throws {
        guard let py = ProcessInfo.processInfo.environment["VERSE_BRAIN_PYTHON"], !py.isEmpty else {
            throw XCTSkip("set VERSE_BRAIN_PYTHON to the brain's interpreter to run the real prep")
        }
        let brain = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("brain")
        let fixture = brain.appendingPathComponent("tests/fixtures/me/dana_profile.md")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "the Dana fixture is not there")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-me-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // Own sources only (a copy of the fixture): the default ones would read the owner's real files.
        let source = dir.appendingPathComponent("dana_profile.md")
        try FileManager.default.copyItem(at: fixture, to: source)
        let src = [["id": "s1", "kind": "file", "path": source.path, "label": "dana_profile.md", "enabled": true]]
        try JSONSerialization.data(withJSONObject: src).write(to: dir.appendingPathComponent("me.sources.json"))
        let m = MeModel(directory: dir, runner: { MePrep(python: URL(fileURLWithPath: py)) }, brainDir: { brain }, fake: { true })
        XCTAssertFalse(m.hasProfile)
        await m.refresh()
        XCTAssertEqual(m.phase, .idle, "\(m.phase)")
        XCTAssertTrue(m.hasProfile)
        XCTAssertFalse(m.lines(.who).isEmpty)
        XCTAssertGreaterThan(m.meta?.tokens ?? 0, 0)
        XCTAssertEqual(m.staleSources, [])

        // Edit a line, refresh: nothing changed, nothing spent, and the edit is still there.
        let id = try XCTUnwrap(m.lines(.who).first?.id)
        XCTAssertNil(m.edit(id: id, to: "My own wording of this line.").failure)
        await m.refresh()
        XCTAssertEqual(m.message, "No source changed since the last build: nothing to do, nothing spent")
        XCTAssertEqual(m.line(id: id)?.fields, ["My own wording of this line."])

        // The source changes: show lists it.
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nDana now also leads the platform guild at Larkspur Health every second Thursday.\n".utf8))
        try handle.close()
        await m.checkSources()
        XCTAssertEqual(m.staleSources, ["dana_profile.md"])
        XCTAssertEqual(m.sources.first?.changed, true)
    }
}

// MARK: - helpers

extension Result {
    /// The error of a failed result, nil for a success: `Result<Void, _>` is not Equatable.
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}

/// A runner for tests: records its calls, writes nothing unless told to.
final class FakeMeRunner: MeRunning, @unchecked Sendable {
    struct Call { var action: MeAction; var dir: URL; var brain: URL; var fake: Bool }
    var calls: [Call] = []
    var outcome: MeOutcome?
    var showOutput = "stale sources: none"
    var refreshLog: [String] = []
    var progress: [String] = []
    var gate: AsyncGate?
    var onRun: ((MeAction, URL) -> Void)?

    func run(_ action: MeAction, profileDir: URL, brainDir: URL, fake: Bool, onLine: @escaping @Sendable (String) -> Void) async -> MeOutcome {
        calls.append(Call(action: action, dir: profileDir, brain: brainDir, fake: fake))
        for l in progress { onLine(l) }
        if let gate { await gate.wait() }
        onRun?(action, profileDir)
        if let outcome, action != .show { return outcome }
        if action == .show { return .done(stdout: showOutput, log: []) }
        return .done(stdout: profileDir.path, log: refreshLog)
    }

    func cancel() {}
}

/// One-shot gate: `wait` suspends until `open`.
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for w in waiters { w.resume() }
        waiters = []
    }
}
