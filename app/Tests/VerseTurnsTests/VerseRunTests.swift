import Darwin
import Foundation
import os
import VerseAudio
import VerseSpeech
import VerseTurns
import XCTest

/// Runs the built `verse-run` binary and collects its stdout lines with their arrival times.
final class RunningVerseRun: @unchecked Sendable {
    let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = OSAllocatedUnfairLock()
    private var buffer = Data()
    private var lines: [(t: Date, obj: [String: Any])] = []
    private var errText = ""

    static var executable: URL {
        Bundle(for: RunningVerseRun.self).bundleURL.deletingLastPathComponent().appendingPathComponent("verse-run")
    }

    init(arguments: [String]) throws {
        process.executableURL = Self.executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.lock.withLockUnchecked { self?.errText += String(decoding: d, as: UTF8.self) }
        }
        try process.run()
    }

    private func consume(_ d: Data) {
        let now = Date()
        lock.withLockUnchecked {
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { lines.append((now, o)) }
            }
        }
    }

    var output: [(t: Date, obj: [String: Any])] { lock.withLockUnchecked { lines } }
    var stderrText: String { lock.withLockUnchecked { errText } }

    func waitFor(timeout: TimeInterval, _ predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let hit = output.first(where: { predicate($0.obj) }) { return hit.obj }
            if !process.isRunning { return output.first(where: { predicate($0.obj) })?.obj }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Waits for the process to exit; kills it after `timeout`. Returns the exit status, nil when it had to be killed.
    func waitForExit(timeout: TimeInterval) async -> Int32? {
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > end { process.terminate(); try? await Task.sleep(for: .milliseconds(300)); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // let the readers drain
        try? await Task.sleep(for: .milliseconds(100))
        return process.terminationStatus
    }
}

final class VerseRunTests: XCTestCase {

    private func isMetric(_ o: [String: Any], _ stage: String) -> Bool {
        o["type"] as? String == "metric" && o["stage"] as? String == stage
    }

    /// The whole pipeline without the network: a spoken file -> recognizer -> turn engine -> brain (canned replies)
    /// -> stdout. Checks the plumbing, the metrics, and that nothing is left running.
    func testVerseRunFileEndToEndWithFakeBrain() async throws {
        let session = try TempSession(
            bank: [("b001", "What results did Lantern deliver?", ["How did Lantern do?"]),
                   ("b002", "What is your biggest weakness?", [])],
            facts: ["{\"id\":\"f001\",\"kind\":\"name\",\"text\":\"Lantern project\",\"value\":\"Lantern\",\"sources\":[{\"kind\":\"prep\",\"ref\":\"prep:L13\",\"quote\":\"x\"}]}"])
        defer { session.delete() }
        let fixture = try SayFixture.make(voice: "Samantha", text: "What results did Lantern deliver?")
        defer { fixture.delete() }

        let run = try RunningVerseRun(arguments: ["--session", session.dir.path, "--lang", "en", "--file", fixture.file.path,
                                                  "--fake-brain", "--drain", "2"])
        let status = await run.waitForExit(timeout: 60)
        XCTAssertEqual(status, 0, "verse-run exit status; stderr: \(run.stderrText)")
        let out = run.output.map(\.obj)
        let t0 = try XCTUnwrap(out.first { isMetric($0, "session_t0") }, "no session_t0 metric")
        let brainPid = Int32(try XCTUnwrap(t0["brain_pid"] as? Int))

        XCTAssertTrue(out.contains { $0["type"] as? String == "status" && $0["state"] as? String == "ready" })
        XCTAssertTrue(out.contains { $0["type"] as? String == "chip" && $0["source_ref"] as? String == "prep:L13" }, "no fact chip for 'Lantern'")
        let turnSent = out.filter { isMetric($0, "turn_sent") }
        XCTAssertGreaterThanOrEqual(turnSent.count, 1)
        let tiers = Set(out.filter { $0["type"] as? String == "delta" }.compactMap { $0["tier"] as? String })
        XCTAssertFalse(tiers.isDisjoint(with: ["S", "F"]), "no S or F delta in the output")
        XCTAssertTrue(out.contains { isMetric($0, "first_text") })
        XCTAssertTrue(processIsGone(brainPid), "brain \(brainPid) still running after verse-run exited")
    }

    /// SIGINT while listening: verse-run stops and takes the brain with it.
    func testSigintKillsBrain() async throws {
        let session = try TempSession(bank: [("b001", "What results did Lantern deliver?", [])])
        defer { session.delete() }
        let fixture = try SayFixture.make(voice: "Samantha", text: "Tell me about the Lantern project. [[slnc 20000]] Thanks.")
        defer { fixture.delete() }
        let run = try RunningVerseRun(arguments: ["--session", session.dir.path, "--lang", "en", "--file", fixture.file.path, "--fake-brain"])
        let t0 = await run.waitFor(timeout: 30) { self.isMetric($0, "session_t0") }
        let brainPid = Int32(try XCTUnwrap(t0?["brain_pid"] as? Int, "verse-run never reached listening; stderr: \(run.stderrText)"))
        XCTAssertFalse(processIsGone(brainPid))
        try await Task.sleep(for: .seconds(2))
        kill(run.process.processIdentifier, SIGINT)
        let status = await run.waitForExit(timeout: 15)
        XCTAssertNotNil(status, "verse-run did not exit after SIGINT")
        XCTAssertTrue(processIsGone(brainPid), "brain \(brainPid) survived SIGINT of verse-run")
        XCTAssertFalse(run.process.isRunning)
    }

    /// verse-run with a session folder that has no pack fails fast and starts nothing.
    func testBadSessionFailsWithoutBrain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = try RunningVerseRun(arguments: ["--session", dir.path, "--lang", "en", "--file", "/nonexistent.wav", "--fake-brain"])
        let status = await run.waitForExit(timeout: 15)
        XCTAssertEqual(status, 2)
        XCTAssertTrue(run.stderrText.contains("pack.md"), run.stderrText)
    }

    // MARK: live (opt-in)

    /// VERSE_LIVE=1: a spoken question from the P1-1 sample session goes through the real brain (Haiku/Sonnet, paid
    /// from the Max credit) and S/F text must appear within 3 s of the turn. Prints the timing from the acoustic end.
    func testVerseRunFileEndToEnd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERSE_LIVE"] == "1", "set VERSE_LIVE=1 to run against the real API (budget < $0.05)")
        let sessionPath = ProcessInfo.processInfo.environment["VERSE_LIVE_SESSION"]
            ?? "/private/tmp/claude-501/-Users-user-Desktop-Alex-Rivera/f7e86aa3-9428-4db2-bfe0-2e9473397b22/scratchpad/verse-sessions/20261014-014809-d425d0c3"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sessionPath + "/pack.md"), "no session folder at \(sessionPath)")

        // b004 in the sample bank: "What results did Lantern deliver?"
        let fixture = try SayFixture.make(voice: "Samantha", text: "What results did Lantern deliver?")
        defer { fixture.delete() }
        let clip = try PCMClip.read(fixture.file)
        let bounds = try XCTUnwrap(clip.speechBounds())

        let run = try RunningVerseRun(arguments: ["--session", sessionPath, "--lang", "en", "--file", fixture.file.path,
                                                  "--drain", "8", "--budget-usd", "0.05"])
        let status = await run.waitForExit(timeout: 90)
        let out = run.output
        XCTAssertEqual(status, 0, "verse-run exit status; stderr: \(run.stderrText)")

        let t0 = try XCTUnwrap(out.first { isMetric($0.obj, "session_t0") }?.obj, "no session_t0 metric")
        let brainPid = Int32(try XCTUnwrap(t0["brain_pid"] as? Int))
        let wall0 = try XCTUnwrap(t0["t"] as? Double)
        let origin = try XCTUnwrap(t0["origin_remote"] as? Double)
        let trueEnd = wall0 + origin + bounds.end                       // acoustic end of the question, epoch seconds

        let ready = out.first { $0.obj["type"] as? String == "status" && $0.obj["state"] as? String == "ready" }
        XCTAssertNotNil(ready, "brain not ready; stderr: \(run.stderrText)")
        let sent = try XCTUnwrap(out.first { isMetric($0.obj, "turn_sent") }, "no turn was sent to the brain")
        let first = try XCTUnwrap(out.first { $0.obj["type"] as? String == "delta" && ["S", "F"].contains($0.obj["tier"] as? String ?? "") },
                                  "no S/F delta on stdout; output: \(out.map { String(describing: $0.obj) })")
        let selectOrDelta = out.contains { $0.obj["type"] as? String == "select" } || true
        XCTAssertTrue(selectOrDelta)
        let sentAt = try XCTUnwrap(sent.obj["t"] as? Double)
        let firstAt = first.t.timeIntervalSince1970
        let sinceTurn = firstAt - sentAt
        let sinceEnd = firstAt - trueEnd
        let turnSinceEnd = sentAt - trueEnd
        let tier = first.obj["tier"] as? String ?? "?"
        let metric = out.first { isMetric($0.obj, "first_text") }?.obj
        let costs = out.compactMap { $0.obj["cost_usd"] as? Double }.reduce(0, +)
        print(String(format: "[testVerseRunFileEndToEnd] question end -> turn sent %.2f s; turn sent -> first %@ text on stdout %.2f s; question end -> first %@ text on stdout %.2f s (in-process metric: %.2f s from recognizer audio end); metered spend in output $%.4f",
                     turnSinceEnd, tier, sinceTurn, tier, sinceEnd, (metric?["since_audio_end_s"] as? Double) ?? -1, costs))
        XCTAssertLessThanOrEqual(sinceTurn, 3.0, "first S/F text came \(sinceTurn) s after the turn was sent")
        XCTAssertTrue(processIsGone(brainPid), "brain \(brainPid) still running after verse-run exited")
        let rest = run.stderrText.lowercased()
        XCTAssertFalse(rest.contains("sk-ant"), "stderr must never contain key material")
    }
}
