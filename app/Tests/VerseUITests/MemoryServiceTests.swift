import Combine
import Foundation
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// The memory service (memory spec 2.1, 2.4, 3.3, 3.5): sync of the index, coalescing, the Trash hook, and the brief runner. The brain is
/// scripted in-process; no process starts, no key is read, nothing is paid.
@MainActor
final class MemoryServiceTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!

    override func setUpWithError() throws { scratch = try MemoryFixtures.scratch() }
    override func tearDownWithError() throws { scratch.remove() }

    /// A service whose brains are scripted; `brains` collects every process it starts.
    private func service(brains: MemBox<[ScriptedIndexBrain]>, make: @escaping () -> ScriptedIndexBrain = { ScriptedIndexBrain() }) -> MemoryService {
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { MemoryFixtures.owner },
                              makeBrain: { let b = make(); brains.value.append(b); return b })
        s.busyRetryDelay = .milliseconds(50)
        s.indexStall = .seconds(10)
        return s
    }

    private func expectEventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await eventually(5, condition)
        XCTAssertTrue(ok, "timed out waiting", file: file, line: line)
    }

    // MARK: sync

    func testSyncSendsStartThenManifestThenOnePutThenEnd() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(need: { $0.contains("halden-kickoff") ? ["halden-kickoff"] : [] }) })
        let phases = MemBox<[MemoryService.Phase]>([])
        let sub = s.$phase.removeDuplicates().sink { phases.value.append($0) }
        defer { sub.cancel() }

        let ok = await s.syncNow(timeout: .seconds(10))
        XCTAssertTrue(ok)
        let b = try XCTUnwrap(brains.value.first)
        XCTAssertEqual(brains.value.count, 1)
        XCTAssertEqual(b.sentTypes, ["memory_index_start", "sync", "put", "end"], "the first line decides the mode")
        XCTAssertEqual(b.sent[0], #"{"db":"\#(scratch.memory.path)/index.sqlite","embed":true,"type":"memory_index_start"}"#)
        XCTAssertEqual(b.syncedNames, ["corvo-design-call", "halden-kickoff", "halden-weekly-prep"])
        let sync = MemoryFixtures.object(b.sent[1])
        let entries = try XCTUnwrap(sync["sessions"] as? [[String: Any]])
        XCTAssertEqual(entries.map { Set($0.keys) }, Array(repeating: Set(["name", "fp", "labels"]), count: 3))
        XCTAssertEqual(entries.first { $0["name"] as? String == "halden-kickoff" }?["fp"] as? String,
                       MemoryManifest.fingerprint(dir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana"))

        // The put carries the rows Ask this meeting would send, from the one implementation.
        let put = MemoryFixtures.object(b.sent[2])
        XCTAssertEqual(put["name"] as? String, "halden-kickoff")
        XCTAssertEqual(put["kind"] as? String, "meeting")
        XCTAssertEqual(put["lang"] as? String, "en")
        XCTAssertEqual(put["title"] as? String, "Halden Kickoff")
        XCTAssertEqual(put["dir"] as? String, scratch.sessions.appendingPathComponent("halden-kickoff").path)
        let doc = TranscriptDocument.load(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana")
        let expected = doc.askRows.map { ["stamp": $0.stamp, "speaker": $0.speaker, "text": $0.text] }
        let rows = try XCTUnwrap(put["rows"] as? [[String: String]])
        XCTAssertEqual(rows, expected)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.first, ["stamp": "0:06", "speaker": "Dana", "text": "Thanks for making time, Marta. Let's start with what the pilot should cover."])
        XCTAssertEqual(rows.last?["speaker"], "Other")

        XCTAssertEqual(phases.value, [.idle, .indexing(done: 0, total: 1), .indexing(done: 1, total: 1), .embedding(done: 3, total: 3), .idle])
        XCTAssertEqual(s.indexedSessions, 3)
        XCTAssertTrue(b.closed, "the process is closed when the run ends")
    }

    func testAPreparedSessionIsPutWithoutRows() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(need: { _ in ["halden-weekly-prep"] }) })
        _ = await s.syncNow(timeout: .seconds(10))
        let put = MemoryFixtures.object(try XCTUnwrap(brains.value.first).sent[2])
        XCTAssertEqual(put["kind"] as? String, "prepared")
        XCTAssertEqual((put["rows"] as? [Any])?.count, 0)
    }

    func testNothingToIndexSendsNoPutAndNoIndexingPhase() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(need: { _ in [] }) })
        let phases = MemBox<[MemoryService.Phase]>([])
        let sub = s.$phase.removeDuplicates().sink { phases.value.append($0) }
        defer { sub.cancel() }
        _ = await s.syncNow(timeout: .seconds(10))
        XCTAssertEqual(try XCTUnwrap(brains.value.first).sentTypes, ["memory_index_start", "sync", "end"])
        XCTAssertEqual(phases.value, [.idle, .embedding(done: 3, total: 3), .idle])
    }

    func testLabelsAndTheRecordingSessionComeFromTheClosures() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(need: { _ in [] }) })
        s.labels = { $0 == "halden-kickoff" ? ["Marta Velin"] : [] }
        s.recordingSession = { "corvo-design-call" }
        _ = await s.syncNow(timeout: .seconds(10))
        let b = try XCTUnwrap(brains.value.first)
        XCTAssertEqual(b.syncedNames, ["halden-kickoff", "halden-weekly-prep"])
        let entries = try XCTUnwrap(MemoryFixtures.object(b.sent[1])["sessions"] as? [[String: Any]])
        XCTAssertEqual(entries.first { $0["name"] as? String == "halden-kickoff" }?["labels"] as? [String], ["Marta Velin"])
    }

    func testTheIndexWriterUsesItsOwnLaunchSoItNeedsNoApiKey() async throws {
        let index = MemBox<Int>(0), api = MemBox<Int>(0)
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                              makeBrain: { api.value += 1; return ScriptedBriefBrain(.done(cost: 0.01)) },
                              makeIndexBrain: { index.value += 1; return ScriptedIndexBrain() })
        _ = await s.syncNow(timeout: .seconds(10))
        XCTAssertEqual(index.value, 1)
        XCTAssertEqual(api.value, 0, "the sync never uses the API-capable launch")
        _ = try await s.makeBrief(request()).get()
        XCTAssertEqual(api.value, 1, "the brief does")
        XCTAssertEqual(index.value, 1)
    }

    func testLaunchArguments() {
        XCTAssertEqual(MemoryService.brainArguments(fake: false, indexOnly: true), ["--no-api"])
        XCTAssertEqual(MemoryService.brainArguments(fake: true, indexOnly: true), ["--fake", "--no-api"])
        XCTAssertEqual(MemoryService.brainArguments(fake: false, indexOnly: false), [], "the brief process reads the Keychain key itself")
    }

    func testRendersSkipTheEmbeddingPhase() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains)
        s.embeds = false
        _ = await s.syncNow(timeout: .seconds(10))
        XCTAssertTrue(try XCTUnwrap(brains.value.first).sent[0].contains(#""embed":false"#))
    }

    func testThreeRequestsDuringARunMakeExactlyOneMoreRun() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(hold: brains.value.isEmpty) })
        s.requestSync(.launch)
        await expectEventually { brains.value.count == 1 && brains.value[0].sentTypes.contains("end") }
        // The first run is open (its brain holds the end). Everything requested now is one more run, not three.
        s.requestSync(.sessionsChanged)
        s.requestSync(.labelsChanged)
        s.requestSync(.callEnded)
        XCTAssertEqual(brains.value.count, 1, "never two at once")
        brains.value[0].release()
        await expectEventually { brains.value.count == 2 && s.phase == .idle && !s.isSyncing }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(brains.value.count, 2, "one run, plus exactly one for everything requested during it")
        XCTAssertEqual(s.runCount, 2)
    }

    func testRequestsBeforeARunReadsTheFolderAreOneRun() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains)
        s.requestSync(.launch)
        s.requestSync(.sessionsChanged)
        await expectEventually { brains.value.count == 1 && s.phase == .idle && !s.isSyncing }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(brains.value.count, 1)
    }

    func testBusyRetriesWithAnotherProcessAfterTheDelay() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(busy: brains.value.isEmpty) })
        let ok = await s.syncNow(timeout: .seconds(10))
        XCTAssertTrue(ok)
        XCTAssertEqual(brains.value.count, 2, "status busy -> a second process after the delay")
        XCTAssertEqual(brains.value[0].sentTypes, ["memory_index_start", "sync"], "the busy process got no put and no end")
        XCTAssertEqual(brains.value[1].sentTypes.last, "end")
        XCTAssertEqual(s.phase, .idle)
    }

    func testStartFailureIsAFailedPhaseNotACrashAndTheNextRequestTriesAgain() async throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "no python" } }
        let attempts = MemBox<Int>(0)
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" }, makeBrain: { attempts.value += 1; throw Boom() })
        let ok = await s.syncNow(timeout: .seconds(5))
        XCTAssertFalse(ok)
        XCTAssertEqual(s.phase, .failed("no python"))
        XCTAssertEqual(attempts.value, 1)
        s.requestSync(.sessionsChanged)
        await expectEventually { attempts.value == 2 }
    }

    func testABrainThatGoesQuietIsEndedByTheWatchdog() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(silent: true) })
        s.indexStall = .milliseconds(200)
        let ok = await s.syncNow(timeout: .seconds(5))
        XCTAssertFalse(ok)
        XCTAssertEqual(s.phase, .failed("the memory indexer stopped answering"))
        XCTAssertTrue(try XCTUnwrap(brains.value.first).closed)
    }

    func testSyncNowGivesUpAtTheTimeout() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(silent: true) })
        s.indexStall = .milliseconds(400)
        let ok = await s.syncNow(timeout: .milliseconds(50))
        XCTAssertFalse(ok, "the index is asked as it is")
        await expectEventually { s.phase != .idle }   // let the silent run end before the test does
    }

    func testADisabledServiceNeverStartsAProcess() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                              makeBrain: { let b = ScriptedIndexBrain(); brains.value.append(b); return b }, enabled: false)
        s.requestSync(.launch)
        s.callEnded()
        let ok = await s.syncNow(timeout: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(ok)
        XCTAssertTrue(brains.value.isEmpty)
    }

    func testNoDirectoryIsCreatedUntilTheFirstUse() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.memory.path))
        let paths = scratch.paths
        paths.ensureDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.briefs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.chats.path))
        XCTAssertEqual(paths.chat(named: "all").lastPathComponent, "all.jsonl")
        XCTAssertEqual(paths.db.lastPathComponent, "index.sqlite")
        XCTAssertEqual(paths.people.lastPathComponent, "people.json")
        XCTAssertEqual(paths.spendDir, paths.dir)
    }

    // MARK: triggers

    func testTheLaunchSyncStartsAfterItsDelay() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains)
        s.launchDelay = .milliseconds(80)
        let (settings, cleanup) = controllerSettings()
        defer { cleanup() }
        let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        s.attach(controller: controller)
        XCTAssertTrue(brains.value.isEmpty, "not at once")
        await expectEventually { brains.value.count == 1 }
    }

    func testACallEndingSyncsAfterItsDelay() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains)
        s.callEndDelay = .milliseconds(80)
        s.callEnded()
        XCTAssertTrue(brains.value.isEmpty)
        await expectEventually { brains.value.count == 1 }
    }

    private func controllerSettings() -> (AppSettings, () -> Void) {
        let (defaults, cleanup) = FolderFixtures.defaults()
        return (AppSettings(defaults: defaults), cleanup)
    }

    // MARK: Move to Trash

    func testTrashAndUndoChangeTheNextManifest() async throws {
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = service(brains: brains, make: { ScriptedIndexBrain(need: { _ in [] }) })
        s.indexStall = .seconds(10)
        let trashDir = scratch.top.appendingPathComponent("trash", isDirectory: true)
        let ops = SessionTrashOps(
            trash: { url in
                let slot = trashDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                let dest = slot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            },
            restore: { from, to in try FileManager.default.moveItem(at: from, to: to) })
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let settings = AppSettings(defaults: defaults)
        let controller = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        controller.sessionsRoot = scratch.sessions
        let model = HomeSessionsModel(root: scratch.sessions, defaults: defaults, trashOps: ops,
                                      eventMap: EventSessionMap(url: scratch.sessions.appendingPathComponent("event-sessions.json")))
        model.hooks = .window(controller: controller, sim: nil, settings: settings, router: HomeRouter(), memory: s)

        // A first run teaches the service which sessions the index holds.
        s.requestSync(.launch)
        await expectEventually { brains.value.count == 1 && s.phase == .idle && !s.isSyncing }
        XCTAssertEqual(brains.value[0].sentTypes, ["memory_index_start", "sync", "end"], "nothing to drop on the first run")

        let outcome = model.trash(["corvo-design-call"])
        let batch = try XCTUnwrap(outcome.batch)
        await expectEventually { brains.value.count == 2 && s.phase == .idle && !s.isSyncing }
        XCTAssertEqual(brains.value[1].sentTypes, ["memory_index_start", "drop", "sync", "end"], "drop first, then the manifest")
        XCTAssertEqual(MemoryFixtures.object(brains.value[1].sent[1])["names"] as? [String], ["corvo-design-call"])
        XCTAssertEqual(brains.value[1].syncedNames, ["halden-kickoff", "halden-weekly-prep"], "the trashed session is gone from the manifest")

        XCTAssertEqual(model.restore(batch), ["corvo-design-call"])
        await expectEventually { brains.value.count == 3 && s.phase == .idle && !s.isSyncing }
        XCTAssertEqual(brains.value[2].sentTypes, ["memory_index_start", "sync", "end"], "nothing left the folder this time")
        XCTAssertEqual(brains.value[2].syncedNames, ["corvo-design-call", "halden-kickoff", "halden-weekly-prep"], "Undo brings it back")
    }

    // MARK: brief

    private func briefService(brains: MemBox<[ScriptedBriefBrain]>, mode: ScriptedBriefBrain.Mode) -> MemoryService {
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { MemoryFixtures.owner },
                              makeBrain: { let b = ScriptedBriefBrain(mode); brains.value.append(b); return b })
        s.cancelGrace = .milliseconds(80)
        s.briefStall = .seconds(10)
        return s
    }

    private func request(sessionOut: URL? = nil) -> BriefRequest {
        BriefRequest(entity: .init(id: "e-3k9xq2ma", kind: "person", name: "Marta Velin", company: "Halden Works"),
                     sessions: ["halden-kickoff"], upcoming: nil, lang: "en", sessionOut: sessionOut)
    }

    func testBriefSendsTheRequestAndReturnsTheDecodedFile() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .done(cost: 0.048))
        let result = await s.makeBrief(request())
        let file = try result.get()
        XCTAssertEqual(file.name, "Marta Velin")
        XCTAssertEqual(file.sections.count, 5)
        XCTAssertEqual(file, BriefStore.load(entity: "e-3k9xq2ma", paths: scratch.paths), "read from the out file")

        let b = try XCTUnwrap(brains.value.first)
        XCTAssertEqual(b.sent.count, 1)
        let o = MemoryFixtures.object(b.sent[0])
        XCTAssertEqual(o["type"] as? String, "brief_start")
        XCTAssertEqual(o["db"] as? String, scratch.paths.db.path)
        XCTAssertEqual(o["out"] as? String, scratch.paths.brief(entity: "e-3k9xq2ma").path)
        XCTAssertEqual(o["owner_name"] as? String, "Dana")
        XCTAssertTrue(o["session_out"] is NSNull)
        XCTAssertTrue(s.briefsInFlight.isEmpty)
        XCTAssertTrue(b.closed)
    }

    func testBriefForAPreparedSessionLandsInThatSessionsSpendAsKindBrief() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .done(cost: 0.048))
        let prep = scratch.sessions.appendingPathComponent("halden-weekly-prep", isDirectory: true)
        _ = try await s.makeBrief(request(sessionOut: prep)).get()
        let runs = SpendLedger.runs(sessionDir: prep)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.kind, "brief")
        XCTAssertEqual(runs.first?.costUSD ?? 0, 0.048, accuracy: 1e-9)
        XCTAssertTrue(SpendLedger.runs(sessionDir: scratch.paths.spendDir).isEmpty)
        XCTAssertEqual(MemoryFixtures.object(try XCTUnwrap(brains.value.first).sent[0])["session_out"] as? String, prep.path)
    }

    func testBriefWithoutASessionGoesIntoTheMemorySpend() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .done(cost: 0.05))
        _ = try await s.makeBrief(request()).get()
        let runs = SpendLedger.runs(sessionDir: scratch.paths.spendDir)
        XCTAssertEqual(runs.map(\.kind), ["brief"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.memory.appendingPathComponent("spend.json").path))
    }

    func testTwoBriefsInTheSameSecondStayTwoRecords() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .done(cost: 0.05))
        let first = request()
        var other = first
        other.entity.id = "e-8hz1p0qq"
        async let a = s.makeBrief(first)
        async let b = s.makeBrief(other)
        _ = try await (a.get(), b.get())
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.paths.spendDir).count, 2)
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.paths.spendDir).reduce(0) { $0 + $1.costUSD }, 0.10, accuracy: 1e-9)
    }

    func testBriefErrorBecomesAChatFailureAndRecordsNothingWithoutUsage() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .error(kind: "credit_exhausted", cost: nil))
        let result = await s.makeBrief(request())
        guard case .failure(let f) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(f.kind, "credit_exhausted")
        XCTAssertEqual(f.message, "fixture message")
        XCTAssertTrue(SpendLedger.runs(sessionDir: scratch.paths.spendDir).isEmpty)
    }

    func testBriefErrorWithUsageStillRecordsItsCost() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .error(kind: "rate_limited", cost: 0.01))
        _ = await s.makeBrief(request())
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.paths.spendDir).first?.costUSD ?? 0, 0.01, accuracy: 1e-9)
    }

    func testNoSessionsFromTheBrainIsPassedThrough() async {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .error(kind: "no_sessions", cost: nil))
        guard case .failure(let f) = await s.makeBrief(request()) else { return XCTFail("expected a failure") }
        XCTAssertEqual(f.kind, "no_sessions")
    }

    func testTwoRequestsForOneEntityStartOneProcess() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .done(cost: 0.048))
        let req = request()
        async let a = s.makeBrief(req)
        async let b = s.makeBrief(req)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(brains.value.count, 1)
        XCTAssertEqual(try ra.get(), try rb.get(), "both get the one result")
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.paths.spendDir).count, 1, "the cost is recorded once")
    }

    func testBriefStartFailureIsStartFailed() async {
        struct Boom: Error {}
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" }, makeBrain: { throw Boom() })
        guard case .failure(let f) = await s.makeBrief(request()) else { return XCTFail("expected a failure") }
        XCTAssertEqual(f.kind, "start_failed")
        XCTAssertTrue(s.briefsInFlight.isEmpty)
    }

    func testCancelSendsStopAndRecordsNothing() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .endsOnStop)
        let req = request()
        let task = Task { await s.makeBrief(req) }
        await expectEventually { s.briefsInFlight == ["e-3k9xq2ma"] && brains.value.count == 1 }
        s.cancelBrief(entity: "e-3k9xq2ma")
        guard case .failure(let f) = await task.value else { return XCTFail("expected a failure") }
        XCTAssertEqual(f.kind, "cancelled")
        let b = try XCTUnwrap(brains.value.first)
        XCTAssertEqual(MemoryFixtures.object(b.sent[1])["type"] as? String, "control")
        XCTAssertEqual(MemoryFixtures.object(b.sent[1])["action"] as? String, "stop")
        XCTAssertTrue(SpendLedger.runs(sessionDir: scratch.paths.spendDir).isEmpty)
    }

    func testCancelKillsAProcessThatIgnoresStop() async throws {
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let s = briefService(brains: brains, mode: .silent)
        let req = request()
        let task = Task { await s.makeBrief(req) }
        await expectEventually { brains.value.count == 1 && s.briefsInFlight == ["e-3k9xq2ma"] }
        s.cancelBrief(entity: "e-3k9xq2ma")
        guard case .failure(let f) = await task.value else { return XCTFail("expected a failure") }
        XCTAssertEqual(f.kind, "cancelled")
        XCTAssertTrue(try XCTUnwrap(brains.value.first).closed, "killed after the grace")
    }

    func testCancelOfAnUnknownEntityIsHarmless() {
        let s = briefService(brains: MemBox([]), mode: .silent)
        s.cancelBrief(entity: "e-nobody")
    }

    // MARK: afterPrepare

    func testPrepareSessionCallsAfterPrepareOnceWithTheEventAndFolderName() async throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let calls = MemBox<[(String, String)]>([])
        let onPrepared = MemBox<[String]>([])
        let model = HomeUpNextModel(settings: AppSettings(defaults: defaults), meeting: MeetingSettings(defaults: defaults), sessions: { [] },
                                    eventMap: EventSessionMap(url: scratch.top.appendingPathComponent("evmap.json")),
                                    prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/halden-weekly-prep") },
                                    onPrepared: { onPrepared.value.append($0) },
                                    afterPrepare: { event, folder in calls.value.append((event.id, folder)) })
        let event = MeetingEvent(id: "ev-halden", title: "Halden weekly", start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(3_600))
        let dir = try await model.prepareSession(for: event)
        XCTAssertEqual(dir.lastPathComponent, "halden-weekly-prep")
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertEqual(calls.value.first?.0, "ev-halden")
        XCTAssertEqual(calls.value.first?.1, "halden-weekly-prep")
        XCTAssertEqual(onPrepared.value, ["halden-weekly-prep"], "onPrepared still runs, before afterPrepare")
    }

    func testPrepareSessionWithoutAfterPrepareStillWorks() async throws {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        let model = HomeUpNextModel(settings: AppSettings(defaults: defaults), meeting: MeetingSettings(defaults: defaults), sessions: { [] },
                                    eventMap: EventSessionMap(url: scratch.top.appendingPathComponent("evmap.json")),
                                    prepare: { _, _ in URL(fileURLWithPath: "/tmp/sessions/x") })
        let event = MeetingEvent(id: "e", title: "t", start: Date(), end: Date().addingTimeInterval(60))
        let dir = try await model.prepareSession(for: event)
        XCTAssertEqual(dir.lastPathComponent, "x")
    }
}
