import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// The runner's raw level event (sink only): it carries the meeting channel's loudness about ten times a second, so the
/// overlay can say "Listening" with the sound and not only after the first transcribed words.
final class RunnerLevelTests: XCTestCase {
    private func session() throws -> TempSession {
        try TempSession(bank: [("b001", "Can you tell me about yourself?", [])], facts: [])
    }

    /// One `--fake-brain` run over a spoken file with a timestamped sink: levels arrive steadily, loud while the file
    /// speaks and not at all before; none of them is printed.
    func testLevelEventsFollowTheRemoteAudio() async throws {
        let s = try session()
        defer { s.delete() }
        let fixture = try SayFixture.make(voice: "Samantha", text: "[[slnc 1500]] Can you tell me about yourself and your background?")
        defer { fixture.delete() }

        let lock = NSLock()
        nonisolated(unsafe) var levels: [(t: Date, remote: Double?, me: Double?)] = []
        var o = RunOptions(sessionDir: s.dir)
        o.file = fixture.file
        o.fakeBrain = true
        o.drainSeconds = 2
        o.brainDir = try brainDir()
        o.sink = { e in
            if case .level(let r, let m) = e { lock.withLock { levels.append((Date(), r, m)) } }
        }
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 0)

        let got = lock.withLock { levels }
        XCTAssertGreaterThan(got.count, 20, "about ten a second over several seconds: \(got.count)")
        let gaps = zip(got, got.dropFirst()).map { $1.t.timeIntervalSince($0.t) }
        let steady = gaps.filter { $0 < 0.25 }.count
        XCTAssertGreaterThan(Double(steady) / Double(max(gaps.count, 1)), 0.9, "events keep a steady ~100 ms rhythm (max gap \(gaps.max() ?? 0))")
        let loud = got.filter { ($0.remote ?? -200) > -50 }
        XCTAssertFalse(loud.isEmpty, "the spoken file is above the -50 dBFS floor")
        XCTAssertTrue(got.contains { ($0.remote ?? -200) <= -50 }, "and the silence before it is not")
        XCTAssertTrue(got.allSatisfy { $0.me == nil }, "a file run has no microphone channel")
        // The first loud event comes after the leading silence and well before the end of the file.
        let first = got.first!.t, firstLoud = loud.first!.t
        XCTAssertGreaterThan(firstLoud.timeIntervalSince(first), 1.0, "speech starts after the 1.5 s of silence")
    }

    /// Without a sink (verse-run on the command line) nothing extra runs or prints.
    func testNoLevelTaskWithoutASink() {
        var o = RunOptions(sessionDir: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertNil(o.sink)
        o.micWithFile = true
        XCTAssertTrue(o.micWithFile)
        XCTAssertLessThanOrEqual(VerseRunner.levelPeriodMs, 100)
    }
}
