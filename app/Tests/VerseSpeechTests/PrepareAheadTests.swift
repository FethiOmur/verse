@preconcurrency import AVFoundation
import Foundation
import os
import Speech
@testable import VerseSpeech
import XCTest

/// `ListenSession.prepare()` (anytime-swap): permissions, sources and recognizers are made ahead of `start()`, so a mid-call route
/// or language switch can load the next recognizers while the old pipeline still listens.
final class PrepareAheadTests: XCTestCase {

    /// Counts what the session built and started.
    final class Probe: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private(set) var engines = 0
        private(set) var cancelled = 0
        private(set) var sourcesStarted = 0
        func engineMade() { lock.withLockUnchecked { engines += 1 } }
        func engineCancelled() { lock.withLockUnchecked { cancelled += 1 } }
        func sourceStarted() { lock.withLockUnchecked { sourcesStarted += 1 } }
    }

    final class CountingSource: AudioCaptureSource, @unchecked Sendable {
        let inner: MemorySource
        let probe: Probe
        init(clip: PCMClip, probe: Probe) {
            inner = MemorySource(clip: clip, tailSeconds: 0.2, name: "counting memory")
            self.probe = probe
        }
        var routeDescription: String { inner.routeDescription }
        func targetIsProducingOutput() -> Bool? { inner.targetIsProducingOutput() }
        func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
            probe.sourceStarted()
            try inner.start(clock: clock, onChunk: onChunk, onEnd: onEnd)
        }
        func stop() { inner.stop() }
    }

    final class ProbedEngine: TranscriptionEngine, @unchecked Sendable {
        let lang = "en"
        let engineName = "probed"
        let probe: Probe
        private var task: Task<Void, Never>?
        init(probe: Probe) { self.probe = probe; probe.engineMade() }
        func prepare() async throws -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)! }
        func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
            task = Task.detached {
                var fed = 0.0
                var said = false
                for await item in input {
                    fed += Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                    if fed >= 0.5, !said { said = true; onResult(EngineResult(text: "ready to go", isFinal: true, start: 0.1, end: 0.5)) }
                }
            }
        }
        func finish() async throws { await task?.value }
        func cancel() async { probe.engineCancelled(); task?.cancel() }
    }

    private func session(_ probe: Probe, perms: FixedPermissions = FixedPermissions()) -> ListenSession {
        let clip = PCMClip(samples: GateDoubleTalkTests.voice(seconds: 1, seed: 3), sampleRate: GateDoubleTalkTests.sr)
        let env = ListenEnvironment(permissions: perms,
                                    makeRemoteSource: { _ in CountingSource(clip: clip, probe: probe) },
                                    makeMicSource: { _ in nil },
                                    makeEngine: { _ in ProbedEngine(probe: probe) })
        return ListenSession(config: ListenConfig(lang: "en", micEnabled: false, source: .live), environment: env)
    }

    /// Recognizers are made and loaded by `prepare()`; no source runs until `start()`; `start()` after `prepare()` builds nothing new.
    func testPrepareMakesTheEnginesAndStartOpensTheSources() async throws {
        let probe = Probe()
        let s = session(probe)
        try await s.prepare()
        try await s.prepare()                                  // idempotent
        XCTAssertEqual(probe.engines, 1)
        XCTAssertEqual(probe.sourcesStarted, 0, "nothing is listening yet")
        let stream = try await s.start()
        XCTAssertEqual(probe.engines, 1, "start() used the prepared engine")
        XCTAssertEqual(probe.sourcesStarted, 1)
        var texts: [String] = []
        for await e in stream { texts.append(e.text) }
        XCTAssertEqual(texts, ["ready to go"])
    }

    /// `start()` alone still works exactly as before.
    func testStartAloneStillPreparesItself() async throws {
        let probe = Probe()
        let s = session(probe)
        var n = 0
        for await _ in try await s.start() { n += 1 }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(probe.engines, 1)
    }

    /// A refused permission fails at `prepare()`: the call that is running is never touched by a switch that cannot happen.
    func testAPermissionProblemShowsAtPrepare() async {
        let probe = Probe()
        let s = ListenSession(config: {
            var c = ListenConfig(lang: "en", source: .live)
            c.micAsRemote = true
            return c
        }(), environment: ListenEnvironment(
            permissions: FixedPermissions(audioCapture: .granted, microphone: .denied),
            makeRemoteSource: { _ in CountingSource(clip: PCMClip(samples: [0, 0, 0], sampleRate: 16000), probe: probe) },
            makeMicSource: { _ in nil }, makeEngine: { _ in ProbedEngine(probe: probe) }))
        do {
            try await s.prepare()
            XCTFail("expected permissionDenied")
        } catch let e as ListenError {
            XCTAssertEqual(e.code, "permission_denied")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(probe.sourcesStarted, 0)
    }

    /// A prepared session that is given up releases its recognizers and starts no source.
    func testDiscardPreparedReleasesTheRecognizers() async throws {
        let probe = Probe()
        let s = session(probe)
        try await s.prepare()
        await s.discardPrepared()
        XCTAssertEqual(probe.cancelled, 1)
        XCTAssertEqual(probe.sourcesStarted, 0)
        await s.discardPrepared()                              // nothing left to discard
        XCTAssertEqual(probe.cancelled, 1)
    }

    /// Once started, a session cannot be discarded (it is stopped instead).
    func testDiscardAfterStartDoesNothing() async throws {
        let probe = Probe()
        let s = session(probe)
        let stream = try await s.start()
        await s.discardPrepared()
        XCTAssertEqual(probe.cancelled, 0)
        for await _ in stream {}
    }
}
