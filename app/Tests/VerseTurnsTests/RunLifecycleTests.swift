import Foundation
import os
import VerseAudio
import VerseSpeech
@testable import VerseTurns
import XCTest

/// A fake `brain/` whose "python" is a shell script, for the run's lifecycle: what it does on `start` is given (answer `ready` at
/// once, after a delay without blocking its input, or fail fatally), it exits with status 1 on the first `turn` that contains
/// `crashWord` (first invocation only) and on `control stop` with 0. Every stdin line is logged with the invocation number; a
/// delayed `ready` also logs a `{"type":"_ready"}` marker line at the moment it is sent.
struct LifecycleBrain {
    enum OnStart {
        case ready
        /// `ready` after this many seconds; the script keeps reading its input meanwhile (like the brain's pre-warm task).
        case readyAfter(Double)
        /// After this many seconds a fatal `status error` (`reason: no_api_key`), then exit 2.
        case fatal(after: Double)
    }

    let dir: URL

    init(onStart: OnStart = .ready, crashWord: String? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-lifebrain-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("verse_brain"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        let ready = #"echo '{"type":"status","state":"ready","message":""}'"#
        let start: String
        switch onStart {
        case .ready: start = ready
        case .readyAfter(let s):
            start = #"( sleep \#(s); echo "$n {\"type\":\"_ready\"}" >> "$D/stdin.log"; \#(ready) ) & BG=$!"#
        case .fatal(let s):
            start = #"sleep \#(s); echo '{"type":"status","state":"error","message":"No API key: test","reason":"no_api_key"}'; exit 2"#
        }
        let crash = crashWord ?? "\u{1}never\u{1}"
        let script = """
        #!/bin/bash
        D="$(cd "$(dirname "$0")/../.." && pwd)"
        n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$D/count"
        echo "$$" >> "$D/pids"
        BG=
        while IFS= read -r line; do
          echo "$n $line" >> "$D/stdin.log"
          if [[ "$n" == 1 && "$line" == *'"type":"turn"'* && "$line" == *\(crash)* ]]; then exit 1; fi
          case "$line" in
            *'"type":"start"'*) \(start) ;;
            *'"action":"stop"'*) if [[ -n "$BG" ]]; then pkill -P "$BG" 2>/dev/null; kill "$BG" 2>/dev/null; fi; exit 0 ;;
          esac
        done
        """
        let py = dir.appendingPathComponent(".venv/bin/python")
        try script.write(to: py, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
    }

    var invocations: Int { Int((try? String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
    var stdin: [(n: Int, obj: [String: JSONValue])] {
        ((try? String(contentsOf: dir.appendingPathComponent("stdin.log"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { l in
            let parts = l.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]), let o = JSONValue.decodeObject(String(parts[1])) else { return nil }
            return (n, o)
        }
    }
    func lines(_ n: Int) -> [[String: JSONValue]] { stdin.filter { $0.n == n }.map(\.obj) }
    var pids: [Int32] { ((try? String(contentsOf: dir.appendingPathComponent("pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) } }

    func delete() { try? FileManager.default.removeItem(at: dir) }
}

/// A capture source whose start fails (a device taken, a permission revoked between prepare and start).
final class FailingStartSource: AudioCaptureSource, @unchecked Sendable {
    var routeDescription: String { "failing stand-in" }
    func targetIsProducingOutput() -> Bool? { false }
    func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        throw ListenError.sourceFailed("device taken")
    }
    func stop() {}
}

private func turnIDs(_ turns: [JSONValue]?) -> [String] {
    (turns ?? []).compactMap { if case .object(let o) = $0 { return o[string: "turn_id"] }; return nil }
}

private func transcript(_ url: URL) -> [(id: String, text: String)] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { l in
        guard let o = JSONValue.decodeObject(String(l)), let id = o[string: "turn_id"] else { return nil }
        return (id, o[string: "text"] ?? "")
    }
}

private func metrics(_ events: [RunnerEvent], _ stage: String) -> [[String: JSONValue]] {
    events.compactMap { if case .metric(let m) = $0, m[string: "stage"] == stage { return m }; return nil }
}

/// The run's lifecycle around the brain: listening does not wait for it, a fatal start still ends the session, Stop during a
/// restart backoff or the warm-up still gets the final merge the call so far, and a failed listen swap goes back to the previous
/// configuration instead of ending the run.
final class RunLifecycleTests: XCTestCase {

    private func liveOptions(_ session: TempSession, rig: SwapRig, brain: URL) -> RunOptions {
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = rig.environment()
        o.source = nil
        o.brainDir = brain
        o.drainSeconds = 1
        o.quietSeconds = 0.5
        o.readyTimeout = 20
        o.transcriptURL = session.dir.appendingPathComponent("transcript.jsonl")
        return o
    }

    // MARK: 1. listening starts at once; the warmed-up brain gets what was heard

    /// The brain takes 7 s to say `ready`. Listening must start at once (before, the runner waited for `ready`, up to 45 s, and
    /// that speech was lost). When it is ready the brain gets the turns heard meanwhile as `history`, the newest question live
    /// (it still gets a card), and later turns go live as usual.
    func testListeningStartsAtOnceAndTheWarmedUpBrainGetsWhatWasHeard() async throws {
        let fake = try LifecycleBrain(onStart: .readyAfter(7))
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)
                                     + SwapScenario.utterance("what is the deadline for the launch", from: 3.0)
                                     + SwapScenario.utterance("and who owns the budget for the launch", from: 10.0)]
        var o = liveOptions(session, rig: rig, brain: fake.dir)
        o.seconds = 13
        let rec = SinkRecorder()
        o.sink = rec.sink
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 0)
        let events = rec.all

        // Listening began before the brain was ready, and the capsule was told the brain is still warming.
        let t0 = events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }
        let ready = events.firstIndex { if case .brain(let b) = $0 { return b.type == "status" && b[string: "state"] == "ready" }; return false }
        guard let t0, let ready else { return XCTFail("no session_t0 or no ready: \(events)") }
        XCTAssertLessThan(t0, ready, "listening waited for the brain")
        XCTAssertTrue(events.contains(.status(state: "warming", message: VerseRunner.warmingWhileListening)))

        let heard = transcript(o.transcriptURL!)
        func id(_ word: String) -> String? { heard.first { $0.text.contains(word) }?.id }
        guard let thanks = id("thanks"), let deadline = id("deadline"), let budget = id("budget") else {
            return XCTFail("the scripted turns were not all finalized: \(heard)")
        }
        // What the brain read, in order: start, (its ready), the turns heard meanwhile as history, the newest question live,
        // then the next question live.
        let lines = fake.lines(1)
        XCTAssertEqual(lines.first?.type, "start")
        guard let readyAt = lines.firstIndex(where: { $0.type == "_ready" }) else { return XCTFail("no ready marker: \(lines.map(\.type))") }
        let beforeReady = lines[..<readyAt].filter { $0.type == "turn" || $0.type == "partial" || $0.type == "history" }
        XCTAssertTrue(beforeReady.isEmpty, "a line went to the brain before it was ready: \(beforeReady)")
        let histories = lines.enumerated().filter { $0.element.type == "history" }
        XCTAssertEqual(histories.count, 1, "\(lines.map(\.type))")
        XCTAssertEqual(turnIDs(histories.first?.element["turns"]?.array), [thanks], "the turns before the newest question")
        let live = lines.enumerated().filter { $0.element.type == "turn" }
        XCTAssertEqual(live.filter { $0.element[string: "turn_id"] == deadline }.count, 1,
                       "the question heard during the warm-up goes live once: \(lines.map { JSONValue.object($0).description })")
        if let h = histories.first, let q = live.first(where: { $0.element[string: "turn_id"] == deadline }) {
            XCTAssertLessThan(h.offset, q.offset)
        }
        XCTAssertTrue(live.contains { $0.element[string: "turn_id"] == budget }, "a later question goes live")
        let replay = metrics(events, "history_replay")
        XCTAssertEqual(replay.first?[string: "reason"], "warm_start")
        // The front end followed the call during the warm-up (the held lines were shown as heard).
        XCTAssertTrue(events.contains { if case .outbound(let x) = $0 { return x.type == "turn" && x[string: "turn_id"] == thanks }; return false })
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    /// A fatal start (here no API key, 2.5 s in) still ends the session with the brain's message, though listening already ran:
    /// what was heard until then stays in transcript.jsonl, the run ends with 1, and no brain is left.
    func testAFatalStartEndsTheSessionAndKeepsWhatWasHeard() async throws {
        let fake = try LifecycleBrain(onStart: .fatal(after: 2.5))
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)]
        var o = liveOptions(session, rig: rig, brain: fake.dir)
        o.seconds = 30
        let rec = SinkRecorder()
        o.sink = rec.sink
        let started = Date()
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "the session must end on the fatal start, not at the time limit")
        XCTAssertTrue(rec.all.contains { if case .brain(let b) = $0 { return b[string: "reason"] == "no_api_key" }; return false },
                      "the brain's message reaches the front end")
        XCTAssertTrue(transcript(o.transcriptURL!).contains { $0.text.contains("thanks") }, "what was heard is kept")
        XCTAssertFalse(fake.lines(1).contains { $0.type == "history" || $0.type == "turn" })
        XCTAssertEqual(fake.invocations, 1, "a fatal start is not restarted")
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    /// The run ends (time limit) while the brain is still warming up: it gets the call so far as `history` before `control stop`,
    /// so its final merge covers it (the brain reads both during its pre-warm, review L3). No turn goes to it live.
    func testABrainStillWarmingAtTheEndGetsTheCallForItsMerge() async throws {
        let fake = try LifecycleBrain(onStart: .readyAfter(60))
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)
                                     + SwapScenario.utterance("what is the deadline for the launch", from: 3.0)]
        var o = liveOptions(session, rig: rig, brain: fake.dir)
        o.seconds = 6
        o.readyTimeout = 120
        let rec = SinkRecorder()
        o.sink = rec.sink
        let started = Date()
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let heard = transcript(o.transcriptURL!).map(\.id)
        let lines = fake.lines(1)
        XCTAssertEqual(lines.map(\.type), ["start", "history", "control"], "\(lines)")
        XCTAssertEqual(turnIDs(lines.first { $0.type == "history" }?["turns"]?.array), heard, "every finalized turn, in order")
        XCTAssertEqual(lines.last?[string: "action"], "stop")
        XCTAssertEqual(metrics(rec.all, "history_replay").first?[string: "reason"], "stop_while_warming")
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    // MARK: 3. Stop during the restart backoff

    /// The brain crashes on the question and the restart waits out a 30 s backoff. Stop in that window used to end the run
    /// without a summary (no brain was running to write it). Now a brain is started for the merge: `start`, the call so far as
    /// `history`, `control stop`, within the stop budget.
    func testStopDuringTheRestartBackoffStillGetsTheFinalMerge() async throws {
        let fake = try LifecycleBrain(onStart: .ready, crashWord: "deadline")
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [
            .remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)
                + SwapScenario.utterance("what is the deadline for the launch", from: 3.0),
            .me: SwapScenario.utterance("it is the end of march", from: 6.0),
        ]
        var o = liveOptions(session, rig: rig, brain: fake.dir)
        o.waitForBrainBeforeListening = true    // the first brain must be live for the question it crashes on
        o.seconds = 60
        o.restartBackoffSeconds = 30
        let rec = SinkRecorder()
        o.sink = rec.sink
        let runner = VerseRunner(options: o)
        let task = Task { await runner.run() }
        let t0 = Date()
        while !rec.all.contains(.status(state: "restarting", message: "brain process ended unexpectedly; restarting (1/3)")) {
            if Date().timeIntervalSince(t0) > 30 { runner.requestStop(); _ = await task.value; return XCTFail("the brain never crashed") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(3.5))   // the owner's answer is finalized while the restart waits
        let stopAt = Date()
        runner.requestStop()
        let code = await task.value
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(stopAt), 10, "the stop must not wait out the backoff")
        XCTAssertEqual(fake.invocations, 2, "one brain for the merge")
        let second = fake.lines(2)
        XCTAssertEqual(second.map(\.type), ["start", "history", "control"], "\(second)")
        let heard = transcript(o.transcriptURL!)
        XCTAssertEqual(turnIDs(second.first { $0.type == "history" }?["turns"]?.array), heard.map(\.id), "the whole call, in order")
        XCTAssertTrue(heard.contains { $0.text.contains("march") }, "the answer given during the backoff: \(heard)")
        XCTAssertEqual(second.last?[string: "action"], "stop")
        XCTAssertEqual(metrics(rec.all, "history_replay").last?[string: "reason"], "stop_while_restarting")
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    // MARK: 4. a brain given up on

    func testTheEndNoteOfARunWithAnswersOff() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)   // 08:00 UTC
        let n = RunEndNote.answersOff(since: at, summaryWritten: false, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(n.title, "Call ended · answers were off for part of it")
        XCTAssertTrue(n.detail.contains("08:00") && n.detail.contains("transcript of the whole call is complete"), n.detail)
        XCTAssertTrue(n.detail.hasSuffix("No summary could be written."))
        XCTAssertTrue(RunEndNote.answersOff(since: at, summaryWritten: true).detail.hasSuffix("The summary was written."))
    }

    // MARK: 5. a failed listen swap (review M6)

    /// The new pipeline (French) cannot start: its capture source throws between prepare and start. The run used to end there.
    /// Now the previous configuration (English, meeting) is started again: the swap is reported as not applied, the call goes
    /// on, a later question is still heard, and the brain is never told the language changed.
    func testAFailedSwapRestartsThePreviousConfiguration() async throws {
        let fake = try LifecycleBrain(onStart: .ready)
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)
                                     + SwapScenario.utterance("what is the deadline for the launch", from: 4.5)]
        var env = rig.environment()
        let base = env.makeRemoteSource
        env.makeRemoteSource = { cfg -> (any AudioCaptureSource)? in
            if cfg.lang == "fr" { return FailingStartSource() }
            return try base(cfg)
        }
        var o = liveOptions(session, rig: rig, brain: fake.dir)
        o.listenEnvironment = env
        o.waitForBrainBeforeListening = true
        o.seconds = 60
        let rec = SinkRecorder()
        o.sink = rec.sink
        let runner = VerseRunner(options: o)
        let task = Task { await runner.run() }
        let t0 = Date()
        while !rec.all.contains(where: { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }) {
            if Date().timeIntervalSince(t0) > 30 { runner.requestStop(); _ = await task.value; return XCTFail("never listened") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(2.5))
        let applied = await runner.switchListening(lang: "fr")
        try await Task.sleep(for: .seconds(7))
        runner.requestStop()
        let code = await task.value

        XCTAssertFalse(applied, "the swap did not happen")
        XCTAssertEqual(code, 0, "a failed swap must not end the run")
        let events = rec.all
        XCTAssertTrue(events.contains { if case .issue(let c, let m, _) = $0 { return c == "swap_failed" && m.contains("still listening in meeting / en") }; return false })
        XCTAssertEqual(metrics(events, "listen_swap_reverted").first?[string: "lang"], "en")
        XCTAssertTrue(metrics(events, "listen_swap").isEmpty)
        XCTAssertFalse(events.contains(where: { if case .status(let st, _) = $0 { return st == "listen_failed" }; return false }))
        XCTAssertTrue(transcript(o.transcriptURL!).contains { $0.text.contains("deadline") }, "the call went on in English after the failed swap")
        XCTAssertFalse(fake.lines(1).contains { $0[string: "action"] == "lang" }, "the brain was told a language that never came")
        let builtFrench = rig.built.contains { $0.lang == "fr" }
        XCTAssertTrue(builtFrench, "the French pipeline was prepared")
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    // MARK: 6. the channel of an issue

    func testIssueLinesNameTheirChannel() {
        let me = VerseRunner.issueObject(.speechFailed(.me, "engine gone"))
        XCTAssertEqual(me["channel"] as? String, "me")
        XCTAssertEqual(me["code"] as? String, "speech_failed")
        XCTAssertEqual(VerseRunner.issueObject(.captureRecovered(.remote, "device"))["channel"] as? String, "remote")
        XCTAssertNil(VerseRunner.issueObject(.sourceFailed("x"))["channel"], "an issue about no one channel has none")
    }

    /// The printed issue line reaches the sink with its channel, and `object` prints it back.
    func testIssueEventsCarryTheirChannel() {
        let line = VerseRunner.issueObject(.captureFailed(.me, "no input device"))
        let o = JSONValue.decodeObject(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))!
        let e = RunnerEvent.classify(o, fromBrain: false)
        XCTAssertEqual(e, .issue(code: "capture_failed", message: ListenError.captureFailed(.me, "no input device").description, channel: .me))
        XCTAssertEqual(e.object?["channel"], .string("me"))
        let none = RunnerEvent.classify(["type": .string("issue"), "code": .string("swap_failed"), "message": .string("x")], fromBrain: false)
        XCTAssertEqual(none, .issue(code: "swap_failed", message: "x", channel: nil), "a line without a channel (or an older runner's)")
        XCTAssertNil(none.object?["channel"])
        let bogus = RunnerEvent.classify(["type": .string("issue"), "code": .string("c"), "message": .string("m"),
                                          "channel": .string("left")], fromBrain: false)
        XCTAssertEqual(bogus, .issue(code: "c", message: "m", channel: nil), "an unknown channel is no channel")
    }
}
