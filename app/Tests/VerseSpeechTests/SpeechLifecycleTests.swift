@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import os
import Speech
@testable import VerseAudio
@testable import VerseSpeech
import XCTest

/// Review S4 (lease kept when the Apple flush throws), S5 (idle models unloaded at a safe point), S7 (shadow recognizer:
/// failed start released, a failure only benches the language) and S10 (gate logs bounded). Fake engines, no model, no audio.
final class SpeechLifecycleTests: XCTestCase {
    typealias Box = RecoveryTests.Box

    final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
        let lang: String
        let engineName = "scripted"
        let failStart: Bool
        let failFinish: Bool
        let cancelled = Box<Bool>()
        private var task: Task<Void, Never>?

        init(lang: String = "en", failStart: Bool = false, failFinish: Bool = false) {
            self.lang = lang; self.failStart = failStart; self.failFinish = failFinish
        }
        struct Boom: Error {}
        func prepare() async throws -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        }
        func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
            if failStart { throw Boom() }
            task = Task.detached { for await _ in input {} }
        }
        func finish() async throws {
            await task?.value
            if failFinish { throw Boom() }
        }
        func cancel() async { cancelled.add(true); task?.cancel() }
    }

    // MARK: S4

    /// The session ends before the switch and Apple's flush throws: the loaded local engine (its Nemotron lease) is still released.
    func testThrowingAppleFlushStillReleasesTheLocalEngine() async throws {
        let apple = ScriptedEngine(failFinish: true)
        let local = ScriptedEngine()
        let sw = SwitchingEngine(lang: "en", apple: apple, makeLocal: { local })
        _ = try await sw.prepare()
        try await Task.sleep(for: .milliseconds(50))      // the local "load" lands
        let (input, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await sw.start(input: input) { _ in }
        cont.finish()                                     // no audio: no turn boundary, no switch
        do {
            try await sw.finish()
            XCTFail("the Apple flush should throw")
        } catch {}
        try await Task.sleep(for: .milliseconds(50))      // abandonLoad releases in a task
        XCTAssertFalse(sw.hasSwitched)
        XCTAssertEqual(local.cancelled.items.count, 1, "the local engine is released even though finish() threw")
    }

    // MARK: S5

    /// Unloading right after a release (what `ListenSession.stop()` does) drops that model too: `unloadIdle` waits for the
    /// release in flight, here one whose load is still running. A model in use stays.
    func testUnloadIdleWaitsForAReleaseInFlight() async throws {
        let pool = NemotronModelPool(load: { _ in
            try await Task.sleep(for: .milliseconds(150))
            return StreamingNemotronAsrManager(requestedChunkSize: .ms560)
        })
        let dir = URL(fileURLWithPath: "/nonexistent/nemotron-test")
        let inUse = await pool.acquire(dir: dir)
        let released = await pool.acquire(dir: dir)
        _ = try await inUse.task.value
        let before = await pool.count
        XCTAssertEqual(before, 2)
        await pool.release(released)                      // its load is still running
        await pool.unloadIdle()
        let after = await pool.count
        XCTAssertEqual(after, 1, "the released model went; the one in use stayed")
    }

    // MARK: S10

    /// The gate logs keep the newest entries only; the drop count stays the total.
    func testGateLogsAreBounded() {
        let c = Counters(maxLog: 100)
        let f = GateFeatures(score: 0.9, lagMs: 0, window: GateLevels(meDb: nil, remoteDb: nil, ratioDb: nil, micOnlyShare: 0, remoteActiveShare: 0))
        for i in 0..<1000 {
            c.addDecision(GateDecision(text: "\(i)", isFinal: false, audioStart: 0, audioEnd: 0, emittedAt: 0, features: f, verdict: .keep))
            c.addDropped(DroppedEcho(text: "\(i)", isFinal: false, audioStart: 0, audioEnd: 0, emittedAt: 0, score: 0.9))
        }
        XCTAssertEqual(c.decisions.count, 100)
        XCTAssertEqual(c.decisions.last?.text, "999")
        XCTAssertEqual(c.decisions.first?.text, "900")
        XCTAssertEqual(c.log.count, 100)
        XCTAssertEqual(c.dropped, 1000)
        XCTAssertLessThanOrEqual(c.storedCounts.decisions, 125, "memory stays bounded, not only what is read")
        XCTAssertLessThanOrEqual(c.storedCounts.dropped, 125)
    }

    // MARK: S7

    /// Feeds `seconds` of silence in 0.1 s pieces from session time `from`, pausing so the shadow's detached start can land.
    private func feed(_ s: ShadowRecognizer, from: Double, seconds: Double) async {
        var t = from
        while t < from + seconds - 1e-9 {
            t += 0.1
            s.feed([Float](repeating: 0, count: 1600), rate: 16000, endTime: t)
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A candidate whose recognizer fails to start: that engine is released, the language is benched (not dropped for the
    /// call) and listens again once the retry delay has passed.
    func testFailedShadowStartIsReleasedAndRetriedLater() async throws {
        let made = Box<ScriptedEngine>()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        var cfg = ShadowConfig(candidates: ["it"], onResult: { _ in })
        cfg.retryAfterSeconds = 5
        let shadow = ShadowRecognizer(channel: .remote, config: cfg, makeEngine: { lang in
            let n = attempts.withLock { $0 += 1; return $0 }
            let e = ScriptedEngine(lang: lang, failStart: n == 1)
            made.add(e)
            return e
        })
        await feed(shadow, from: 0, seconds: 1)
        XCTAssertEqual(made.items.count, 1)
        XCTAssertEqual(made.items.first?.cancelled.items.count, 1, "the engine that failed to start is released")
        XCTAssertEqual(shadow.slotsStarted, 0)
        await feed(shadow, from: 1, seconds: 2)
        XCTAssertEqual(made.items.count, 1, "benched: not retried before the delay")
        await feed(shadow, from: 3, seconds: 3)
        XCTAssertEqual(made.items.count, 2, "tried again after the delay")
        XCTAssertEqual(shadow.slotsStarted, 1)
        XCTAssertTrue(shadow.excludedLanguages.isEmpty)
        await shadow.stop()
    }

    /// No engine can be made for a language: it is left out at once. One that keeps failing to start goes after
    /// `maxStartFailures` failures in a row.
    func testShadowLanguageIsDroppedOnlyForGood() async throws {
        struct Unsupported: Error {}
        var cfg = ShadowConfig(candidates: ["xx", "tr"], onResult: { _ in })
        cfg.retryAfterSeconds = 0.5
        cfg.maxStartFailures = 2
        let made = Box<String>()
        let shadow = ShadowRecognizer(channel: .remote, config: cfg, makeEngine: { lang in
            made.add(lang)
            if lang == "xx" { throw Unsupported() }
            return ScriptedEngine(lang: lang, failStart: true)
        })
        await feed(shadow, from: 0, seconds: 6)
        XCTAssertEqual(shadow.excludedLanguages, ["xx", "tr"])
        XCTAssertEqual(made.items.filter { $0 == "xx" }.count, 1, "never asked again")
        XCTAssertEqual(made.items.filter { $0 == "tr" }.count, 2, "two failures in a row, then out")
        await shadow.stop()
    }
}
