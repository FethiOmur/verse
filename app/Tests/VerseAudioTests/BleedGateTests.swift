import Foundation
import VerseAudio
import VerseSpeech
import XCTest

final class BleedGateTests: XCTestCase {

    /// Deterministic noise in [-a, a].
    struct LCG {
        var state: UInt64
        mutating func next(_ a: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * a
        }
    }

    /// Speech-like test signal: noise with a syllable-rate envelope, 48 kHz.
    func modulatedNoise(seconds: Double, seed: UInt64, rate: Double) -> [Float] {
        var g = LCG(state: seed)
        let sr = 48000.0
        return (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            let env = Float(max(0, sin(2 * .pi * rate * t + Double(seed % 7)))) * Float(0.5 + 0.5 * sin(2 * .pi * 0.7 * t))
            return env * g.next(0.3)
        }
    }

    func track(_ s: [Float], delay: Double = 0, gain: Float = 1) -> EnvelopeTrack {
        let e = EnvelopeTrack()
        let pad = [Float](repeating: 0, count: Int(delay * 48000))
        let x = (pad + s).map { $0 * gain }
        var i = 0
        while i < x.count {   // 512-frame chunks like the tap
            let n = min(512, x.count - i)
            e.add(AudioChunk(samples: Array(x[i..<(i + n)]), sampleRate: 48000, startTime: Double(i) / 48000))
            i += n
        }
        return e
    }

    func testEchoAt40msIsCaughtAndOwnSpeechIsNot() {
        let remote = modulatedNoise(seconds: 3, seed: 1, rate: 4)
        let gate = BleedGate()
        let rTrack = track(remote)
        let echo = track(remote, delay: 0.04, gain: 0.3)
        let own = track(modulatedNoise(seconds: 3, seed: 99, rate: 5.3))

        let echoScore = try? XCTUnwrap(gate.echoScore(mic: echo, remote: rTrack, start: 0.5, end: 2.5))
        let ownScore = gate.echoScore(mic: own, remote: rTrack, start: 0.5, end: 2.5) ?? 0
        print(String(format: "[bleed unit] echo@40ms score %.3f, own speech score %.3f", echoScore ?? -1, ownScore))
        XCTAssertGreaterThanOrEqual(echoScore ?? 0, 0.6)
        XCTAssertTrue(gate.isEcho(mic: echo, remote: rTrack, start: 0.5, end: 2.5))
        XCTAssertLessThan(ownScore, 0.6)
        XCTAssertFalse(gate.isEcho(mic: own, remote: rTrack, start: 0.5, end: 2.5))
    }

    func testEchoBeyond80msIsNotTreatedAsEcho() {
        let remote = modulatedNoise(seconds: 3, seed: 3, rate: 4)
        let gate = BleedGate()
        // 200 ms is outside the 0-80 ms window; the envelope at that offset is not the same shape.
        let late = track(remote, delay: 0.2, gain: 0.3)
        let score = gate.echoScore(mic: late, remote: track(remote), start: 0.5, end: 2.5) ?? 0
        print(String(format: "[bleed unit] echo@200ms score %.3f", score))
        XCTAssertLessThan(score, 0.6)
    }

    func testSilentRemoteIsNeverEcho() {
        let gate = BleedGate()
        let silent = track([Float](repeating: 0, count: 48000 * 3))
        let mic = track(modulatedNoise(seconds: 3, seed: 5, rate: 4))
        XCTAssertNil(gate.echoScore(mic: mic, remote: silent, start: 0.5, end: 2.5))
        XCTAssertFalse(gate.isEcho(mic: mic, remote: silent, start: 0.5, end: 2.5))
    }

    // MARK: end to end through ListenSession (real recognizers, synthetic speech)

    static func pad(_ c: PCMClip, lead: Double) -> PCMClip {
        PCMClip(samples: [Float](repeating: 0, count: Int(lead * c.sampleRate)) + c.samples, sampleRate: c.sampleRate)
    }

    func run(remote: PCMClip, me: PCMClip) async throws -> (events: [TranscriptEvent], dropped: Int) {
        let session = ListenSession(config: ListenConfig(lang: "en", source: .memory(remote: remote, me: me)))
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        return (events, session.droppedEchoEvents)
    }

    /// The remote voice copied into the mic 40 ms later (speaker bleed) -> no `.me` events; the mic recognizer
    /// did hear it (events were dropped by the gate, not missing).
    func testBleedGateDropsEcho() async throws {
        let speech = Self.pad(try SayFixture.clip(voice: "Samantha", text: "Could you walk me through the deployment schedule for next week?"), lead: 0.5)
        var g = LCG(state: 42)
        let lag = Int(0.040 * speech.sampleRate)
        let micSamples = ([Float](repeating: 0, count: lag) + speech.samples.map { $0 * 0.35 }).map { $0 + g.next(0.0005) }
        let mic = PCMClip(samples: micSamples, sampleRate: speech.sampleRate)

        let (events, dropped) = try await run(remote: speech, me: mic)
        let remote = events.filter { $0.channel == .remote }
        let me = events.filter { $0.channel == .me }
        print("[testBleedGateDropsEcho] remote events \(remote.count), me events \(me.count), dropped echo events \(dropped); remote final: \(remote.filter(\.isFinal).map(\.text).joined(separator: " "))")
        XCTAssertFalse(remote.isEmpty, "remote channel produced no events")
        XCTAssertEqual(me.count, 0, "echo leaked as .me: \(me.map(\.text))")
        XCTAssertGreaterThan(dropped, 0, "the mic recognizer produced nothing, so the gate was not exercised")
    }

    /// Control: Alex talking over the remote speaker (different words, 300 ms later) is kept.
    func testBleedGateKeepsOwnSpeech() async throws {
        let remote = Self.pad(try SayFixture.clip(voice: "Samantha", text: "Could you walk me through the deployment schedule for next week?"), lead: 0.5)
        let own = Self.pad(try SayFixture.clip(voice: "Samantha", text: "Sure, the release goes out on Thursday morning."), lead: 0.8)
        let (events, dropped) = try await run(remote: remote, me: own)
        let me = events.filter { $0.channel == .me }
        print("[testBleedGateKeepsOwnSpeech] me events \(me.count), dropped \(dropped); me final: \(me.filter(\.isFinal).map(\.text).joined(separator: " "))")
        XCTAssertFalse(me.isEmpty, "own speech was dropped as echo")
        XCTAssertTrue(me.contains { $0.isFinal && words($0.text).contains("thursday") }, "own speech final missing 'thursday'")
    }
}
