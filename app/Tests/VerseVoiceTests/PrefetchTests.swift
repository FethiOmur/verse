import XCTest
@testable import VerseVoice

/// An engine whose synthesis and playback take a set time; records what happened, writes nothing.
final class SlowEngine: VoiceEngine, @unchecked Sendable {
    let kind: VoiceKind
    let synthDelay: Duration
    let playDelay: Duration
    let clipBytes: Int
    var failing: Set<String> = []
    private let state = Locked<(synth: [String], active: Int, peak: Int, plays: [(text: String, start: Date, end: Date)])>(([], 0, 0, []))

    init(kind: VoiceKind = .openai, synth: Duration = .milliseconds(300), play: Duration = .milliseconds(100), clipBytes: Int = 1000) {
        self.kind = kind; synthDelay = synth; playDelay = play; self.clipBytes = clipBytes
    }

    var synthesized: [String] { state.with { $0.synth } }
    var peakConcurrency: Int { state.with { $0.peak } }
    var plays: [(text: String, start: Date, end: Date)] { state.with { $0.plays } }

    func synthesize(_ sentence: String) async throws -> SynthesizedSpeech {
        state.with { $0.synth.append(sentence); $0.active += 1; $0.peak = max($0.peak, $0.active) }
        defer { state.with { $0.active -= 1 } }
        try await Task.sleep(for: synthDelay)
        if failing.contains(sentence) { throw VoiceError.network("HTTP 500") }
        return SynthesizedSpeech(text: sentence, engine: kind, payload: .clips([Data(count: clipBytes)], .wav))
    }

    func play(_ speech: SynthesizedSpeech) async throws {
        let start = Date()
        try await Task.sleep(for: playDelay)
        state.with { $0.plays.append((speech.text, start, Date())) }
    }

    func speak(_ sentence: String) async throws { try await play(try await synthesize(sentence)) }
    func stop() async {}
}

final class PrefetchTests: XCTestCase {
    func testTwoQueuedSentencesPlayBackToBack() async throws {
        let engine = SlowEngine(synth: .milliseconds(300), play: .milliseconds(100))
        let cache = PrefetchCache(engine: engine)
        await cache.prefetch("First sentence.")
        await cache.prefetch("Second sentence.")
        for text in ["First sentence.", "Second sentence."] {
            let hit = await cache.take(text)
            let s: SynthesizedSpeech
            if let hit { s = hit } else { s = try await engine.synthesize(text) }
            try await engine.play(s)
        }
        let plays = engine.plays
        XCTAssertEqual(plays.map(\.text), ["First sentence.", "Second sentence."])
        let gap = plays[1].start.timeIntervalSince(plays[0].end)
        XCTAssertLessThan(gap, 0.05, "gap between the sentences was \(gap) s")
        XCTAssertEqual(engine.synthesized.count, 2)
    }

    func testPrefetchThenSameTextSynthesizesOnce() async throws {
        let engine = SlowEngine(synth: .milliseconds(50))
        let cache = PrefetchCache(engine: engine)
        await cache.prefetch("Thank you.")
        await cache.prefetch("Thank you.")            // the later `say` with the same text
        let a = await cache.take("Thank you.")
        let b = await cache.take("Thank you.")        // repeat: replays without a second call
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(engine.synthesized, ["Thank you."])
    }

    func testSentenceBound() async {
        let engine = SlowEngine(synth: .milliseconds(1))
        let cache = PrefetchCache(engine: engine)
        for i in 0..<20 { await cache.prefetch("Sentence \(i).") }
        let n = await cache.count
        XCTAssertLessThanOrEqual(n, PrefetchCache.maxSentences)
        let oldest = await cache.take("Sentence 0.")
        XCTAssertNil(oldest, "the least recently used sentence was dropped")
        let newest = await cache.take("Sentence 19.")
        XCTAssertNotNil(newest)
    }

    func testByteBound() async throws {
        let engine = SlowEngine(synth: .milliseconds(1), clipBytes: 3 * 1024 * 1024)
        let cache = PrefetchCache(engine: engine)
        for i in 0..<5 {
            await cache.prefetch("Big \(i).")
            _ = await cache.take("Big \(i).")
        }
        let bytes = await cache.byteCount
        XCTAssertLessThanOrEqual(bytes, PrefetchCache.maxBytes)
        XCTAssertGreaterThan(bytes, 0)
    }

    func testAtMostTwoSynthesesAtOnce() async {
        let engine = SlowEngine(synth: .milliseconds(80))
        let cache = PrefetchCache(engine: engine)
        for i in 0..<6 { await cache.prefetch("S\(i).") }
        for i in 0..<6 { _ = await cache.take("S\(i).") }
        XCTAssertEqual(engine.synthesized.count, 6)
        XCTAssertLessThanOrEqual(engine.peakConcurrency, 2)
    }

    func testClearEmpties() async {
        let engine = SlowEngine(synth: .milliseconds(20))
        let cache = PrefetchCache(engine: engine)
        await cache.prefetch("One."); await cache.prefetch("Two.")
        _ = await cache.take("One.")
        await cache.clear()
        let n = await cache.count, b = await cache.byteCount
        XCTAssertEqual(n, 0); XCTAssertEqual(b, 0)
        let t = await cache.take("One.")
        XCTAssertNil(t)
    }

    func testFailedPrefetchWithoutFallbackLeavesNothing() async {
        let engine = SlowEngine(synth: .milliseconds(5))
        engine.failing = ["Bad."]
        let cache = PrefetchCache(engine: engine)
        await cache.prefetch("Bad.")
        let t = await cache.take("Bad.")
        XCTAssertNil(t)
        let n = await cache.count
        XCTAssertEqual(n, 0)
    }

    func testFailedPrefetchFallsBackToAppleAtPlayTime() async throws {
        let primary = SlowEngine(kind: .openai, synth: .milliseconds(5))
        primary.failing = ["Tell me about yourself."]
        let apple = FakeEngine(.apple)
        let voice = FallbackVoice(primary: primary, fallback: apple)
        let cache = PrefetchCache(engine: voice)
        await cache.prefetch("Tell me about yourself.")
        let taken = await cache.take("Tell me about yourself.")
        let speech = try XCTUnwrap(taken)
        XCTAssertEqual(speech.engine, .apple)
        try await voice.play(speech)
        XCTAssertEqual(apple.spoken, ["Tell me about yourself."])
        XCTAssertEqual(voice.recorder.events.count, 1)
        XCTAssertEqual(voice.recorder.events.first?.primary, .openai)
        XCTAssertTrue(primary.plays.isEmpty)
    }

    // MARK: real engines, stubbed network

    func testCloudSynthesizeDoesNotPlayAndPlayUsesTheClip() async throws {
        let key = dummyKey("pf")
        let wav = Data("RIFF....WAVEfmt ".utf8)
        StubURLProtocol.reset { _ in .init(status: 200, headers: [:], body: wav) }
        let player = FakePlayer(), logs = LogCollector()
        let v = OpenAIVoice(keyProvider: { key }, session: StubURLProtocol.session(), player: player, log: logs.sink)
        let s = try await v.synthesize("Why this role?")
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertEqual(s.byteCount, wav.count)
        try await v.play(s)
        XCTAssertEqual(player.played.map(\.audio), [wav])
        XCTAssertEqual(StubURLProtocol.captured.with { $0.count }, 1)
        XCTAssertTrue(logs.all.allSatisfy { !$0.contains(key) }, "the key never appears in a log line: \(logs.all)")
    }

    func testNoFileCreatedDuringARun() async throws {
        func listing() -> Set<String> {
            var out = Set<String>()
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            for root in [URL(fileURLWithPath: NSTemporaryDirectory()), caches].compactMap({ $0 }) {
                guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in en {
                    if en.level > 3 { en.skipDescendants() }          // the caches tree is huge; audio would sit near the top
                    if !u.pathExtension.isEmpty { out.insert(u.path) }
                }
            }
            return out
        }
        let audioExt: Set<String> = ["wav", "mp3", "m4a", "caf", "aif", "aiff", "aac", "flac", "pcm", "opus", "ogg"]
        let before = listing()
        StubURLProtocol.reset { _ in .init(status: 200, headers: [:], body: Data("RIFF....WAVEfmt ".utf8)) }
        let v = OpenAIVoice(keyProvider: { dummyKey("nf") }, session: StubURLProtocol.session(), player: FakePlayer())
        let cache = PrefetchCache(engine: v)
        for i in 0..<5 { await cache.prefetch("Line \(i).") }
        for i in 0..<5 { if let s = await cache.take("Line \(i).") { try await v.play(s) } }
        await cache.clear()
        let added = listing().subtracting(before).filter { audioExt.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        XCTAssertEqual(added, [], "audio files appeared: \(added)")
    }
}
