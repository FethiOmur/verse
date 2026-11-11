import Foundation
@testable import VerseTurns
import XCTest

/// A fake `brain/` whose "python" is a shell script: it answers `start` with `ready`, exits with status 1 on the first `turn`
/// whose text contains `crashWord` (first invocation only: the restarted brain serves), and logs every stdin line with the
/// invocation number.
struct ReplayBrain {
    let dir: URL

    init(crashWord: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-replaybrain-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("verse_brain"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        D="$(cd "$(dirname "$0")/../.." && pwd)"
        n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$D/count"
        echo "$$" >> "$D/pids"
        while IFS= read -r line; do
          echo "$n $line" >> "$D/stdin.log"
          if [[ "$n" == 1 && "$line" == *'"type":"turn"'* && "$line" == *\(crashWord)* ]]; then exit 1; fi
          case "$line" in
            *'"type":"start"'*) echo '{"type":"status","state":"ready","message":""}' ;;
            *'"action":"stop"'*) exit 0 ;;
          esac
        done
        """
        let py = dir.appendingPathComponent(".venv/bin/python")
        try script.write(to: py, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
    }

    var invocations: Int { Int((try? String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
    /// (invocation, decoded line) for every stdin line, in order.
    var stdin: [(n: Int, obj: [String: JSONValue])] {
        ((try? String(contentsOf: dir.appendingPathComponent("stdin.log"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { l in
            let parts = l.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]), let o = JSONValue.decodeObject(String(parts[1])) else { return nil }
            return (n, o)
        }
    }
    var pids: [Int32] { ((try? String(contentsOf: dir.appendingPathComponent("pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) } }

    func delete() { try? FileManager.default.removeItem(at: dir) }
}

private func ids(_ turns: [JSONValue]?) -> [String] {
    (turns ?? []).compactMap { if case .object(let o) = $0 { return o[string: "turn_id"] }; return nil }
}

/// The brain lifecycle across a crash and across Quit: a restarted brain gets the call so far (`history`), and Quit during a call
/// waits for the final summary like Stop.
final class BrainLifecycleTests: XCTestCase {

    // MARK: history replay: the wire

    private func h(_ id: String, _ speaker: Speaker = .remote, _ text: String = "words", kind: TurnKind = .statement) -> HistoryTurn {
        HistoryTurn(turnID: id, speaker: speaker, text: text, addressee: .unknown, kind: kind, tAudioEnd: 1.2345)
    }

    func testTheHistoryLineIsTheWireFormatTheBrainValidates() {
        let line = BrainCommand.history([
            HistoryTurn(turnID: "r1", speaker: .remote, text: "what is the deadline?", addressee: .me, kind: .question, tAudioEnd: 4.25, lang: "en"),
            HistoryTurn(turnID: "m2", speaker: .me, text: "end of March", addressee: .unknown, kind: .statement, tAudioEnd: 7.5),
        ]).jsonLine()
        XCTAssertEqual(line, #"{"turns":[{"addressee":"me","kind":"question","lang":"en","speaker":"remote","t_audio_end":4.25,"text":"what is the deadline?","turn_id":"r1"},{"addressee":"unknown","kind":"statement","speaker":"me","t_audio_end":7.5,"text":"end of March","turn_id":"m2"}],"type":"history"}"#)
    }

    func testTheHistoryKeepsTheNewestTurnsWithinTheBounds() {
        let many = (0..<(HistoryTurn.maxTurns + 7)).map { h("t\($0)") }
        let kept = HistoryTurn.bounded(many)
        XCTAssertEqual(kept.count, HistoryTurn.maxTurns)
        XCTAssertEqual(kept.first?.turnID, "t7")
        XCTAssertEqual(kept.last?.turnID, "t\(HistoryTurn.maxTurns + 6)")
        let quarter = String(repeating: "y", count: HistoryTurn.maxChars / 4)
        XCTAssertEqual(HistoryTurn.bounded((0..<6).map { h("l\($0)", .me, quarter) }).map(\.turnID), ["l2", "l3", "l4", "l5"])
        let line = JSONValue.decodeObject(BrainCommand.history(many).jsonLine())
        XCTAssertEqual(line?["turns"]?.array?.count, HistoryTurn.maxTurns, "the line itself is bounded")
    }

    func testTheReplayIsSplitAroundTheReSentQuestion() {
        let hist = [h("r1"), h("m2", .me), h("r3", kind: .question), h("m4", .me)]
        let q = OutboundEvent.turn(turnID: "r3", speaker: .remote, text: "words", addressee: .me, tAudioEnd: 1, kind: .question)
        var plan = VerseRunner.replayPlan(history: hist, resend: q)
        XCTAssertEqual(plan.before.map(\.turnID), ["r1", "m2"])
        XCTAssertEqual(plan.after.map(\.turnID), ["m4"])
        plan = VerseRunner.replayPlan(history: hist, resend: nil)
        XCTAssertEqual(plan.before.map(\.turnID), ["r1", "m2", "r3", "m4"])
        XCTAssertEqual(plan.after, [])
        let other = OutboundEvent.turn(turnID: "r9", speaker: .remote, text: "x", addressee: .me, tAudioEnd: 1, kind: .question)
        XCTAssertEqual(VerseRunner.replayPlan(history: hist, resend: other).before.count, 4, "a question not among them takes nothing out")
    }

    // MARK: history replay: the real runner across a crash

    /// The first brain crashes on the remote question "… deadline …". While the restart waits out its backoff the owner answers
    /// (a turn nobody can be sent live). The restarted brain must get, in this order: `start`, the turns before the question as
    /// `history`, the question once as a live `turn` (it is answered again), the owner's answer as `history`, then the live
    /// lines of the next question. Every finalized turn reaches the restarted brain exactly once.
    func testARestartedBrainGetsTheCallSoFarWithoutLossOrDuplication() async throws {
        let fake = try ReplayBrain(crashWord: "deadline")
        defer { fake.delete() }
        let session = try TempSession()
        defer { session.delete() }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [
            .remote: SwapScenario.utterance("thanks for joining today everyone", from: 0.3)
                + SwapScenario.utterance("what is the deadline for the launch", from: 3.0)
                + SwapScenario.utterance("and who owns the budget for the launch", from: 12.5),
            .me: SwapScenario.utterance("happy to be here", from: 1.8)
                + SwapScenario.utterance("it is the end of march", from: 6.0),
        ]
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = rig.environment()
        o.brainDir = fake.dir
        o.seconds = 17
        o.drainSeconds = 1
        o.quietSeconds = 0.5
        o.readyTimeout = 10
        o.restartBackoffSeconds = 5
        let rec = SinkRecorder()
        o.sink = rec.sink
        let transcriptURL = session.dir.appendingPathComponent("transcript.jsonl")
        o.transcriptURL = transcriptURL
        _ = await VerseRunner(options: o).run()

        let transcript = ((try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { JSONValue.decodeObject(String($0)) }
        let all = transcript.compactMap { $0[string: "turn_id"] }
        let textOf = Dictionary(uniqueKeysWithValues: transcript.compactMap { t in t[string: "turn_id"].map { ($0, t[string: "text"] ?? "") } })
        func id(containing word: String) -> String? { all.first { textOf[$0]?.contains(word) ?? false } }
        guard let q = id(containing: "deadline"), let answer = id(containing: "march"), let budget = id(containing: "budget") else {
            return XCTFail("the scripted turns were not all finalized: \(textOf)")
        }
        XCTAssertEqual(fake.invocations, 2, "one crash, one restart")

        let second = fake.stdin.filter { $0.n == 2 }.map(\.obj)
        XCTAssertEqual(second.first?.type, "start")
        let historyLines = second.enumerated().filter { $0.element.type == "history" }
        XCTAssertEqual(historyLines.count, 2, "before and after the re-sent question: \(second.map(\.type))")
        let liveTurns = second.enumerated().filter { $0.element.type == "turn" }
        let resent = liveTurns.filter { $0.element[string: "turn_id"] == q }
        XCTAssertEqual(resent.count, 1, "the question the first brain crashed on is answered again, once")
        guard historyLines.count == 2, let r = resent.first else { return }
        let before = ids(historyLines[0].element["turns"]?.array)
        let after = ids(historyLines[1].element["turns"]?.array)
        XCTAssertLessThan(historyLines[0].offset, r.offset)
        XCTAssertLessThan(r.offset, historyLines[1].offset)
        XCTAssertEqual(before, Array(all.prefix { $0 != q }), "every turn before the question, in order")
        XCTAssertTrue(after.contains(answer), "the answer given while the brain was restarting is replayed: \(after)")
        XCTAssertFalse(before.contains(q) || after.contains(q), "the re-sent question is not replayed as well")
        // Everything live comes after the replay.
        let firstLive = second.enumerated().first { ($0.element.type == "partial" || $0.element.type == "turn") && $0.element[string: "turn_id"] != q }
        XCTAssertGreaterThan(firstLive?.offset ?? .max, historyLines[1].offset, "a live line went out before the replay")
        XCTAssertTrue(liveTurns.contains { $0.element[string: "turn_id"] == budget }, "the next question goes live")
        // No loss, no duplicates: replayed + live turns of the restarted brain = the call's finalized turns, each once.
        let reached = before + liveTurns.compactMap { $0.element[string: "turn_id"] } + after
        XCTAssertEqual(reached.count, Set(reached).count, "a turn reached the restarted brain twice: \(reached)")
        XCTAssertEqual(Set(reached), Set(all), "every finalized turn reaches the restarted brain")
        // The front end is not shown the replayed turns again (only the re-sent question goes out a second time, as before).
        let outboundTurns = rec.all.compactMap { e -> String? in if case .outbound(let o) = e, o.type == "turn" { return o[string: "turn_id"] }; return nil }
        XCTAssertEqual(outboundTurns.filter { $0 != q }.count, Set(outboundTurns.filter { $0 != q }).count)
        XCTAssertTrue(rec.all.contains { if case .metric(let m) = $0 { return m[string: "stage"] == "history_replay" }; return false })
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    // MARK: Quit

    func testQuitWithoutACallIsInstant() {
        var gate = QuitGate()
        XCTAssertEqual(gate.quit(sessionActive: false), .now)
        XCTAssertFalse(gate.waiting)
    }

    func testQuitDuringACallWaitsAsLongAsStopAndASecondQuitForces() {
        var gate = QuitGate()
        guard case .graceful(let budget) = gate.quit(sessionActive: true) else { return XCTFail("a call must end gracefully") }
        // Stop's grace (the brain's 45 s merge timeout plus a margin) and the SIGTERM/SIGKILL escalation after it must fit.
        XCTAssertGreaterThanOrEqual(budget, RunOptions(sessionDir: URL(fileURLWithPath: "/")).stopGraceSeconds + 3.5)
        XCTAssertTrue(gate.waiting)
        XCTAssertEqual(gate.quit(sessionActive: true), .force, "the second Quit is the escape hatch")
        XCTAssertEqual(gate.quit(sessionActive: false), .force)
    }
}
