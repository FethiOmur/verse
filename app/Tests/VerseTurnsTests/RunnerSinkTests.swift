import Darwin
import Foundation
import os
import VerseAudio
import VerseSpeech
import VerseTurns
import XCTest

/// Collects sink events in order (the sink is called from several threads, always under the runner's output lock).
final class SinkRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var events: [RunnerEvent] = []
    var sink: @Sendable (RunnerEvent) -> Void { { [weak self] e in self?.lock.withLockUnchecked { self?.events.append(e) } } }
    var all: [RunnerEvent] { lock.withLockUnchecked { events } }
}

/// Numbers (times, pids, costs) differ between two runs; everything else must be identical.
private func masked(_ v: JSONValue) -> JSONValue {
    switch v {
    case .number: return .string("#")
    case .array(let a): return .array(a.map(masked))
    case .object(let o): return .object(o.mapValues(masked))
    default: return v
    }
}

final class RunnerSinkTests: XCTestCase {

    private func sampleSession() throws -> TempSession {
        try TempSession(
            bank: [("b001", "Can you tell me about yourself and your background?", ["Walk us through your background."]),
                   ("b002", "What results did Lantern deliver?", ["How did Lantern do?"])],
            facts: ["{\"id\":\"f001\",\"kind\":\"name\",\"text\":\"Lantern project\",\"value\":\"Lantern\",\"sources\":[{\"kind\":\"prep\",\"ref\":\"prep:L13\",\"quote\":\"x\"}]}"])
    }

    /// One `--fake-brain --file` run with a sink: the sink gets exactly the objects verse-run prints (mirrored from the
    /// same run, so timing-dependent lines such as hedges and metrics can't differ), in the same order. Then a separate
    /// stdout run of the `verse-run` binary must show the same timing-independent content (chips, statuses, the text
    /// of every tier per turn).
    func testSinkParity() async throws {
        let session = try sampleSession()
        defer { session.delete() }
        let fixture = try SayFixture.make(voice: "Samantha", text: "Can you tell me about yourself and your background? [[slnc 1500]] What results did Lantern deliver?")
        defer { fixture.delete() }

        // 1. Same run: sink vs the mirrored printed lines.
        let mirrorURL = session.dir.appendingPathComponent("mirror.jsonl")
        FileManager.default.createFile(atPath: mirrorURL.path, contents: nil)
        let mirror = try FileHandle(forWritingTo: mirrorURL)
        let rec = SinkRecorder()
        var o = RunOptions(sessionDir: session.dir)
        o.file = fixture.file
        o.fakeBrain = true
        o.drainSeconds = 3
        o.brainDir = try brainDir()
        o.sink = rec.sink
        o.mirrorOutput = mirror
        let code = await VerseRunner(options: o).run()
        try mirror.close()
        XCTAssertEqual(code, 0)
        let events = rec.all
        XCTAssertEqual(events.last, .ended(exitCode: 0))
        let printed = try String(contentsOf: mirrorURL, encoding: .utf8).split(separator: "\n").map { JSONValue.decodeObject(String($0)) }
        XCTAssertFalse(printed.contains { $0 == nil }, "every printed line is one JSON object")
        // Sink-only extras: the lines sent to the brain (printed only with --echo), the audio level and the end marker.
        let sunk = events.filter {
            if case .outbound = $0 { return false }
            if case .ended = $0 { return false }
            if case .level = $0 { return false }
            return true
        }
        XCTAssertGreaterThan(sunk.count, 20)
        XCTAssertEqual(sunk.count, printed.count, "printed \(printed.count) lines, sink got \(sunk.count)")
        for (i, (e, p)) in zip(sunk, printed).enumerated() where e.object != p {
            XCTFail("line \(i) differs:\n  printed \(p.map { JSONValue.object($0).description } ?? "nil")\n  sink    \(e.object.map { JSONValue.object($0).description } ?? "nil")")
            break
        }
        // The categories are right: brain lines are .brain, chips .chip, the runner's own metrics .metric.
        XCTAssertTrue(sunk.contains { if case .brain(let o) = $0 { return o.type == "delta" }; return false })
        XCTAssertTrue(sunk.contains { if case .chip = $0 { return true }; return false })
        XCTAssertTrue(sunk.contains { if case .metric(let o) = $0 { return o[string: "stage"] == "session_t0" }; return false })
        XCTAssertTrue(events.contains { if case .outbound(let o) = $0 { return o.type == "bank_hit" }; return false },
                      "the overlay needs bank_hit (P tier) from the sink")

        // 2. The stdout path (sink nil) of the binary shows the same timing-independent content.
        let run = try RunningVerseRun(arguments: ["--session", session.dir.path, "--lang", "en", "--file", fixture.file.path,
                                                  "--fake-brain", "--drain", "3", "--brain-dir", try brainDir().path])
        let status = await run.waitForExit(timeout: 90)
        XCTAssertEqual(status, 0, "verse-run stderr: \(run.stderrText)")
        let stdoutObjs = run.output.map { r -> [String: JSONValue] in
            let d = try! JSONSerialization.data(withJSONObject: r.obj)
            return JSONValue.decodeObject(String(decoding: d, as: UTF8.self))!
        }
        XCTAssertEqual(Self.stableContent(stdoutObjs), Self.stableContent(printed.compactMap { $0 }))
    }

    /// What does not depend on timing with the fake brain: fact chips, readiness, and the text each tier wrote per turn.
    private static func stableContent(_ objs: [[String: JSONValue]]) -> [String] {
        var text: [String: String] = [:]
        var out: [String] = []
        for o in objs {
            switch o.type {
            // Topic chips (F4) depend on a wall-clock window and cooldown, so they differ between two runs.
            case "chip" where o[string: "kind"] == "topic": break
            case "chip": out.append("chip \(o[string: "turn_id"] ?? "") \(o[string: "text"] ?? "")")
            case "status": out.append("status \(o[string: "state"] ?? "")")
            case "delta":
                // Selected S and F both answer the turn; only the turn and the text matter, not which call it was.
                let tier = o[string: "tier"] == "D" ? "D" : "fast"
                text["\(o[string: "turn_id"] ?? "") \(tier)", default: ""] += o[string: "text"] ?? ""
            default: break
            }
        }
        return out + text.keys.sorted().map { "\($0): \(text[$0]!)" }
    }

    /// A brain that crashes after `ready` is restarted once and gets the latest question again; a second crash stops
    /// listening and ends the run with `status error`. No brain process is left behind.
    func testSupervisorRestartOnce() async throws {
        let session = try sampleSession()
        defer { session.delete() }
        let fake = try CrashingBrain()
        defer { fake.delete() }
        let fixture = try SayFixture.make(voice: "Samantha", text: "Can you tell me about yourself and your background? [[slnc 6000]] What results did Lantern deliver?")
        defer { fixture.delete() }

        let rec = SinkRecorder()
        var o = RunOptions(sessionDir: session.dir)
        o.file = fixture.file
        o.brainDir = fake.dir
        o.drainSeconds = 3
        o.readyTimeout = 10
        o.sink = rec.sink
        let t0 = Date()
        let code = await VerseRunner(options: o).run()
        let events = rec.all
        XCTAssertEqual(code, 1)
        XCTAssertEqual(events.last, .ended(exitCode: 1))

        let statuses = events.compactMap { e -> String? in
            if case .status(let st, _) = e { return st }
            if case .brain(let o) = e, o.type == "status" { return o[string: "state"] }
            return nil
        }
        XCTAssertEqual(statuses.filter { $0 == "restarting" }.count, 1, "statuses: \(statuses)")
        XCTAssertEqual(statuses.filter { $0 == "ready" }.count, 2, "statuses: \(statuses)")
        XCTAssertEqual(statuses.last, "error", "statuses: \(statuses)")
        XCTAssertLessThan(statuses.firstIndex(of: "restarting")!, statuses.lastIndex(of: "error")!)

        let log = fake.stdinLog
        XCTAssertEqual(fake.invocations, 2, "the brain must be restarted exactly once; stdin log:\n\(log.joined(separator: "\n"))")
        let firstTurns = log.filter { $0.hasPrefix("1 ") && $0.contains("\"type\":\"turn\"") }
        let resent = log.filter { $0.hasPrefix("2 ") && $0.contains("\"type\":\"turn\"") }
        XCTAssertEqual(firstTurns.count, 1)
        XCTAssertEqual(resent.count, 1, "the latest question must be re-sent once to the restarted brain")
        XCTAssertTrue(resent.first?.contains("\"turn_id\":\"r1\"") ?? false, "re-sent: \(resent)")
        XCTAssertTrue(log.contains { $0.hasPrefix("2 ") && $0.contains("\"type\":\"start\"") }, "restart must send start again")
        // Listening stopped at the second crash: the second question (6 s later) never reached a brain.
        XCTAssertFalse(log.contains { $0.contains("Lantern deliver") }, "listening went on after the second crash")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
        for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
    }

    /// Finalized turns of both speakers land in transcript.jsonl, one JSON line each; nothing else (no audio) is
    /// written to the session folder.
    func testTranscriptLines() async throws {
        let session = try sampleSession()
        defer { session.delete() }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: session.dir.path))
        let remoteFx = try SayFixture.make(voice: "Samantha", text: "Can you tell me about yourself and your background? [[slnc 4500]]")
        defer { remoteFx.delete() }
        let meFx = try SayFixture.make(voice: "Mara", text: "[[slnc 4500]] Sure, I build data pipelines and route planners.")
        defer { meFx.delete() }
        let remote = try PCMClip.read(remoteFx.file)
        let me = try PCMClip.read(meFx.file)

        var o = RunOptions(sessionDir: session.dir)
        o.source = .memory(remote: remote, me: me)
        o.fakeBrain = true
        o.drainSeconds = 2
        o.brainDir = try brainDir()
        let rec = SinkRecorder()
        o.sink = rec.sink
        let url = session.dir.appendingPathComponent("transcript.jsonl")
        o.transcriptURL = url
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 0)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let objs = lines.compactMap { JSONValue.decodeObject($0) }
        XCTAssertEqual(objs.count, lines.count, "every transcript line is one JSON object")
        let sentTurns = rec.all.compactMap { e -> String? in
            if case .outbound(let o) = e, o.type == "turn" { return o[string: "turn_id"] }
            return nil
        }
        XCTAssertEqual(objs.map { $0[string: "turn_id"] ?? "" }, sentTurns, "one line per finalized turn, in order")
        let speakers = Set(objs.compactMap { $0[string: "speaker"] })
        XCTAssertEqual(speakers, ["remote", "me"], "both speakers: \(lines)")
        for obj in objs {
            // The original keys are unchanged; `run_start` and `t_wall` (F1) are the only additions.
            XCTAssertEqual(Set(obj.keys), ["turn_id", "speaker", "text", "addressee", "kind", "t_audio_end", "lang", "run_start", "t_wall"])
            guard case .number(let runStart)? = obj["run_start"], case .number(let tWall)? = obj["t_wall"], case .number(let end)? = obj["t_audio_end"] else {
                XCTFail("run_start, t_wall and t_audio_end are numbers: \(obj)"); continue
            }
            XCTAssertGreaterThan(runStart, 1_600_000_000, "run_start is Unix seconds")
            XCTAssertEqual(tWall, runStart + end, accuracy: 0.0015, "t_wall = run_start + t_audio_end")
            XCTAssertEqual(runStart, (runStart * 1000).rounded() / 1000, accuracy: 1e-6, "3 decimals")
        }
        let starts = Set(objs.compactMap { o -> Double? in if case .number(let n)? = o["run_start"] { return n }; return nil })
        XCTAssertEqual(starts.count, 1, "one run, one run_start")
        XCTAssertTrue(objs.contains { ($0[string: "text"] ?? "").lowercased().contains("background") })
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: session.dir.path))
        // The brain writes its final summary.md at stop (F2) and its text-only decision log events.jsonl; the runner adds only the transcript.
        XCTAssertTrue(after.subtracting(before).isSubset(of: ["transcript.jsonl", "summary.md", "events.jsonl"]), "new files: \(after.subtracting(before))")
        let audioExt: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3", "flac", "pcm"]
        XCTAssertFalse(after.contains { audioExt.contains(($0 as NSString).pathExtension.lowercased()) })
    }
}

/// A fake `brain/` whose "python" is a shell script: it answers `start` with `ready` and exits with status 1 on the
/// first `turn` (a crash). It counts its invocations and logs every stdin line with the invocation number.
struct CrashingBrain {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-fakebrain-\(UUID().uuidString)", isDirectory: true)
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
          case "$line" in
            *'"type":"start"'*) echo '{"type":"status","state":"ready","message":""}' ;;
            *'"type":"turn"'*) exit 1 ;;
            *'"action":"stop"'*) exit 0 ;;
          esac
        done
        """
        let py = dir.appendingPathComponent(".venv/bin/python")
        try script.write(to: py, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
    }

    var invocations: Int { Int((try? String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
    var stdinLog: [String] { ((try? String(contentsOf: dir.appendingPathComponent("stdin.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var pids: [Int32] { ((try? String(contentsOf: dir.appendingPathComponent("pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) } }

    func delete() { try? FileManager.default.removeItem(at: dir) }
}
