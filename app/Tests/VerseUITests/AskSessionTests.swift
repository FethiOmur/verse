import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// An in-process stand-in for the brain child process: records what Swift sends, lets the test push lines back.
final class FakeAskBrain: SimBrainTransport, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false

    init() { (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded) }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    func send(_ line: String) { lock.withLock { _sent.append(line) } }
    func close() async { lock.withLock { _closed = true }; continuation.finish() }
    func push(_ line: String) { continuation.yield(line) }
    func push(_ obj: [String: Any]) { continuation.yield(AskWire.line(obj)) }
}

@MainActor
final class AskSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func fixtureDocument() -> TranscriptDocument {
        let fx = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/transcript-forward", isDirectory: true)
        return TranscriptDocument.load(sessionDir: fx, ownerName: "Dana")
    }

    private func context(me: URL? = nil) -> AskContext {
        let rows = fixtureDocument().askRows.map { AskRow(stamp: $0.stamp, speaker: $0.speaker, text: $0.text) }
        return AskContext(sessionDir: dir, ownerName: "Dana", title: "Fixture call", date: Date(timeIntervalSince1970: 1_792_100_000), meCore: me, rows: rows)
    }

    private func spin(_ ms: Int = 60) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// A session whose brain is the fake; `brains` collects every process it starts.
    private func session(idle: Duration = .seconds(600), brains: Box<[FakeAskBrain]>) -> AskSession {
        let s = AskSession(idleInterval: idle, makeBrain: { let b = FakeAskBrain(); brains.value.append(b); return b })
        s.recordSpend = { d, at, cost in SpendLedger.record(sessionDir: d, startedAt: at, costUSD: cost, kind: "ask") }
        return s
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    // MARK: ask_start

    func testAskStartLineGolden() {
        let tz = TimeZone(secondsFromGMT: 2 * 3600)!
        let ctx = AskContext(sessionDir: URL(fileURLWithPath: "/tmp/sessions/fixture"), ownerName: "Dana", title: "Fixture call",
                             date: Date(timeIntervalSince1970: 1_792_100_000), meCore: URL(fileURLWithPath: "/tmp/profile/me.md"),
                             rows: [AskRow(stamp: "0:05", speaker: "Dana", text: "Hello."), AskRow(stamp: "0:22", speaker: "Other", text: "Hi, Dana.")])
        let expected = #"{"date":"2026-10-15T23:33:20+02:00","me":{"core":"/tmp/profile/me.md"},"model":"sonnet","owner_name":"Dana","session_dir":"/tmp/sessions/fixture","title":"Fixture call","transcript":[{"speaker":"Dana","stamp":"0:05","text":"Hello."},{"speaker":"Other","stamp":"0:22","text":"Hi, Dana."}],"type":"ask_start"}"#
        XCTAssertEqual(ctx.startLine(model: .sonnet, timeZone: tz), expected)
        var noMe = ctx
        noMe.meCore = nil
        XCTAssertTrue(noMe.startLine(model: .opus, timeZone: tz).contains(#""me":null"#), "the toggle off sends null")
        XCTAssertTrue(noMe.startLine(model: .opus, timeZone: tz).contains(#""model":"opus""#))
    }

    func testAskStartRowsComeFromTranscriptDocumentUnchanged() throws {
        let doc = fixtureDocument()
        let line = context().startLine(model: .sonnet)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(o["transcript"] as? [[String: String]])
        XCTAssertEqual(rows.map { $0["stamp"] }, doc.rows.map(\.stamp))
        XCTAssertEqual(rows.map { $0["speaker"] }, doc.rows.map { doc.name(of: $0.speaker) })
        XCTAssertEqual(rows.last?["stamp"], "1:02:05", "elapsed stamps, hour form included")
    }

    // MARK: streaming, cost

    func testDeltasAccumulateAndDoneAddsCostToSpendJsonAsKindAsk() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        let b = try XCTUnwrap(brains.value.first)
        XCTAssertTrue(b.sent[0].contains(#""type":"ask_start""#), "the first line decides the mode")

        s.send("What did they ask?")
        XCTAssertTrue(s.isBusy)
        XCTAssertEqual(s.turns.last?.phase, .waiting)
        XCTAssertTrue(b.sent[1].contains(#""id":"q1""#) && b.sent[1].contains(#""type":"ask""#) && b.sent[1].contains(#""model":"sonnet""#))

        b.push(["type": "ask_delta", "id": "a1", "q": "q1", "text": "She asked "])
        b.push(["type": "ask_delta", "id": "a1", "q": "q1", "text": "about routes [0:22]."])
        await spin()
        XCTAssertEqual(s.turns.last?.phase, .streaming)
        XCTAssertEqual(s.turns.last?.shownText, "She asked about routes [0:22].")

        b.push(["type": "ask_done", "id": "a1", "q": "q1", "model": "claude-sonnet-5-5",
                "usage": ["input": 412, "output": 388, "cache_read": 0, "cache_write": 31240], "cost_usd": 0.0104, "ms_first_token": 1840,
                "ms_total": 4120, "citations": ["0:22"], "stop_reason": "end_turn", "cost_estimated": false])
        await spin()
        XCTAssertFalse(s.isBusy)
        let a = try XCTUnwrap(s.turns.last?.answer)
        XCTAssertEqual(a.text, "She asked about routes [0:22].")
        XCTAssertEqual(a.costUSD, 0.0104, accuracy: 1e-9)
        XCTAssertEqual(a.usage.cacheWrite, 31240)
        XCTAssertEqual(s.chatCost, 0.0104, accuracy: 1e-9)

        // A second answer in the same opening updates the same run, which is of kind ask.
        s.send("And then?")
        b.push(["type": "ask_done", "id": "a2", "q": "q2", "model": "claude-sonnet-5-5", "usage": ["input": 10, "output": 10, "cache_read": 31240, "cache_write": 0],
                "cost_usd": 0.0036, "ms_first_token": 900, "ms_total": 2000, "citations": [], "stop_reason": "end_turn", "cost_estimated": false])
        await spin()
        let runs = SpendLedger.runs(sessionDir: dir)
        XCTAssertEqual(runs.count, 1, "one record per panel opening")
        XCTAssertEqual(runs[0].kind, "ask")
        XCTAssertEqual(runs[0].costUSD, 0.014, accuracy: 1e-9)
        let json = try String(contentsOf: dir.appendingPathComponent("spend.json"), encoding: .utf8)
        XCTAssertTrue(json.contains(#""kind" : "ask""#), json)
    }

    func testSpendRecordWithoutKindStaysAbsentAndOldFilesDecode() throws {
        SpendLedger.record(sessionDir: dir, startedAt: Date(timeIntervalSince1970: 1_792_100_000), costUSD: 0.5)
        let text = try String(contentsOf: dir.appendingPathComponent("spend.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("kind"), "a call run has no kind key")
        XCTAssertNil(SpendLedger.runs(sessionDir: dir).first?.kind)
        // An ask run in the same second is a second record.
        SpendLedger.record(sessionDir: dir, startedAt: Date(timeIntervalSince1970: 1_792_100_000), costUSD: 0.02, kind: "ask")
        XCTAssertEqual(SpendLedger.runs(sessionDir: dir).count, 2)
    }

    func testAnErrorMarksTheQuestionFailedAndRetryAsksItAgain() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        let b = try XCTUnwrap(brains.value.first)
        s.send("Why?")
        b.push(["type": "ask_error", "id": "a1", "q": "q1", "kind": "rate_limited", "message": "slow down", "retry_after": 12])
        await spin()
        XCTAssertEqual(s.turns.last?.phase, .failed)
        XCTAssertEqual(s.turns.last?.failure?.kind, "rate_limited")
        XCTAssertEqual(s.turns.last?.failure?.retryAfter, 12)
        XCTAssertFalse(s.isBusy)
        s.retry("q1")
        XCTAssertEqual(s.turns.map(\.id), ["q2"], "the failed attempt leaves the screen")
        XCTAssertTrue(b.sent.last?.contains(#""text":"Why?""#) ?? false)
        XCTAssertEqual(AskMessages.text(for: ChatFailure(kind: "rate_limited", message: "", retryAfter: 12)), L10n.tr("Rate limited. Try again in \(12) s."))
    }

    // MARK: cancel, reset, idle

    func testCancelSendsControlCancelAndACancelledAnswerKeepsItsText() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        let b = try XCTUnwrap(brains.value.first)
        s.send("Long one")
        b.push(["type": "ask_delta", "id": "a1", "q": "q1", "text": "Partial"])
        await spin()
        s.cancel()
        XCTAssertEqual(b.sent.last, #"{"action":"cancel","type":"control"}"#)
        b.push(["type": "ask_done", "id": "a1", "q": "q1", "model": "claude-sonnet-5-5", "usage": ["input": 400, "output": 2, "cache_read": 0, "cache_write": 0],
                "cost_usd": 0.0009, "ms_first_token": 800, "ms_total": 900, "citations": [], "stop_reason": "cancelled", "cost_estimated": true])
        await spin()
        let a = try XCTUnwrap(s.turns.last?.answer)
        XCTAssertTrue(a.cancelled)
        XCTAssertTrue(a.costEstimated)
        XCTAssertEqual(a.text, "Partial")
        XCTAssertTrue(AskFormat.meta(a).contains("~$0.001"), AskFormat.meta(a))
    }

    func testClearChatSendsResetAndEmptiesTheScreenWithoutTouchingTheFile() async throws {
        let line = #"{"type":"q","id":"q1","t":"2026-10-20T10:00:00Z","text":"Old","model":"claude-sonnet-5-5"}"#
        try Data((line + "\n").utf8).write(to: ChatLog.url(sessionDir: dir))
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        XCTAssertEqual(s.turns.map(\.id), ["q1"], "history from chat.jsonl")
        s.clearChat()
        XCTAssertEqual(s.turns, [])
        XCTAssertEqual(brains.value[0].sent.last, #"{"action":"reset","type":"control"}"#)
        XCTAssertEqual(try String(contentsOf: ChatLog.url(sessionDir: dir), encoding: .utf8), line + "\n", "Swift never writes chat.jsonl")
        s.send("New")
        XCTAssertEqual(s.turns.map(\.id), ["q2"], "ids continue past the hidden pairs")
    }

    func testIdleTimerStopsTheProcessAndTheNextQuestionRestartsIt() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(idle: .milliseconds(80), brains: brains)
        s.open(context())
        XCTAssertEqual(brains.value.count, 1)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(brains.value[0].closed, "stopped after the idle interval")
        XCTAssertFalse(s.isRunning)
        s.send("Back again")
        XCTAssertEqual(brains.value.count, 2, "restarted lazily")
        XCTAssertTrue(brains.value[1].sent[0].contains(#""type":"ask_start""#))
        XCTAssertTrue(brains.value[1].sent[1].contains(#""type":"ask""#))
        XCTAssertEqual(s.turns.last?.question, "Back again")
    }

    func testCloseEndsTheProcess() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        s.close()
        await spin()
        XCTAssertTrue(brains.value[0].closed)
        XCTAssertFalse(s.isOpen)
    }

    func testTheProcessLeavingWhileAQuestionIsOutFailsThatQuestion() async throws {
        let brains = Box<[FakeAskBrain]>([])
        let s = session(brains: brains)
        s.open(context())
        s.send("Hello?")
        brains.value[0].push(["type": "status", "state": "error", "message": "Keychain item service=verse-anthropic missing (exit 44)"])
        await brains.value[0].close()
        await spin()
        XCTAssertEqual(s.turns.last?.failure?.kind, "key_missing")
        XCTAssertFalse(s.isBusy)
    }

    // MARK: availability, settings

    func testAskIsDisabledForTheRunningSessionAndForSessionsWithoutATranscript() throws {
        func session(_ name: String, kind: HomeSession.Kind, transcript: Bool) -> HomeSession {
            HomeSession(name: name, dir: dir, kind: kind, title: name, date: Date(), summaryURL: nil, reportURL: nil,
                        transcriptURL: transcript ? dir.appendingPathComponent("transcript.jsonl") : nil, spend: 0)
        }
        let meeting = session("a", kind: .meeting, transcript: true)
        XCTAssertEqual(AskAvailability.of(meeting, recordingSession: nil, rows: 12), .available)
        XCTAssertEqual(AskAvailability.of(meeting, recordingSession: "a", rows: 12), .recording)
        XCTAssertEqual(AskAvailability.of(meeting, recordingSession: "other", rows: 12), .available, "another session's recording does not block")
        XCTAssertEqual(AskAvailability.of(session("b", kind: .meeting, transcript: false), recordingSession: nil, rows: nil), .noTranscript)
        XCTAssertEqual(AskAvailability.of(meeting, recordingSession: nil, rows: 0), .noTranscript, "an empty transcript")
        XCTAssertEqual(AskAvailability.of(session("c", kind: .call, transcript: true), recordingSession: nil, rows: 3), .available, "adhoc calls")
        XCTAssertEqual(AskAvailability.of(session("d", kind: .practice, transcript: true), recordingSession: nil, rows: 3), .hidden)
        XCTAssertEqual(AskAvailability.of(session("e", kind: .prepared, transcript: false), recordingSession: nil, rows: nil), .hidden)
        XCTAssertFalse(AskAvailability.recording.isAvailable)
        XCTAssertFalse(AskAvailability.noTranscript.isAvailable)
    }

    func testAskModelIsRememberedAppWide() {
        let suite = "dev.example.verse.test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let a = AppSettings(defaults: d)
        XCTAssertEqual(a.askModel, .sonnet, "the default")
        a.askModel = .opus
        XCTAssertEqual(AppSettings(defaults: d).askModel, .opus)
        XCTAssertEqual(d.string(forKey: "askModel"), "opus", "the spec's key")
        XCTAssertEqual(AskModel.displayName(forModelID: "claude-haiku-5-5"), "Haiku")
    }

    // MARK: the real brain process, fake model

    /// `python -m verse_brain.runtime --fake` answers an `ask_start` + `ask`: the protocol both sides speak, end to end. Skipped when
    /// the brain's virtualenv is not there.
    func testTheFakeBrainStreamsIntoThePanelModel() async throws {
        let brainDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("brain", isDirectory: true)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: brainDir.appendingPathComponent(".venv/bin/python").path), "no brain venv")
        try Data("# Prep\n\n(fixture)\n".utf8).write(to: dir.appendingPathComponent("pack.md"))
        let s = AskSession(makeBrain: {
            let b = try BrainProcess(brainDir: brainDir, extraArgs: ["--fake"])
            try b.start()
            return b
        })
        s.open(context())
        s.send("What did they ask?")
        for _ in 0 ..< 200 where s.isBusy { try await Task.sleep(for: .milliseconds(50)) }
        defer { s.close() }
        XCTAssertFalse(s.isBusy, "the fake brain answered")
        let a = try XCTUnwrap(s.turns.last?.answer, "ask_done arrived: \(String(describing: s.turns.last))")
        XCTAssertTrue(a.text.hasPrefix("Fake answer 1"), a.text)
        XCTAssertEqual(a.citations, ["0:05"], "the canned answer cites the first stamp of the grounding block")
        XCTAssertGreaterThan(a.costUSD, 0)
        // The brain wrote chat.jsonl; Swift reads it back the way the panel does.
        let loaded = ChatLog.load(sessionDir: dir)
        XCTAssertEqual(loaded.turns.map(\.id), ["q1"])
        XCTAssertEqual(loaded.turns.first?.answer?.text, a.text)
    }

    /// One real question through the app's own path (AskSession, `BrainProcess`, the brain's Keychain read, `spend.json`) on the brain's
    /// fictional "Dana Reyes" fixture. Off unless `VERSE_LIVE_ASK=1`: it spends real money (about a cent on Sonnet).
    func testLiveQuestionOnTheFictionalFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERSE_LIVE_ASK"] == "1", "live check, off by default")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fx = repo.appendingPathComponent("brain/tests/fixtures/ask", isDirectory: true)
        for f in ["pack.md", "summary.md"] { try FileManager.default.copyItem(at: fx.appendingPathComponent(f), to: dir.appendingPathComponent(f)) }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fx.appendingPathComponent("transcript.json"))) as? [[String: String]])
        let rows = raw.map { AskRow(stamp: $0["stamp"] ?? "", speaker: $0["speaker"] ?? "", text: $0["text"] ?? "") }
        let ctx = AskContext(sessionDir: dir, ownerName: "the owner", title: "Larkspur Health intro", date: Date(), meCore: nil, rows: rows)
        let brainDir = repo.appendingPathComponent("brain", isDirectory: true)
        let s = AskSession(model: .sonnet, makeBrain: {
            let b = try BrainProcess(brainDir: brainDir, extraArgs: [])
            try b.start()
            return b
        })
        s.open(ctx)
        s.send("What did Mara ask me to start with?")
        for _ in 0 ..< 300 where s.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        defer { s.close() }
        let t = try XCTUnwrap(s.turns.last)
        let a = try XCTUnwrap(t.answer, "failure: \(String(describing: t.failure))")
        print("LIVE answer: \(a.text)")
        print("LIVE meta shown: \(AskFormat.meta(a)) | This chat: \(AskFormat.chatCost(s.chatCost)) | usage \(a.usage) | citations \(a.citations)")
        let runs = SpendLedger.runs(sessionDir: dir)
        print("LIVE chat.jsonl answer line: \((try? String(contentsOf: ChatLog.url(sessionDir: dir), encoding: .utf8))?.split(separator: "\n").last.map(String.init) ?? "-")")
        print("LIVE spend.json runs: \(runs.map { "\($0.kind ?? "call") $\($0.costUSD)" })")
        XCTAssertEqual(runs.first?.kind, "ask")
        XCTAssertEqual(runs.first?.costUSD ?? -1, a.costUSD, accuracy: 1e-9, "spend.json equals the cost shown")
    }
}
