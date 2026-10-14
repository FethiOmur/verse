import Darwin
import Foundation
import os
import VerseSpeech
import VerseTurns
import XCTest

/// Lines collected from an AsyncStream in the background, with their arrival time.
final class LineCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var items: [(t: Date, line: String)] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<String>) {
        task = Task { [weak self] in
            for await l in stream { self?.lock.withLockUnchecked { self?.items.append((Date(), l)) } }
        }
    }

    var all: [(t: Date, line: String)] { lock.withLockUnchecked { items } }

    func json() -> [[String: Any]] {
        all.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.line.utf8))) as? [String: Any] }
    }

    func waitFor(timeout: TimeInterval, _ predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let hit = json().first(where: predicate) { return hit }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func cancel() { task?.cancel() }
}

func processIsGone(_ pid: Int32) -> Bool {
    // kill(pid, 0) fails with ESRCH once the process is gone (a zombie we still own would still answer, but
    // Foundation reaps its children).
    kill(pid, 0) != 0 && errno == ESRCH
}

final class BrainWireTests: XCTestCase {

    /// Every event the engine produces for the brain parses with the brain's own `parse_line`; chips are not brain
    /// messages and are rejected.
    func testWireFormat() throws {
        let events: [OutboundEvent] = [
            .partial(turnID: "r1", speaker: .remote, text: "Can you walk me through \"Lantern\" — übung", cue: true, tAudioEnd: 12.346),
            .turn(turnID: "r1", speaker: .remote, text: "Can you walk me through it", addressee: .me, tAudioEnd: 13.0),
            .turn(turnID: "m1", speaker: .me, text: "Sure", addressee: .unknown, tAudioEnd: 14.2),
            .turn(turnID: "r2", speaker: .remote, text: "Marco, can you", addressee: .other, tAudioEnd: 15),
            .bankHit(turnID: "r1", bankID: "b004", score: 0.712),
        ]
        var lines = events.map { $0.jsonLine() }
        lines.append(BrainCommand.start(sessionDir: "/tmp/x y", lang: "en").jsonLine())
        lines.append(BrainCommand.summarize.jsonLine())
        lines.append(BrainCommand.stop.jsonLine())
        let chip = OutboundEvent.chip(turnID: "r1", kind: "number", text: "42K", sourceRef: "prep:L9", factID: "f001")
        lines.append(chip.jsonLine())

        let script = """
        import sys, json
        from verse_brain.runtime.protocol import parse_line
        out = []
        for line in sys.stdin:
            try:
                m = parse_line(line)
                out.append({"ok": True, "msg": m})
            except ValueError as e:
                out.append({"ok": False, "err": str(e)})
        print(json.dumps(out))
        """
        let result = try runBrainPython(script, stdin: lines.joined(separator: "\n") + "\n")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]], result)
        XCTAssertEqual(parsed.count, lines.count)
        for (i, p) in parsed.enumerated().dropLast() {
            XCTAssertEqual(p["ok"] as? Bool, true, "line \(i) rejected: \(lines[i]) -> \(p)")
        }
        XCTAssertEqual(parsed.last?["ok"] as? Bool, false, "chip must not be accepted as a brain message")

        // Exact field names and types, as the plan's protocol lists them.
        let msgs = parsed.dropLast().compactMap { $0["msg"] as? [String: Any] }
        XCTAssertEqual(Set(msgs[0].keys), ["type", "turn_id", "speaker", "text", "cue", "t_audio_end"])
        XCTAssertEqual(msgs[0]["cue"] as? Bool, true)
        XCTAssertEqual(msgs[0]["t_audio_end"] as? Double, 12.346)
        XCTAssertEqual(msgs[0]["text"] as? String, "Can you walk me through \"Lantern\" — übung")
        XCTAssertEqual(Set(msgs[1].keys), ["type", "turn_id", "speaker", "text", "addressee", "t_audio_end"])
        XCTAssertEqual(msgs[1]["addressee"] as? String, "me")
        XCTAssertEqual(msgs[2]["speaker"] as? String, "me")
        XCTAssertEqual(msgs[3]["addressee"] as? String, "other")
        XCTAssertEqual(Set(msgs[4].keys), ["type", "turn_id", "bank_id", "score"])
        XCTAssertEqual(msgs[4]["bank_id"] as? String, "b004")
        XCTAssertEqual(msgs[5]["type"] as? String, "start")
        XCTAssertEqual(msgs[5]["session_dir"] as? String, "/tmp/x y")
        XCTAssertEqual(msgs[6]["action"] as? String, "summarize")
        XCTAssertEqual(msgs[7]["action"] as? String, "stop")
        // and they round-trip through Codable
        for e in events { XCTAssertEqual(try JSONDecoder().decode(OutboundEvent.self, from: Data(e.jsonLine().utf8)), e) }
        XCTAssertTrue(events.allSatisfy(\.isForBrain))
        XCTAssertFalse(chip.isForBrain)
    }

    /// The brain (canned replies, no network) really takes our lines and answers: start -> ready -> turn -> F deltas.
    func testBrainFakeRoundTripAndShutdown() async throws {
        let s = try TempSession()
        defer { s.delete() }
        let brain = try BrainProcess(brainDir: try brainDir(), extraArgs: ["--fake"])
        try brain.start()
        let pid = brain.pid
        let lines = LineCollector(brain.lines)
        defer { lines.cancel() }

        brain.send(BrainCommand.start(sessionDir: s.dir.path, lang: "en").jsonLine())
        let ready = await lines.waitFor(timeout: 15) { $0["type"] as? String == "status" && $0["state"] as? String == "ready" }
        XCTAssertNotNil(ready, "brain never reported ready: \(lines.all.map(\.line))")

        brain.send(OutboundEvent.partial(turnID: "r1", speaker: .remote, text: "what did the pilot achieve", cue: true, tAudioEnd: 1).jsonLine())
        brain.send(OutboundEvent.turn(turnID: "r1", speaker: .remote, text: "what did the pilot achieve", addressee: .me, tAudioEnd: 1).jsonLine())
        let delta = await lines.waitFor(timeout: 5) { $0["type"] as? String == "delta" && $0["turn_id"] as? String == "r1" }
        XCTAssertNotNil(delta, "no delta for r1: \(lines.all.map(\.line))")
        XCTAssertTrue(["S", "F"].contains(delta?["tier"] as? String ?? ""))

        await brain.shutdown()
        XCTAssertTrue(processIsGone(pid), "brain process \(pid) still alive after shutdown")
    }

    /// `killAll()` (what the signal handler and the error paths call) ends the brain even when nobody asked it to stop.
    func testKillAllEndsBrain() async throws {
        let brain = try BrainProcess(brainDir: try brainDir(), extraArgs: ["--fake"])
        try brain.start()
        let pid = brain.pid
        XCTAssertTrue(brain.isRunning)
        BrainProcess.killAll()
        let end = Date().addingTimeInterval(3)
        while !processIsGone(pid), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(processIsGone(pid), "brain process \(pid) survived killAll")
    }

    // MARK: helper

    private func runBrainPython(_ code: String, stdin: String) throws -> String {
        let dir = try brainDir()
        let p = Process()
        p.executableURL = dir.appendingPathComponent(".venv/bin/python")
        p.arguments = ["-c", code]
        p.currentDirectoryURL = dir      // `-c` puts the cwd on sys.path, so verse_brain imports
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: out, as: UTF8.self)
    }
}
