import Foundation
import os
import VerseSpeech
@testable import VerseTurns
import VerseVoice
import XCTest

/// End to end without audio or cloud: the real brain (`--fake`: canned model output, no key, no network) runs the S2
/// fixture sim over JSON lines; the text voice "plays" each line and a scripted mic answers every `listen`. Checks
/// that the whole interview reaches `sim_report` and that the report and transcript land in the session folder.
final class SimBrainSmokeTests: XCTestCase {
    private var brainDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brain")
    }

    func testFakeBrainSimEndToEnd() async throws {
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "brain/.venv missing")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("verse-sim-smoke-\(UUID().uuidString)", isDirectory: true)
        let session = tmp.appendingPathComponent("session", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: brainDir.appendingPathComponent("tests/fixtures/sim_runtime/session"), to: session)

        let brain = try BrainProcess(brainDir: brainDir, extraArgs: ["--fake"])
        try brain.start()
        let mic = FakeMic()
        let log = EventLog()
        let box = OSAllocatedUnfairLock<SimRunner?>(initialState: nil)
        var cfg = SimRunner.Config()
        cfg.tickInterval = 0.02
        let runner = SimRunner(transport: brain, voice: TextVoice(), mic: mic, config: cfg, sink: { e in
            log.add(e)
            // Answer every question: words 0.2 s after the mic opened, then 2 s of silence on the mic clock.
            if case .listening(let q) = e {
                let t = mic.t + 1
                mic.t = t
                mic.hear("For \(q) I led Lantern and we cut entry time to two minutes.", start: t + 0.2, end: t + 1.5, final: true)
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    mic.t = t + 4
                    await box.withLock { $0 }?.tick(now: t + 4)
                }
            }
        })
        box.withLock { $0 = runner }
        await runner.start(sessionDir: session, mode: .coach, voice: .text)

        let end = Date().addingTimeInterval(90)
        while Date() < end, !log.all.contains(where: { if case .ended = $0 { return true }; return false }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        await runner.stop()
        XCTAssertFalse(brain.isRunning, "the brain process is gone")

        let events = log.all
        let report = events.compactMap { e -> String? in if case .report(let p) = e { return p }; return nil }.first
        XCTAssertTrue(events.contains(.ended(code: 0)), "ended cleanly: \(events.suffix(5))")
        let progress = events.compactMap { e -> Int? in if case .progress(let i, _) = e { return i }; return nil }
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertGreaterThanOrEqual(log.answers.count, 4, "3 questions + the candidate question")
        XCTAssertTrue(events.contains { if case .coach = $0 { return true }; return false }, "coach notes in coach mode")
        let reportPath = try XCTUnwrap(report, "sim_report arrived")
        XCTAssertTrue(fm.fileExists(atPath: reportPath), reportPath)
        let results = try JSONSerialization.jsonObject(with: Data(contentsOf: session.appendingPathComponent("sim_results.json"))) as? [String: Any]
        let qs = results?["questions"] as? [[String: Any]] ?? []
        XCTAssertEqual(qs.count, 3)
        let answers = qs.flatMap { ($0["answers"] as? [[String: Any]]) ?? [] }
        XCTAssertTrue(answers.allSatisfy { ($0["text"] as? String)?.contains("Lantern") == true }, "\(answers)")
        print("[smoke] events \(events.count), answers \(log.answers.count), report \(reportPath)")
    }
}
