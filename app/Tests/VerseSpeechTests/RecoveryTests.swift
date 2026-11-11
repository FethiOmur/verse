@preconcurrency import AVFoundation
import Foundation
import os
import Speech
@testable import VerseSpeech
import XCTest

/// Review H8 (a recognizer failure mid-call), H5 wiring (capture events reach `issues`) and S1 (engines released when `start()` fails).
/// No speech model and no audio hardware: fake engines and in-memory sources.
final class RecoveryTests: XCTestCase {

    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var items_: [T] = []
        var items: [T] { lock.withLockUnchecked { items_ } }
        func add(_ x: T) { lock.withLockUnchecked { items_.append(x) } }
    }

    /// Feeds on its own timeline; says `text` at `sayAt` seconds of fed audio; at `failAt` reports a failure and stops reading
    /// (what NemotronEngine.run does when `process` throws).
    final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
        let lang = "en"
        let engineName: String
        let rate: Double
        let sayAt: Double?, text: String
        let failAt: Double?
        let cancelled = Box<Bool>()
        let rates = Box<Double>()
        private let lock = OSAllocatedUnfairLock()
        private var handler: (@Sendable (String) -> Void)?
        private var task: Task<Void, Never>?

        init(_ name: String, rate: Double = 16000, sayAt: Double? = nil, text: String = "", failAt: Double? = nil) {
            engineName = name; self.rate = rate; self.sayAt = sayAt; self.text = text; self.failAt = failAt
        }
        func setFailureHandler(_ h: @escaping @Sendable (String) -> Void) { lock.withLockUnchecked { handler = h } }
        func prepare() async throws -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        }
        func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
            let h = lock.withLockUnchecked { handler }
            let (sayAt, failAt, text, rates) = (self.sayAt, self.failAt, self.text, self.rates)
            task = Task.detached {
                var fed = 0.0, said = false
                for await item in input {
                    rates.add(item.buffer.format.sampleRate)
                    fed += Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                    if let s = sayAt, fed >= s, !said { said = true; onResult(EngineResult(text: text, isFinal: true, start: s - 0.2, end: s)) }
                    if let f = failAt, fed >= f { h?("decode failed (test)"); return }
                }
            }
        }
        func finish() async throws { await task?.value }
        func cancel() async { cancelled.add(true); task?.cancel() }
    }

    struct NoFallback: Error {}

    static func buffer(seconds: Double, rate: Double = 16000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
        b.frameLength = b.frameCapacity
        return b
    }

    /// Feeds `seconds` of audio in 0.1 s buffers, a little slower than the fakes read, then ends the input and flushes.
    private func run(_ engine: RecoveringEngine, seconds: Double) async throws -> [EngineResult] {
        let results = Box<EngineResult>()
        _ = try await engine.prepare()
        let (input, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await engine.start(input: input) { results.add($0) }
        for _ in 0..<Int(seconds * 10) {
            cont.yield(AnalyzerInput(buffer: Self.buffer(seconds: 0.1)))
            try? await Task.sleep(for: .milliseconds(3))
        }
        cont.finish()
        try await engine.finish()
        return results.items
    }

    /// The local engine dies at 1 s: the Apple-kind fallback takes over from that point, its words land at the right time,
    /// the session hears `speechRecovered`, the failed engine is released.
    func testFailedEngineIsReplacedAndItsTimelineContinues() async throws {
        let primary = FakeEngine("nemotron-fake", sayAt: 0.5, text: "before", failAt: 1.0)
        let fallback = FakeEngine("apple-fake", sayAt: 0.5, text: "after")
        let issues = Box<ListenError>(), statuses = Box<ListenStatus>()
        let e = RecoveringEngine(primary: primary, channel: .remote, makeFallback: { fallback }, report: { issues.add($0) })
        e.attach(channel: .remote, status: { statuses.add($0) })
        let results = try await run(e, seconds: 3)

        XCTAssertEqual(results.map(\.text), ["before", "after"])
        let sw = try XCTUnwrap(statuses.items.first { $0.state == "engine_fallback" })
        let at = try XCTUnwrap(sw.switchAtSec)
        XCTAssertGreaterThanOrEqual(at, 1.0, "the fallback starts where the failed engine stopped, never earlier")
        XCTAssertEqual(results[1].end, at + 0.5, accuracy: 1e-6, "the fallback's results are shifted onto the channel's timeline")
        XCTAssertEqual(sw.from, "nemotron-fake")
        XCTAssertEqual(e.engineName, "apple-fake")
        guard case .speechRecovered(.remote, let why)? = issues.items.first, issues.items.count == 1 else { return XCTFail("\(issues.items)") }
        XCTAssertTrue(why.contains("decode failed"), why)
        XCTAssertEqual(primary.cancelled.items.count, 1, "the failed engine (and its model lease) is released")
        XCTAssertFalse(e.gaveUp)
    }

    /// No fallback can be built: the channel says so (`speechFailed`), the input is drained and `finish()` returns.
    func testNoFallbackReportsSpeechFailed() async throws {
        let primary = FakeEngine("nemotron-fake", failAt: 0.5)
        let issues = Box<ListenError>()
        let e = RecoveringEngine(primary: primary, channel: .me, makeFallback: { throw NoFallback() }, report: { issues.add($0) })
        _ = try await run(e, seconds: 2)
        guard case .speechFailed(.me, _)? = issues.items.first, issues.items.count == 1 else { return XCTFail("\(issues.items)") }
        XCTAssertTrue(e.gaveUp)
        XCTAssertEqual(ListenError.speechFailed(.me, "x").code, "speech_failed")
    }

    /// A fallback that fails too is replaced until `maxRecoveries`, then the channel gives up with one `speechFailed`.
    func testGivesUpAfterMaxRecoveries() async throws {
        let issues = Box<ListenError>()
        let e = RecoveringEngine(primary: FakeEngine("a", failAt: 0.3), channel: .remote, maxRecoveries: 2,
                                 makeFallback: { FakeEngine("b", failAt: 0.3) }, report: { issues.add($0) })
        _ = try await run(e, seconds: 3)
        XCTAssertEqual(issues.items.map(\.code), ["speech_recovered", "speech_recovered", "speech_failed"])
        XCTAssertEqual(e.recoveries, 2)
        XCTAssertTrue(e.gaveUp)
    }

    /// A fallback that wants another format gets converted buffers.
    func testFallbackInAnotherFormatGetsConvertedAudio() async throws {
        let fallback = FakeEngine("apple-48k", rate: 48000)
        let e = RecoveringEngine(primary: FakeEngine("p", failAt: 0.3), channel: .remote, makeFallback: { fallback }, report: { _ in })
        _ = try await run(e, seconds: 1.5)
        XCTAssertFalse(fallback.rates.items.isEmpty)
        XCTAssertEqual(Set(fallback.rates.items), [48000])
    }

    /// A healthy engine is untouched: no issue, its own finish, no fallback built.
    func testHealthyEngineIsPassedThrough() async throws {
        let primary = FakeEngine("ok", sayAt: 0.5, text: "hello")
        let made = Box<Bool>(), issues = Box<ListenError>()
        let e = RecoveringEngine(primary: primary, channel: .remote, makeFallback: { made.add(true); return FakeEngine("x") },
                                 report: { issues.add($0) })
        let results = try await run(e, seconds: 1)
        XCTAssertEqual(results.map(\.text), ["hello"])
        XCTAssertEqual(results.first?.end, 0.5)
        XCTAssertTrue(made.items.isEmpty)
        XCTAssertTrue(issues.items.isEmpty)
    }

    // MARK: SwitchingEngine passes the active engine's failure up

    /// After the switch the local engine's failure goes up; Apple's late error (it was closed on purpose) does not.
    func testSwitchingEngineForwardsTheActiveEnginesFailure() async throws {
        final class FailableApple: TranscriptionEngine, @unchecked Sendable {
            let lang = "en", engineName = "apple-fake"
            var handler: (@Sendable (String) -> Void)?
            func setFailureHandler(_ h: @escaping @Sendable (String) -> Void) { handler = h }
            func prepare() async throws -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)! }
            func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
                Task.detached { for await _ in input {} }
            }
            func finish() async throws {}
            func cancel() async {}
        }
        let apple = FailableApple()
        let local = FakeEngine("local-fake", failAt: 0.5)
        let failures = Box<String>()
        let sw = SwitchingEngine(lang: "en", apple: apple, makeLocal: { local })
        sw.setFailureHandler { failures.add($0) }
        _ = try await sw.prepare()
        try await Task.sleep(for: .milliseconds(50))     // the local "load" lands
        let (input, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await sw.start(input: input) { _ in }
        for _ in 0..<30 {                                 // silence: the first turn boundary switches at 0.6 s
            cont.yield(AnalyzerInput(buffer: Self.buffer(seconds: 0.1)))
            try? await Task.sleep(for: .milliseconds(3))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sw.hasSwitched)
        apple.handler?("late apple error")
        cont.finish()
        try await sw.finish()
        XCTAssertEqual(failures.items, ["decode failed (test)"])
    }

    // MARK: through ListenSession

    final class EventSource: AudioCaptureSource, @unchecked Sendable {
        let inner: MemorySource
        let event: CaptureEvent?
        let failStart: Bool
        private let lock = OSAllocatedUnfairLock()
        private var handler: (@Sendable (CaptureEvent) -> Void)?
        init(seconds: Double, event: CaptureEvent? = nil, failStart: Bool = false) {
            inner = MemorySource(clip: PCMClip(samples: GateDoubleTalkTests.voice(seconds: seconds, seed: 5), sampleRate: GateDoubleTalkTests.sr),
                                 tailSeconds: 0.2, name: "event memory")
            self.event = event
            self.failStart = failStart
        }
        var routeDescription: String { inner.routeDescription }
        func targetIsProducingOutput() -> Bool? { nil }
        func setEventHandler(_ h: @escaping @Sendable (CaptureEvent) -> Void) { lock.withLockUnchecked { handler = h } }
        func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
            if failStart { throw ListenError.micFailed("no input device (test)") }
            try inner.start(clock: clock, onChunk: onChunk, onEnd: onEnd)
            if let event, let h = lock.withLockUnchecked({ handler }) { h(event) }
        }
        func stop() { inner.stop() }
    }

    private func collect(_ s: ListenSession, _ stream: AsyncStream<TranscriptEvent>) async -> ([TranscriptEvent], [ListenError]) {
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        await s.waitUntilFinished()
        var issues: [ListenError] = []
        for await i in s.issues { issues.append(i) }
        return (events, issues)
    }

    /// The session's engine fails mid-call: the issue reaches `session.issues` (what VerseRunner turns into an `issue` line for
    /// the overlay) and the Apple-kind engine the session asks for keeps the channel transcribing.
    func testSessionReportsAndRecoversAnEngineFailure() async throws {
        let env = ListenEnvironment(permissions: FixedPermissions(),
                                    makeRemoteSource: { _ in EventSource(seconds: 2) },
                                    makeMicSource: { _ in nil },
                                    makeEngine: { cfg in
                                        cfg.engineKind == .speechTranscriber
                                            ? FakeEngine("apple-fake", sayAt: 0.3, text: "still here")
                                            : FakeEngine("nemotron-fake", failAt: 0.5)
                                    })
        var cfg = ListenConfig(lang: "en", micEnabled: false, source: .live)
        cfg.statusSink = nil
        let s = ListenSession(config: cfg, environment: env)
        let (events, issues) = await collect(s, try await s.start())
        XCTAssertEqual(events.map(\.text), ["still here"])
        XCTAssertEqual(issues.map(\.code), ["speech_recovered"])
        let names = await s.engineNames()
        XCTAssertEqual(names[.remote], "apple-fake")
    }

    /// A capture event from the source reaches `session.issues` with its channel.
    func testCaptureEventsReachTheSessionIssues() async throws {
        let env = ListenEnvironment(permissions: FixedPermissions(),
                                    makeRemoteSource: { _ in EventSource(seconds: 0.5) },
                                    makeMicSource: { _ in EventSource(seconds: 0.5, event: .failed("no input device after AirPods left")) },
                                    makeEngine: { _ in FakeEngine("ok") })
        var cfg = ListenConfig(lang: "en", source: .live)
        cfg.statusSink = nil
        let s = ListenSession(config: cfg, environment: env)
        let (_, issues) = await collect(s, try await s.start())
        XCTAssertEqual(issues.filter { $0.code != "dead_stream" }, [.captureFailed(.me, "no input device after AirPods left")])
    }

    /// Review S1: when a source fails to start, every recognizer the session built is released (the started one included).
    func testFailedStartReleasesEveryEngine() async throws {
        let engines = Box<FakeEngine>()
        let env = ListenEnvironment(permissions: FixedPermissions(),
                                    makeRemoteSource: { _ in EventSource(seconds: 1) },
                                    makeMicSource: { _ in EventSource(seconds: 1, failStart: true) },
                                    makeEngine: { _ in let e = FakeEngine("ok"); engines.add(e); return e })
        var cfg = ListenConfig(lang: "en", source: .live)
        cfg.statusSink = nil
        let s = ListenSession(config: cfg, environment: env)
        do {
            _ = try await s.start()
            XCTFail("start should throw")
        } catch let e as ListenError {
            XCTAssertEqual(e.code, "mic_failed")
        }
        XCTAssertEqual(engines.items.count, 2)
        XCTAssertEqual(engines.items.map { $0.cancelled.items.count }, [1, 1])
    }
}
