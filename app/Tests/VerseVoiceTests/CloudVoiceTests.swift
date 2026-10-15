import XCTest
@testable import VerseVoice

final class CloudVoiceTests: XCTestCase {
    private let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x01, 0x02, 0x03])
    private let wav = Data("RIFF....WAVEfmt ".utf8)

    override func setUp() { StubURLProtocol.reset() }

    // MARK: request shape

    func testElevenLabsRequestShape() async throws {
        let key = dummyKey("el")
        StubURLProtocol.reset { [mp3] _ in .init(status: 200, headers: ["Content-Type": "audio/mpeg"], body: mp3) }
        let player = FakePlayer(), logs = LogCollector()
        let v = ElevenLabsVoice(voiceID: "TESTVOICE123", keyProvider: { key }, session: StubURLProtocol.session(), player: player, log: logs.sink)

        try await v.speak("Tell me about yourself.")

        let reqs = StubURLProtocol.captured.with { $0 }
        XCTAssertEqual(reqs.count, 1)
        let r = try XCTUnwrap(reqs.first)
        XCTAssertEqual(r.request.httpMethod, "POST")
        let comps = try XCTUnwrap(URLComponents(url: try XCTUnwrap(r.request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "api.elevenlabs.io")
        XCTAssertEqual(comps.path, "/v1/text-to-speech/TESTVOICE123/stream")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "output_format" }?.value, "mp3_44100_128")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "xi-api-key"), key)
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(r.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(comps.url!.absoluteString.contains(key), "the key is never in the URL")
        let body = json(r.body)
        XCTAssertEqual(body["text"] as? String, "Tell me about yourself.")
        XCTAssertEqual(body["model_id"] as? String, ElevenLabsVoice.defaultModelID)
        XCTAssertEqual(ElevenLabsVoice.defaultModelID, "eleven_flash_v2_5")
        XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains(key), "the key is never in the body")

        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(player.played.first?.audio, mp3, "audio goes to the player from memory")
        XCTAssertEqual(player.played.first?.format, .mp3)
        XCTAssertFalse(logs.all.isEmpty, "the engine logs what it does")
        XCTAssertTrue(logs.all.allSatisfy { !$0.contains(key) }, "the key never appears in a log line: \(logs.all)")
    }

    func testOpenAIRequestShape() async throws {
        let key = dummyKey("oa")
        StubURLProtocol.reset { [wav] _ in .init(status: 200, headers: ["Content-Type": "audio/wav"], body: wav) }
        let player = FakePlayer(), logs = LogCollector()
        let v = OpenAIVoice(voiceID: "cedar", keyProvider: { key }, session: StubURLProtocol.session(), player: player, log: logs.sink)

        try await v.speak("Why this role?")

        let r = try XCTUnwrap(StubURLProtocol.captured.with { $0 }.first)
        XCTAssertEqual(r.request.httpMethod, "POST")
        XCTAssertEqual(r.request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(r.request.value(forHTTPHeaderField: "xi-api-key"))
        let body = json(r.body)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["input"] as? String, "Why this role?")
        XCTAssertEqual(body["voice"] as? String, "cedar")
        XCTAssertEqual(body["response_format"] as? String, "wav")
        XCTAssertNil(body["instructions"], "no instructions unless asked")
        XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains(key))
        XCTAssertEqual(player.played.first?.audio, wav)
        XCTAssertEqual(player.played.first?.format, .wav)
        XCTAssertFalse(logs.all.isEmpty)
        XCTAssertTrue(logs.all.allSatisfy { !$0.contains(key) }, "\(logs.all)")
    }

    func testOpenAIInstructionsOnlyForModelsThatSupportThem() async throws {
        StubURLProtocol.reset { [wav] _ in .init(body: wav) }
        let s = StubURLProtocol.session()
        try await OpenAIVoice(instructions: "Calm interviewer.", keyProvider: { dummyKey("a") }, session: s, player: FakePlayer()).speak("Hi.")
        XCTAssertEqual(json(try XCTUnwrap(StubURLProtocol.captured.with { $0 }.first).body)["instructions"] as? String, "Calm interviewer.")
        StubURLProtocol.reset { [wav] _ in .init(body: wav) }
        try await OpenAIVoice(model: "tts-1", instructions: "Calm interviewer.", keyProvider: { dummyKey("a") }, session: s, player: FakePlayer()).speak("Hi.")
        XCTAssertNil(json(try XCTUnwrap(StubURLProtocol.captured.with { $0 }.first).body)["instructions"], "tts-1 ignores instructions: do not send them")
    }

    // MARK: missing key, errors

    func testMissingKeyThrows() async {
        for engine in [ElevenLabsVoice(keyProvider: { nil }, session: StubURLProtocol.session(), player: FakePlayer()) as any VoiceEngine,
                       ElevenLabsVoice(keyProvider: { "  " }, session: StubURLProtocol.session(), player: FakePlayer()),
                       OpenAIVoice(keyProvider: { nil }, session: StubURLProtocol.session(), player: FakePlayer()),
                       OpenAIVoice(keyProvider: { "" }, session: StubURLProtocol.session(), player: FakePlayer())] {
            do { try await engine.speak("Hello."); XCTFail("\(engine.kind) should throw") }
            catch let e as VoiceError { XCTAssertEqual(e, .missingKey, "\(engine.kind)") }
            catch { XCTFail("\(error)") }
        }
        XCTAssertTrue(StubURLProtocol.captured.with { $0 }.isEmpty, "no request without a key")
    }

    func testHTTPErrorMapsToNetworkErrorWithoutLeakingTheKey() async {
        let key = dummyKey("leak")
        // A hostile or buggy server that echoes the credentials back in its error body.
        StubURLProtocol.reset { _ in .init(status: 401, body: Data("{\"detail\":\"bad key \(key)\"}".utf8)) }
        let logs = LogCollector()
        let v = ElevenLabsVoice(keyProvider: { key }, session: StubURLProtocol.session(), player: FakePlayer(), log: logs.sink)
        do { try await v.speak("Hello."); XCTFail("should throw") }
        catch let e as VoiceError {
            guard case .network(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("401"), m)
            XCTAssertFalse(m.contains(key), "the error text must not contain the key")
            XCTAssertFalse(e.description.contains(key))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(logs.all.allSatisfy { !$0.contains(key) }, "\(logs.all)")
    }

    func testTransportFailureMapsToNetworkError() async {
        StubURLProtocol.reset { _ in .init(failure: .notConnectedToInternet) }
        let v = OpenAIVoice(keyProvider: { dummyKey("n") }, session: StubURLProtocol.session(), player: FakePlayer())
        do { try await v.speak("Hello."); XCTFail("should throw") }
        catch let e as VoiceError { if case .network = e {} else { XCTFail("\(e)") } }
        catch { XCTFail("\(error)") }
    }

    func testEmptyAudioAndPlayerFailureAreAudioErrors() async {
        StubURLProtocol.reset { _ in .init(status: 200, body: Data()) }
        let v1 = OpenAIVoice(keyProvider: { dummyKey("e") }, session: StubURLProtocol.session(), player: FakePlayer())
        do { try await v1.speak("Hello."); XCTFail("empty audio should throw") }
        catch let e as VoiceError { if case .audio = e {} else { XCTFail("\(e)") } } catch { XCTFail("\(error)") }

        StubURLProtocol.reset { [mp3] _ in .init(body: mp3) }
        let bad = FakePlayer(); bad.failure = .audio("decode failed")
        let v2 = ElevenLabsVoice(keyProvider: { dummyKey("e") }, session: StubURLProtocol.session(), player: bad)
        do { try await v2.speak("Hello."); XCTFail("player failure should throw") }
        catch let e as VoiceError { XCTAssertEqual(e, .audio("decode failed")) } catch { XCTFail("\(error)") }
    }

    func testBlankSentenceMakesNoRequest() async throws {
        let v = OpenAIVoice(keyProvider: { dummyKey("b") }, session: StubURLProtocol.session(), player: FakePlayer())
        try await v.speak("   \n")
        XCTAssertTrue(StubURLProtocol.captured.with { $0 }.isEmpty)
    }

    func testLongTextIsSplitUnderTheProviderLimit() async throws {
        StubURLProtocol.reset { [wav] _ in .init(body: wav) }
        let player = FakePlayer()
        let v = OpenAIVoice(keyProvider: { dummyKey("l") }, session: StubURLProtocol.session(), player: player)
        let text = String(repeating: "I led the migration and measured the result. ", count: 200) // ~9,000 characters
        try await v.speak(text)
        let inputs = StubURLProtocol.captured.with { $0 }.map { json($0.body)["input"] as? String ?? "" }
        XCTAssertGreaterThanOrEqual(inputs.count, 3)
        XCTAssertTrue(inputs.allSatisfy { $0.count <= 4096 }, "OpenAI input limit is 4096 characters")
        XCTAssertEqual(player.played.count, inputs.count, "every chunk is played, in order")
    }

    // MARK: stop

    func testStopStopsThePlayer() async {
        let player = FakePlayer()
        let v = ElevenLabsVoice(keyProvider: { dummyKey("s") }, session: StubURLProtocol.session(), player: player)
        await v.stop()
        XCTAssertEqual(player.stopCount, 1)
    }

    func testStopDuringFetchSkipsPlaybackWithoutThrowing() async throws {
        StubURLProtocol.reset { [mp3] _ in .init(body: mp3, delay: 0.4) }
        let player = FakePlayer()
        let v = ElevenLabsVoice(keyProvider: { dummyKey("s") }, session: StubURLProtocol.session(), player: player)
        let task = Task { try await v.speak("Long question that the user skips.") }
        try await Task.sleep(nanoseconds: 100_000_000)
        await v.stop()
        try await task.value
        XCTAssertTrue(player.played.isEmpty, "a stopped sentence must not start playing afterwards")
    }

    // MARK: voice lists

    func testElevenLabsVoiceListRequestAndPaging() async throws {
        let key = dummyKey("list")
        StubURLProtocol.reset { cap in
            let q = URLComponents(url: cap.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if q.contains(where: { $0.name == "next_page_token" }) {
                return .init(body: Data(#"{"voices":[{"voice_id":"b2","name":"Bob"}],"has_more":false,"total_count":2,"next_page_token":null}"#.utf8))
            }
            return .init(body: Data(#"{"voices":[{"voice_id":"a1","name":"Alice","category":"premade","labels":{"accent":"american","gender":"female"}}],"has_more":true,"total_count":2,"next_page_token":"tok2"}"#.utf8))
        }
        let voices = try await ElevenLabsVoice.listVoices(keyProvider: { key }, session: StubURLProtocol.session())
        XCTAssertEqual(voices.map(\.id), ["a1", "b2"])
        XCTAssertEqual(voices.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(voices.first?.detail, "premade, american, female")
        let reqs = StubURLProtocol.captured.with { $0 }
        XCTAssertEqual(reqs.count, 2)
        guard reqs.count == 2 else { return }
        XCTAssertEqual(reqs[0].request.httpMethod, "GET")
        let c0 = URLComponents(url: reqs[0].request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c0.host, "api.elevenlabs.io")
        XCTAssertEqual(c0.path, "/v2/voices")
        XCTAssertEqual(c0.queryItems?.first { $0.name == "page_size" }?.value, "100")
        XCTAssertEqual(reqs[0].request.value(forHTTPHeaderField: "xi-api-key"), key)
        let c1 = URLComponents(url: reqs[1].request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c1.queryItems?.first { $0.name == "next_page_token" }?.value, "tok2")

        do { _ = try await ElevenLabsVoice.listVoices(keyProvider: { nil }, session: StubURLProtocol.session()); XCTFail() }
        catch let e as VoiceError { XCTAssertEqual(e, .missingKey) }
    }

    func testOpenAIVoiceNamesDependOnTheModel() {
        let modern = OpenAIVoice.availableVoices(model: "gpt-4o-mini-tts").map(\.id)
        XCTAssertEqual(Set(modern), ["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse", "marin", "cedar"])
        let legacy = OpenAIVoice.availableVoices(model: "tts-1").map(\.id)
        XCTAssertEqual(Set(legacy), ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"])
        XCTAssertTrue(modern.contains(OpenAIVoice.defaultVoice))
    }
}
