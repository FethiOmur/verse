import Foundation
import VerseAudio
@testable import VerseUI
import XCTest

/// The Groq Whisper engine: the request (multipart body, headers), the prompt, the in-memory audio (16 kHz conversion, WAV,
/// duration cap), every fallback to the on-device text, cancel during the upload, the engine choice, and the Apple path left
/// as it was. No network: the client is stubbed (an injected `GroqTranscribing`, or `URLProtocol` for the URLSession client),
/// and no test reads the Keychain.
extension DictationTests {

    /// A key-shaped string that is obviously not a real key.
    nonisolated static let groqTestKey = "gsk_TEST_ONLY_not_a_real_key_0123456789"

    final class StubGroqClient: GroqTranscribing, @unchecked Sendable {
        enum Reply { case text(String), fail(GroqTranscriptionError), hang }
        private let lock = NSLock()
        private let reply: Reply
        private var requests_: [GroqTranscriptionRequest] = []
        private var keys_: [String] = []
        private var timeouts_: [TimeInterval] = []
        private var sawCancel_ = false
        init(_ reply: Reply) { self.reply = reply }
        var requests: [GroqTranscriptionRequest] { lock.withLock { requests_ } }
        var keys: [String] { lock.withLock { keys_ } }
        var timeouts: [TimeInterval] { lock.withLock { timeouts_ } }
        var sawCancel: Bool { lock.withLock { sawCancel_ } }
        func transcribe(_ request: GroqTranscriptionRequest, apiKey: String, timeout: TimeInterval) async throws -> String {
            lock.withLock {
                requests_.append(request)
                keys_.append(apiKey)
                timeouts_.append(timeout)
            }
            switch reply {
            case .text(let s): return s
            case .fail(let e): throw e
            case .hang:
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    lock.withLock { sawCancel_ = true }
                    throw CancellationError()
                }
                return ""
            }
        }
    }

    private func groqWait(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<20_000 {
            if cond() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// One second of a quiet tone at 16 kHz.
    private func oneSecond(_ rec: DictationAudioRecorder, seconds: Double = 1) {
        rec.record([Float](repeating: 0.1, count: Int(16_000 * seconds)), sampleRate: 16_000)
    }

    private struct GroqRig {
        let transcriber: GroqDictationTranscriber
        let inner: FakeTranscriber
        let audio: DictationAudioRecorder
        let client: StubGroqClient
        let logs: Box<[String]>
    }

    private func groqRig(_ reply: StubGroqClient.Reply, apple: String = "cloud kod", key: String? = DictationTests.groqTestKey,
                         seconds: Double = 1, maxSeconds: TimeInterval = DictationAudioRecorder.maxSeconds,
                         sleep: GroqDictationTranscriber.Sleep? = nil) -> GroqRig {
        let inner = FakeTranscriber()
        inner.finishText = apple
        let audio = DictationAudioRecorder(maxSeconds: maxSeconds)
        if seconds > 0 { oneSecond(audio, seconds: seconds) }
        let client = StubGroqClient(reply)
        let logs = Box<[String]>([])
        let t = GroqDictationTranscriber(inner: inner, audio: audio, apiKey: { key }, client: client,
                                         sleep: sleep ?? { try await Task.sleep(for: $0) }, log: { logs.value.append($0) })
        return GroqRig(transcriber: t, inner: inner, audio: audio, client: client, logs: logs)
    }

    private func run(_ g: GroqRig, lang: String = "tr", vocabulary: [String] = ["Claude Code"]) async throws -> String {
        try await g.transcriber.begin(lang: lang, vocabulary: vocabulary, onFailure: { _ in })
        return try await g.transcriber.finish(onCaptureClosed: {})
    }

    private func assertNoSecretsOrText(_ logs: [String], texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for l in logs {
            XCTAssertFalse(l.contains(Self.groqTestKey), "key in log: \(l)", file: file, line: line)
            for t in texts where !t.isEmpty {
                XCTAssertFalse(l.contains(t), "transcript in log: \(l)", file: file, line: line)
            }
        }
    }

    // MARK: request

    func testGroqMultipartBodyAndHeaders() throws {
        let audio = DictationWAV.encode([1, -1, 300])
        let r = GroqTranscriptionRequest(audio: audio, language: "tr", prompt: "Claude Code, Groq.", model: "whisper-large-v3")
        let req = GroqMultipart.urlRequest(r, apiKey: Self.groqTestKey, boundary: "B0UNDARY", timeout: 8)
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.groqTestKey)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B0UNDARY")
        XCTAssertEqual(req.timeoutInterval, 8)
        let body = try XCTUnwrap(req.httpBody)
        let expectedHead = """
        --B0UNDARY\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3\r\n\
        --B0UNDARY\r\nContent-Disposition: form-data; name="language"\r\n\r\ntr\r\n\
        --B0UNDARY\r\nContent-Disposition: form-data; name="prompt"\r\n\r\nClaude Code, Groq.\r\n\
        --B0UNDARY\r\nContent-Disposition: form-data; name="temperature"\r\n\r\n0\r\n\
        --B0UNDARY\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n\
        --B0UNDARY\r\nContent-Disposition: form-data; name="file"; filename="dictation.wav"\r\nContent-Type: audio/wav\r\n\r\n
        """
        var expected = Data(expectedHead.utf8)
        expected.append(audio)
        expected.append(Data("\r\n--B0UNDARY--\r\n".utf8))
        XCTAssertEqual(body, expected)
        XCTAssertNil(body.range(of: Data(Self.groqTestKey.utf8)), "the key is only in the header")
    }

    func testGroqMultipartLeavesOutAnEmptyPrompt() {
        let r = GroqTranscriptionRequest(audio: Data([0, 0]), language: "en", prompt: nil)
        let body = String(decoding: GroqMultipart.body(r, boundary: "X"), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"prompt\""))
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\n\(GroqWhisper.model)\r\n"))
        XCTAssertEqual(GroqWhisper.model, "whisper-large-v3", "the accurate model unless the turbo constant is flipped")
        XCTAssertEqual(GroqWhisper.turboModel, "whisper-large-v3-turbo")
    }

    func testGroqAnswerJSON() throws {
        XCTAssertEqual(try GroqMultipart.text(fromJSON: Data(#"{"text":" Claude Code","x_groq":{"id":"r"}}"#.utf8)), " Claude Code")
        XCTAssertThrowsError(try GroqMultipart.text(fromJSON: Data("<html>".utf8))) {
            XCTAssertEqual($0 as? GroqTranscriptionError, .badResponse)
        }
    }

    // MARK: prompt

    func testGroqPromptIsANaturalListOfTheTerms() {
        XCTAssertEqual(GroqWhisper.prompt(terms: ["Claude Code", " Groq ", "", "Whisper"]), "Claude Code, Groq, Whisper.")
        XCTAssertNil(GroqWhisper.prompt(terms: []))
        XCTAssertNil(GroqWhisper.prompt(terms: ["  "]))
    }

    func testGroqPromptIsCutByWholeTermsUnderTheTokenLimit() {
        // Budget 10 estimated tokens = about 20 bytes: "Alpha, Bravo." is 13 bytes (7), adding ", Charlie" makes 22 (11).
        XCTAssertEqual(GroqWhisper.prompt(terms: ["Alpha", "Bravo", "Charlie", "D"], budget: 10), "Alpha, Bravo.")
        XCTAssertNil(GroqWhisper.prompt(terms: [String(repeating: "x", count: 50)], budget: 10), "a term is never cut in half")
        // A full vocabulary (100 terms, Turkish letters included) stays under Groq's 224-token limit by a margin.
        let terms = (0..<100).map { "Terim çğışöü \($0)" }
        let p = try! XCTUnwrap(GroqWhisper.prompt(terms: terms))
        XCTAssertLessThanOrEqual(GroqWhisper.estimatedTokens(p), GroqWhisper.promptTokenBudget)
        XCTAssertLessThan(GroqWhisper.promptTokenBudget, GroqWhisper.promptTokenLimit)
        XCTAssertLessThanOrEqual(p.utf8.count, 2 * GroqWhisper.promptTokenBudget)
        let kept = p.dropLast().components(separatedBy: ", ")
        XCTAssertEqual(kept, Array(terms.prefix(kept.count)), "whole terms, in order")
        XCTAssertLessThan(kept.count, terms.count)
    }

    // MARK: audio

    func testGroqWAVHeaderAndLength() {
        let samples: [Int16] = [0, 1, -1, 32767, -32768]
        let d = DictationWAV.encode(samples)
        XCTAssertEqual(d.count, 44 + 2 * samples.count)
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        XCTAssertEqual(String(decoding: b[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(u32(4), UInt32(36 + 2 * samples.count))
        XCTAssertEqual(String(decoding: b[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: b[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(u32(16), 16)
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(28), 32_000)
        XCTAssertEqual(u16(32), 2)
        XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(String(decoding: b[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(40), UInt32(2 * samples.count))
        XCTAssertEqual(Int16(bitPattern: u16(44 + 2 * 3)), 32767)
        XCTAssertEqual(Int16(bitPattern: u16(44 + 2 * 4)), -32768)
    }

    func testGroqResamplesTo16kHzWithoutSeamsAcrossChunks() {
        let input = (0..<4800).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        var whole = DictationResampler(), split = DictationResampler()
        var a: [Int16] = [], b: [Int16] = []
        whole.convert(input, sampleRate: 48_000, into: &a)
        var i = 0
        for size in [7, 480, 1, 333, 1024, 2955] {
            split.convert(Array(input[i..<i + size]), sampleRate: 48_000, into: &b)
            i += size
        }
        XCTAssertEqual(i, input.count)
        XCTAssertEqual(a.count, 1600, "0.1 s at 16 kHz")
        XCTAssertEqual(a, b, "chunk boundaries change nothing")
        var c: [Int16] = [], same = DictationResampler()
        same.convert([0.5, -0.5, 1.5], sampleRate: 16_000, into: &c)
        XCTAssertEqual(c, [16384, -16384, 32767], "16 kHz passes through, clipped at full scale")
        var d: [Int16] = [], odd = DictationResampler()
        odd.convert([Float](repeating: 0, count: 4410), sampleRate: 44_100, into: &d)
        XCTAssertEqual(d.count, 1600)
    }

    func testGroqDurationCapKeepsTheUploadWellUnderGroqsLimit() {
        let rec = DictationAudioRecorder(maxSeconds: 1)
        oneSecond(rec, seconds: 0.75)
        XCTAssertFalse(rec.snapshot.overflowed)
        oneSecond(rec, seconds: 0.75)
        let s = rec.snapshot
        XCTAssertTrue(s.overflowed)
        XCTAssertEqual(s.samples.count, 16_000)
        oneSecond(rec)
        XCTAssertEqual(rec.snapshot.samples.count, 16_000, "nothing more after the cap")
        let largest = 44 + Int(DictationAudioRecorder.maxSeconds * 16_000) * 2
        XCTAssertLessThan(largest, 25 * 1024 * 1024 / 2, "the longest upload is under half of the 25 MB free-tier limit")
    }

    // MARK: transcriber

    func testGroqTextBecomesTheTranscript() async throws {
        let g = groqRig(.text(" Claude Code çalışıyor "))
        let text = try await run(g, lang: "tr", vocabulary: ["Claude Code", "Groq"])
        XCTAssertEqual(text, "Claude Code çalışıyor")
        XCTAssertNil(g.transcriber.finishNotice)
        XCTAssertEqual(g.transcriber.outcome, .ok)
        let req = try XCTUnwrap(g.client.requests.first)
        XCTAssertEqual(req.language, "tr")
        XCTAssertEqual(req.prompt, "Claude Code, Groq.")
        XCTAssertEqual(req.model, GroqWhisper.model)
        XCTAssertEqual(req.audio.count, 44 + 16_000 * 2, "one second of 16 kHz 16-bit mono")
        XCTAssertEqual(g.client.keys, [Self.groqTestKey])
        XCTAssertEqual(g.client.timeouts, [GroqWhisper.timeout(audioSeconds: 1)])
        XCTAssertEqual(g.inner.finishCalls, 1, "the Apple engine finished first, as always")
        XCTAssertTrue(g.logs.value.contains { $0.hasPrefix("dictation: groq outcome=ok audio_ms=1000 ms=") }, "\(g.logs.value)")
        assertNoSecretsOrText(g.logs.value, texts: ["Claude Code", "cloud kod"])
    }

    func testGroqTimeoutGrowsALittleWithTheAudio() {
        XCTAssertEqual(GroqWhisper.timeout(audioSeconds: 2), 8.1, accuracy: 1e-9)
        XCTAssertEqual(GroqWhisper.timeout(audioSeconds: 60), 11, accuracy: 1e-9)
        XCTAssertEqual(GroqWhisper.timeout(audioSeconds: 600), 20)
    }

    func testGroqWithoutAKeyUsesTheAppleTextAndSaysSo() async throws {
        let g = groqRig(.text("never"), key: nil)
        let text = try await run(g)
        XCTAssertEqual(text, "cloud kod")
        XCTAssertEqual(g.transcriber.finishNotice, .cloudNoKey)
        XCTAssertEqual(g.transcriber.outcome, .noKey)
        XCTAssertTrue(g.client.requests.isEmpty, "nothing leaves the Mac without a key")
    }

    func testGroqFallbacksUseTheAppleText() async throws {
        let cases: [(StubGroqClient.Reply, GroqDictationOutcome)] = [
            (.fail(.http(401)), .http), (.fail(.http(500)), .http), (.fail(.network), .network),
            (.fail(.badResponse), .badResponse), (.fail(.timeout), .timeout), (.text("  \n"), .empty),
        ]
        for (reply, outcome) in cases {
            let g = groqRig(reply)
            let text = try await run(g)
            XCTAssertEqual(text, "cloud kod", "\(outcome)")
            XCTAssertEqual(g.transcriber.outcome, outcome)
            XCTAssertEqual(g.transcriber.finishNotice, .cloudUnavailable, "\(outcome)")
            XCTAssertEqual(g.client.requests.count, 1)
            assertNoSecretsOrText(g.logs.value, texts: ["cloud kod"])
        }
        let g = groqRig(.fail(.http(429)))
        _ = try await run(g)
        XCTAssertTrue(g.logs.value.contains { $0.contains("outcome=http") && $0.hasSuffix("status=429") }, "\(g.logs.value)")
    }

    func testGroqNoAnswerInTimeFallsBackAndCancelsTheRequest() async throws {
        let g = groqRig(.hang, sleep: { _ in })    // the deadline passes at once
        let text = try await run(g)
        XCTAssertEqual(text, "cloud kod")
        XCTAssertEqual(g.transcriber.outcome, .timeout)
        XCTAssertEqual(g.transcriber.finishNotice, .cloudUnavailable)
        await groqWait("request cancelled") { g.client.sawCancel }
    }

    func testGroqTooLongARecordingIsNotSent() async throws {
        let g = groqRig(.text("never"), seconds: 2, maxSeconds: 1)
        let text = try await run(g)
        XCTAssertEqual(text, "cloud kod")
        XCTAssertEqual(g.transcriber.outcome, .tooLong)
        XCTAssertEqual(g.transcriber.finishNotice, .cloudUnavailable)
        XCTAssertTrue(g.client.requests.isEmpty, "never half a dictation")
    }

    func testGroqNoAudioIsNotSentAndShowsNoNotice() async throws {
        let g = groqRig(.text("never"), apple: "", seconds: 0)
        let text = try await run(g)
        XCTAssertEqual(text, "")
        XCTAssertEqual(g.transcriber.outcome, .tooShort)
        XCTAssertNil(g.transcriber.finishNotice)
        XCTAssertTrue(g.client.requests.isEmpty)
    }

    func testGroqForwardsTheLivePreviewToTheAppleEngine() async throws {
        let g = groqRig(.text("x"))
        g.inner.liveText = "canlı"
        g.inner.meterLevel = 0.2
        XCTAssertEqual(g.transcriber.liveText, "canlı")
        XCTAssertEqual(g.transcriber.takeMeterLevel(), 0.2)
        try await g.transcriber.begin(lang: "it", vocabulary: ["Verse"], onFailure: { _ in })
        XCTAssertEqual(g.inner.began, ["it"])
        XCTAssertEqual(g.inner.vocabularies, [["Verse"]])
    }

    func testGroqAStuckKeychainReadFallsBackInsteadOfHanging() async throws {
        let release = DispatchSemaphore(value: 0)
        let inner = FakeTranscriber()
        inner.finishText = "cloud kod"
        let audio = DictationAudioRecorder()
        oneSecond(audio)
        let client = StubGroqClient(.text("never"))
        let logs = Box<[String]>([])
        // The read returns only after 2 s (or when released): a `security` call waiting on a keychain prompt.
        let t = GroqDictationTranscriber(inner: inner, audio: audio,
                                         apiKey: { _ = release.wait(timeout: .now() + 2); return DictationTests.groqTestKey },
                                         client: client, keySleep: { _ in }, log: { logs.value.append($0) })
        try await t.begin(lang: "tr", vocabulary: [], onFailure: { _ in })
        let text = try await t.finish(onCaptureClosed: {})
        release.signal()
        XCTAssertEqual(text, "cloud kod")
        XCTAssertEqual(t.outcome, .keyTimeout)
        XCTAssertEqual(t.finishNotice, .cloudUnavailable)
        XCTAssertTrue(client.requests.isEmpty, "nothing is sent once the key wait has given up")
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("dictation: groq outcome=key_timeout") }, "\(logs.value)")
    }

    func testGroqCancelPendingStopsTheUploadBeforeItStarts() async throws {
        let g = groqRig(.text("never"))
        try await g.transcriber.begin(lang: "tr", vocabulary: [], onFailure: { _ in })
        g.transcriber.cancelPending()    // synchronous: what the controller calls at Esc, before `cancel`'s task runs
        let text = try await g.transcriber.finish(onCaptureClosed: {})
        XCTAssertEqual(text, "cloud kod")
        XCTAssertTrue(g.client.requests.isEmpty, "no audio leaves the Mac after Esc")
        XCTAssertNil(g.transcriber.finishNotice)
    }

    func testGroqClientsShareOneSession() {
        XCTAssertTrue(URLSessionGroqClient().session === URLSessionGroqClient().session,
                      "one session for the app, not one per dictation")
    }

    func testGroqRecorderReservesTheWholeCapUpFront() {
        let rec = DictationAudioRecorder(maxSeconds: 10)
        XCTAssertGreaterThanOrEqual(rec.capacity, 11 * 16_000, "no reallocation under the lock on the capture thread")
        oneSecond(rec, seconds: 10.5)
        XCTAssertEqual(rec.snapshot.samples.count, 10 * 16_000)
        XCTAssertTrue(rec.snapshot.overflowed)
    }

    // MARK: through the controller

    private func groqControllerRig(_ reply: StubGroqClient.Reply, apple: String = "cloud kod",
                                   key: String? = DictationTests.groqTestKey) -> (Rig, StubGroqClient, Box<[String]>) {
        let client = StubGroqClient(reply)
        let groqLogs = Box<[String]>([])
        let r = rig(lang: "tr", prepare: { $0.finishText = apple }, wrap: { fake in
            let audio = DictationAudioRecorder()
            audio.record([Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
            return GroqDictationTranscriber(inner: fake, audio: audio, apiKey: { key }, client: client,
                                            log: { groqLogs.value.append($0) })
        })
        return (r, client, groqLogs)
    }

    func testGroqTextGoesThroughCorrectionsInsertionAndHistory() async throws {
        let (r, client, groqLogs) = groqControllerRig(.text("Claude Code ile Groq denedim"))
        r.settings.vocabulary = "Claude Code"
        r.settings.corrections = "denedim -> denedik"
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.calls.map(\.text), ["Claude Code ile Groq denedik"], "Groq's text, then the corrections")
        XCTAssertEqual(r.history.last?.text, "Claude Code ile Groq denedik")
        XCTAssertTrue(r.notifier.notices.isEmpty)
        XCTAssertEqual(client.requests.first?.language, "tr")
        XCTAssertEqual(client.requests.first?.prompt, "Claude Code.")
        XCTAssertEqual(r.controller.phase, .idle)
        assertNoSecretsOrText(r.logs.value + groqLogs.value, texts: ["Claude Code ile", "cloud kod"])
    }

    func testGroqFallbackInsertsTheAppleTextWithANotice() async throws {
        let (r, _, _) = groqControllerRig(.fail(.network))
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.calls.map(\.text), ["cloud kod"], "the dictation is never lost")
        XCTAssertEqual(r.notifier.notices, [.cloudUnavailable])
    }

    func testGroqEscDuringTheUploadCancelsItAndInsertsNothing() async throws {
        let (r, client, _) = groqControllerRig(.hang)
        await r.controller.press()
        let stop = Task { await r.controller.press() }
        await groqWait("upload under way") { client.requests.count == 1 }
        XCTAssertEqual(r.controller.phase, .finalising, "the island shows finishing while Groq works")
        r.controller.cancelByKey()
        await r.controller.pendingRelease?.value
        await stop.value
        await groqWait("request cancelled") { client.sawCancel }
        XCTAssertTrue(r.inserter.calls.isEmpty)
        XCTAssertNil(r.history.last)
        XCTAssertEqual(r.notifier.notices, [.cancelled])
        XCTAssertEqual(r.controller.phase, .idle)
        XCTAssertEqual(r.last?.cancelCalls, 1, "the Apple engine is released too")
    }

    // MARK: engine choice and the Apple path

    func testGroqEngineSettingDefaultsToAppleAndPersists() {
        let d = defaults()
        let s = DictationSettings(defaults: d)
        XCTAssertEqual(s.engine, .apple)
        s.engine = .groq
        XCTAssertEqual(DictationSettings(defaults: d).engine, .groq)
        d.set("whisper-on-mars", forKey: "dictationEngine")
        XCTAssertEqual(DictationSettings(defaults: d).engine, .apple, "an unknown value is the default")
    }

    func testGroqEngineFactoryPicksTheTranscriber() throws {
        let client = StubGroqClient(.text("x"))
        let apple = DictationEngineFactory.make(.apple, client: client, apiKey: { nil }, log: { _ in })
        let a = try XCTUnwrap(apple as? AppleDictationTranscriber)
        XCTAssertNil(a.recorder, "the Apple engine keeps no audio")
        let groq = DictationEngineFactory.make(.groq, client: client, apiKey: { nil }, log: { _ in })
        XCTAssertTrue(groq is GroqDictationTranscriber)
        XCTAssertNil(groq.finishNotice)
        XCTAssertNil(apple.finishNotice)
    }

    func testGroqTheAppleCaptureIsUnchangedWithoutARecorder() throws {
        final class ChunkSource: AudioCaptureSource, @unchecked Sendable {
            var routeDescription: String { "test" }
            var onChunk: (@Sendable (AudioChunk) -> Void)?
            func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
                self.onChunk = onChunk
            }
            func stop() {}
            func targetIsProducingOutput() -> Bool? { nil }
            func setEventHandler(_ handler: @escaping @Sendable (CaptureEvent) -> Void) {}
        }
        final class Seen: @unchecked Sendable { var chunks: [AudioChunk] = [] }
        let samples: [Float] = (0..<480).map { Float($0) / 480 - 0.5 }
        for recorder in [nil, DictationAudioRecorder()] as [DictationAudioRecorder?] {
            let inner = ChunkSource(), meter = DictationInputMeter(), seen = Seen()
            let src = MeteredCaptureSource(inner: inner, meter: meter, recorder: recorder)
            try src.start(clock: SessionClock(), onChunk: { seen.chunks.append($0) }, onEnd: {})
            inner.onChunk?(AudioChunk(samples: samples, sampleRate: 48_000, startTime: 1.5))
            XCTAssertEqual(seen.chunks.count, 1)
            XCTAssertEqual(seen.chunks.first?.samples, samples, "the engine gets the same samples")
            XCTAssertEqual(seen.chunks.first?.sampleRate, 48_000)
            XCTAssertEqual(seen.chunks.first?.startTime, 1.5)
            XCTAssertEqual(meter.chunks, 1)
            if let recorder { XCTAssertEqual(recorder.snapshot.samples.count, 160, "10 ms at 16 kHz") }
        }
    }

    func testGroqTheAppleEngineShowsNoExtraNotice() async {
        let r = rig { $0.finishText = "hello" }
        await r.controller.press()
        await r.controller.press()
        XCTAssertEqual(r.inserter.calls.map(\.text), ["hello"])
        XCTAssertTrue(r.notifier.notices.isEmpty)
        XCTAssertFalse(r.logs.value.contains { $0.contains("groq") })
    }

    func testGroqNoticesAndSettingTexts() {
        XCTAssertEqual(DictationNotice.cloudUnavailable.text, "Groq unavailable: used the on-device text")
        XCTAssertEqual(DictationNotice.cloudNoKey.text, "No Groq key: used the on-device text")
        XCTAssertTrue(DictationNotice.cloudUnavailable.showsInIsland)
        XCTAssertFalse(DictationNotice.cloudUnavailable.isFailure)
        XCTAssertTrue(SettingsDictationSection.engineDetail(.apple).contains("never leaves the Mac"))
        XCTAssertTrue(SettingsDictationSection.engineDetail(.groq).contains("sent to Groq"))
        XCTAssertTrue(SettingsDictationSection.status(hotKeyRefused: false, fnSpaceActive: true, engine: .groq).contains("Groq"))
        XCTAssertFalse(SettingsDictationSection.status(hotKeyRefused: false, fnSpaceActive: true).contains("Groq"))
        XCTAssertTrue(SettingsDictationSection.groqKeyNote.contains("-s verse-groq"))
        XCTAssertFalse(GroqKey.terminalCommand.contains("gsk_"), "the command never carries a key")
        XCTAssertEqual(GroqKey.service, "verse-groq")
    }
}

/// The URLSession client against a stubbed `URLProtocol`: status codes and the answer are mapped; nothing reaches the network.
final class DictationGroqURLSessionTests: XCTestCase {
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var lastAuthorization: String?
        nonisolated(unsafe) static var lastContentType: String?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            Self.lastContentType = request.value(forHTTPHeaderField: "Content-Type")
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> URLSessionGroqClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSessionGroqClient(session: URLSession(configuration: cfg))
    }

    private let request = GroqTranscriptionRequest(audio: DictationWAV.encode([0, 1]), language: "en", prompt: nil)

    func testDictationGroqClientReadsTheText() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"text":"hello"}"#.utf8)
        let text = try await client().transcribe(request, apiKey: DictationTests.groqTestKey, timeout: 8)
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(StubProtocol.lastAuthorization, "Bearer \(DictationTests.groqTestKey)")
        XCTAssertTrue(StubProtocol.lastContentType?.hasPrefix("multipart/form-data; boundary=verse-") == true)
    }

    func testDictationGroqClientMapsErrors() async {
        StubProtocol.status = 401
        StubProtocol.body = Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8)
        do {
            _ = try await client().transcribe(request, apiKey: DictationTests.groqTestKey, timeout: 8)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GroqTranscriptionError, .http(401)) }
        StubProtocol.status = 200
        StubProtocol.body = Data("not json".utf8)
        do {
            _ = try await client().transcribe(request, apiKey: DictationTests.groqTestKey, timeout: 8)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GroqTranscriptionError, .badResponse) }
    }

    func testTheSubtitleCreditHallucinationIsRemoved() {
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Yarın toplantı var. Altyazı M.K."), "Yarın toplantı var.")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Yarın toplantı var Altyazı M.K"), "Yarın toplantı var")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("altyazı m.k. Merhaba, nasılsın?"), "Merhaba, nasılsın?")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Bunu yap ALTYAZI MK. sonra bak."), "Bunu yap sonra bak.")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Altyazi M. K."), "")
        XCTAssertEqual(GroqWhisper.strippingArtifacts(" Altyazı M.K. "), "")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Altyazı ekle, MKV dosyasına."), "Altyazı ekle, MKV dosyasına.")
        XCTAssertEqual(GroqWhisper.strippingArtifacts("Filmin altyazısı yok."), "Filmin altyazısı yok.")
    }
}
