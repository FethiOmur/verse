@preconcurrency import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
@testable import VersePrompter
import VerseAudio
import VerseSpeech

/// Review V2: the prompter closed while its start is still opening the mic and loading the recognizer.
@Suite("Prompter start overtaken by stop")
struct StartStopRaceTests {

    /// A one-shot gate a test opens by hand.
    final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>], entered: Bool)>((false, [], false))
        var entered: Bool { state.withLock { $0.entered } }
        func wait() async {
            await withCheckedContinuation { c in
                let resumeNow = state.withLock { s -> Bool in
                    s.entered = true
                    if s.open { return true }
                    s.waiters.append(c)
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        func open() {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.open = true
                defer { s.waiters = [] }
                return s.waiters
            }
            for c in waiters { c.resume() }
        }
    }

    /// Transcript source whose `events()` does not return until the gate opens.
    final class SlowTranscriptSource: TranscriptSource {
        let gate = Gate()
        let broadcaster = TranscriptBroadcaster()
        let stops = Mutex(0)
        func events() async throws -> AsyncStream<TranscriptEvent> {
            await gate.wait()
            return broadcaster.subscribe()
        }
        func stop() async {
            stops.withLock { $0 += 1 }
            broadcaster.finish()
        }
    }

    @Test
    func startThatReturnsAfterStopStaysStoppedAndClosesItsInputs() async {
        let source = SlowTranscriptSource()
        let session = PrompterSession(script: SessionTests.script, mode: .wordTracking, transcript: source,
                                      clock: ManualClock(), autoTick: false)
        let starting = Task { await session.start() }
        #expect(await eventually { source.gate.entered })
        await session.stop()
        let stopsBefore = source.stops.withLock { $0 }
        source.gate.open()
        await starting.value
        let state = await session.state
        #expect(state.isPaused, "a start overtaken by stop must not resume reading")
        #expect(source.stops.withLock { $0 } > stopsBefore, "the inputs opened after stop are closed again")
    }

    // MARK: ListenSessionInputs

    final class Probe: Sendable {
        let starts = Mutex(0)
        let stops = Mutex(0)
    }

    /// A long silent clip; counts start and stop.
    final class CountingSource: AudioCaptureSource, @unchecked Sendable {
        let inner = MemorySource(clip: PCMClip(samples: [Float](repeating: 0, count: 16000 * 30), sampleRate: 16000),
                                 tailSeconds: 0, name: "silent memory")
        let probe: Probe
        init(probe: Probe) { self.probe = probe }
        var routeDescription: String { inner.routeDescription }
        func targetIsProducingOutput() -> Bool? { inner.targetIsProducingOutput() }
        func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
            probe.starts.withLock { $0 += 1 }
            try inner.start(clock: clock, onChunk: onChunk, onEnd: onEnd)
        }
        func stop() {
            probe.stops.withLock { $0 += 1 }
            inner.stop()
        }
    }

    /// An engine whose model load waits for the gate (the slow part of a real start).
    final class SlowEngine: TranscriptionEngine, @unchecked Sendable {
        let lang = "en"
        let engineName = "slow"
        let gate: Gate
        private var task: Task<Void, Never>?
        init(gate: Gate) { self.gate = gate }
        func prepare() async throws -> AVAudioFormat {
            await gate.wait()
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        }
        func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
            task = Task.detached { for await _ in input {} }
        }
        func finish() async throws { await task?.value }
        func cancel() async { task?.cancel() }
    }

    @Test
    func listenInputsStoppedWhileStartingCloseTheMicWhenTheStartReturns() async throws {
        let probe = Probe()
        let gate = Gate()
        let env = ListenEnvironment(permissions: FixedPermissions(),
                                    makeRemoteSource: { _ in nil },
                                    makeMicSource: { _ in CountingSource(probe: probe) },
                                    makeEngine: { _ in SlowEngine(gate: gate) })
        var config = ListenConfig(lang: "en", remoteBundleIDs: [], micEnabled: true, source: .live)
        config.releaseIdleModelsOnStop = false
        config.statusSink = nil
        let inputs = ListenSessionInputs(session: ListenSession(config: config, environment: env))

        let starting = Task { try await inputs.events() }
        #expect(await eventually { gate.entered })
        await inputs.stop()
        gate.open()
        _ = try? await starting.value
        #expect(await eventually { probe.starts.withLock { $0 } == 0 || probe.stops.withLock { $0 } > 0 },
                "a mic that opened after stop() is closed again")
    }
}
