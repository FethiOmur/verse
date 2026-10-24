@preconcurrency import AVFoundation
import Foundation
import os
import Speech
@testable import VerseSpeech
import XCTest

/// A recognizer that says exactly what the test scripted, when the audio it was fed reaches the end of each result.
/// No speech model involved, so the envelope gate is tested alone and the result does not depend on a recognizer.
final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let lang = "en"
    let engineName = "scripted"
    private let scripts: [Channel: [EngineResult]]
    private let lock = OSAllocatedUnfairLock()
    private var channel: Channel = .remote
    private var task: Task<Void, Never>?

    init(scripts: [Channel: [EngineResult]]) { self.scripts = scripts }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) {
        lock.withLockUnchecked { self.channel = channel }
    }

    func prepare() async throws -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        var pending = (scripts[lock.withLockUnchecked { channel }] ?? []).sorted { $0.end < $1.end }
        task = Task.detached {
            var fed = 0.0
            for await item in input {
                fed += Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                while let r = pending.first, r.end <= fed { onResult(r); pending.removeFirst() }
            }
            for r in pending { onResult(r) }
        }
    }

    func finish() async throws { await task?.value }
    func cancel() async { task?.cancel() }
}

/// The envelope gate against a person talking at the mic while the remote speaker talks. Signals are synthetic (modulated
/// noise at a syllable rate); the recognizer is scripted.
final class GateDoubleTalkTests: XCTestCase {
    struct LCG {
        var state: UInt64
        mutating func next(_ a: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * a
        }
    }

    static let sr = 48000.0

    /// Speech-like carrier: noise under a 4 Hz syllable envelope. `phase` fixes the envelope; the noise carrier comes from
    /// `seed`, so two voices with the same phase have the same envelope and different sound.
    static func voice(seconds: Double, seed: UInt64, phase: Double = 0.3) -> [Float] {
        var g = LCG(state: seed)
        return (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            let env = Float(max(0, sin(2 * .pi * 4 * t + phase))) * Float(0.5 + 0.5 * sin(2 * .pi * 0.7 * t))
            return env * g.next(0.3)
        }
    }

    /// The remote speaker heard by the mic: attenuated by `db`, `delay` seconds late, with a little room noise.
    static func echo(of remote: [Float], db: Double, delay: Double, seed: UInt64 = 42) -> [Float] {
        var g = LCG(state: seed)
        let gain = Float(pow(10, -db / 20))
        let lag = Int(delay * sr)
        return (0..<remote.count).map { i in (i >= lag ? remote[i - lag] * gain : 0) + g.next(0.0005) }
    }

    func run(remote: [Float], mic: [Float], meText: String, start: Double, end: Double) async throws
        -> (me: [TranscriptEvent], decisions: [GateDecision], dropped: Int) {
        let script: [Channel: [EngineResult]] = [
            .me: [EngineResult(text: meText, isFinal: false, start: start, end: (start + end) / 2),
                  EngineResult(text: meText, isFinal: true, start: start, end: end)],
        ]
        let env = ListenEnvironment(permissions: FixedPermissions(), makeRemoteSource: ListenEnvironment.system.makeRemoteSource,
                                    makeMicSource: ListenEnvironment.system.makeMicSource,
                                    makeEngine: { _ in ScriptedEngine(scripts: script) })
        let cfg = ListenConfig(lang: "en", source: .memory(remote: PCMClip(samples: remote, sampleRate: Self.sr),
                                                           me: PCMClip(samples: mic, sampleRate: Self.sr)))
        let session = ListenSession(config: cfg, environment: env)
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        return (events.filter { $0.channel == .me }, session.gateDecisions, session.droppedEchoEvents)
    }

    /// the owner talks while the remote speaker talks and the two envelopes correlate (the same syllable rhythm). His voice is
    /// as loud at the mic as the remote is in the tap, with the speaker echo underneath. The gate used to drop this at the
    /// first correlation of 0.6 or more; it must pass it on to the text guard.
    func testDoubleTalkWithCorrelatedEnvelopeIsKept() async throws {
        let remote = Self.voice(seconds: 3.5, seed: 1)
        let own = Self.voice(seconds: 3.5, seed: 77)                 // same envelope, different voice
        let echo = Self.echo(of: remote, db: 25, delay: 0.04)
        let mic = zip(own, echo).map { $0 + $1 }
        let r = try await run(remote: remote, mic: mic, meText: "Sorry one second let me share my screen first", start: 0.5, end: 3.0)
        for d in r.decisions {
            print(String(format: "[double talk] score %.3f ratio %.1f dB micOnly %.2f -> %@", d.features.score, d.features.window.ratioDb ?? .nan, d.features.window.micOnlyShare, d.verdict.rawValue))
        }
        let scores = r.decisions.map(\.features.score)
        XCTAssertFalse(scores.isEmpty)
        XCTAssertGreaterThanOrEqual(scores.min() ?? 0, BleedGate().threshold, "the fixture must correlate, or it proves nothing: \(scores)")
        XCTAssertEqual(r.dropped, 0, "the gate dropped the owner's real speech: \(r.decisions.map { "\($0.features.score)/\($0.features.window.ratioDb ?? .nan)" })")
        XCTAssertEqual(r.me.count, 2, "both results reach the turn engine")
        XCTAssertTrue(r.decisions.allSatisfy { $0.verdict == .defer })
    }

    /// Bleed protection: the remote voice at -25 dB (40 ms) and -30 dB (80 ms), the cells of the P1 report, plus the louder
    /// -15 and -10 dB, never reaches the turn engine as a me result.
    func testEchoCellsAreStillDropped() async throws {
        for (db, delay) in [(25.0, 0.04), (30.0, 0.08), (15.0, 0.04), (10.0, 0.04)] {
            let remote = Self.voice(seconds: 3.5, seed: 1)
            let mic = Self.echo(of: remote, db: db, delay: delay)
            let r = try await run(remote: remote, mic: mic, meText: "Could you walk me through the deployment schedule", start: 0.5, end: 3.0)
            print("[echo -\(Int(db)) dB \(Int(delay * 1000)) ms] me results \(r.me.count), dropped \(r.dropped), "
                  + r.decisions.map { String(format: "%.2f/%.1fdB", $0.features.score, $0.features.window.ratioDb ?? .nan) }.joined(separator: " "))
            XCTAssertEqual(r.me.count, 0, "echo at -\(db) dB / \(delay * 1000) ms leaked: \(r.me.map(\.text))")
            XCTAssertEqual(r.dropped, 2, "-\(db) dB: the gate must drop both results")
        }
    }
}
