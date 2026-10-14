import XCTest
@testable import VerseVoice

final class FallbackAndTextTests: XCTestCase {
    func testTextVoiceInstant() async throws {
        let v = TextVoice()
        XCTAssertEqual(v.kind, .text)
        let t0 = Date()
        try await v.speak("Tell me about a time you led a project.")
        await v.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05, "TextVoice must return at once")
    }

    func testFallbackOnError() async throws {
        let primary = FakeEngine(.elevenlabs, failure: VoiceError.network("HTTP 503"))
        let apple = FakeEngine(.apple)
        let reported = Locked<[FallbackEvent]>([])
        let v = FallbackVoice(primary: primary, fallback: apple, onFallback: { e in reported.with { $0.append(e) } })

        try await v.speak("First question.")

        XCTAssertEqual(primary.spoken, ["First question."])
        XCTAssertEqual(apple.spoken, ["First question."], "the same sentence is spoken by the fallback")
        XCTAssertEqual(v.recorder.events.count, 1)
        XCTAssertEqual(v.recorder.events.first?.primary, .elevenlabs)
        XCTAssertEqual(v.recorder.events.first?.error, .network("HTTP 503"))
        XCTAssertEqual(reported.with { $0 }.count, 1, "onFallback fires once per fallback")
    }

    func testFallbackIsPerSentence() async throws {
        let primary = FakeEngine(.openai, failure: VoiceError.missingKey)
        let apple = FakeEngine(.apple)
        let v = FallbackVoice(primary: primary, fallback: apple)
        try await v.speak("One.")
        primary.failure = nil
        try await v.speak("Two.")
        XCTAssertEqual(primary.spoken, ["One.", "Two."], "the primary is retried on the next sentence")
        XCTAssertEqual(apple.spoken, ["One."])
        XCTAssertEqual(v.recorder.events.count, 1)
    }

    func testNoFallbackWhenPrimarySucceeds() async throws {
        let primary = FakeEngine(.openai)
        let apple = FakeEngine(.apple)
        let v = FallbackVoice(primary: primary, fallback: apple)
        XCTAssertEqual(v.kind, .openai, "reports the primary's kind")
        try await v.speak("Hello.")
        XCTAssertEqual(apple.spoken, [])
        XCTAssertTrue(v.recorder.events.isEmpty)
    }

    func testCancellationDoesNotFallBack() async {
        let primary = FakeEngine(.elevenlabs, failure: CancellationError())
        let apple = FakeEngine(.apple)
        let v = FallbackVoice(primary: primary, fallback: apple)
        do { try await v.speak("x"); XCTFail("should rethrow") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(apple.spoken, [])
        XCTAssertTrue(v.recorder.events.isEmpty)
    }

    func testFallbackFailureIsRethrown() async {
        let primary = FakeEngine(.elevenlabs, failure: VoiceError.network("down"))
        let apple = FakeEngine(.apple, failure: VoiceError.audio("no output device"))
        let v = FallbackVoice(primary: primary, fallback: apple)
        do { try await v.speak("x"); XCTFail("should throw") } catch let e as VoiceError { XCTAssertEqual(e, .audio("no output device")) } catch { XCTFail("\(error)") }
        XCTAssertEqual(v.recorder.events.count, 1, "the fallback attempt is still recorded")
    }

    func testFallbackStopStopsBoth() async {
        let primary = FakeEngine(.openai), apple = FakeEngine(.apple)
        let v = FallbackVoice(primary: primary, fallback: apple)
        await v.stop()
        XCTAssertEqual(primary.stopCount, 1)
        XCTAssertEqual(apple.stopCount, 1)
    }

    func testFactoryMakesEachKind() {
        XCTAssertTrue(VoiceFactory.make(.text, voiceID: nil) is TextVoice)
        XCTAssertTrue(VoiceFactory.make(.apple, voiceID: nil) is AppleVoice)
        let el = VoiceFactory.make(.elevenlabs, voiceID: "abc123") as? ElevenLabsVoice
        XCTAssertEqual(el?.voiceID, "abc123")
        let oa = VoiceFactory.make(.openai, voiceID: "cedar") as? OpenAIVoice
        XCTAssertEqual(oa?.voiceID, "cedar")
        XCTAssertEqual((VoiceFactory.make(.openai, voiceID: nil) as? OpenAIVoice)?.voiceID, OpenAIVoice.defaultVoice)
        XCTAssertEqual((VoiceFactory.make(.elevenlabs, voiceID: nil) as? ElevenLabsVoice)?.voiceID, ElevenLabsVoice.defaultVoiceID)
        for k in [VoiceKind.apple, .elevenlabs, .openai, .text] { XCTAssertEqual(VoiceFactory.make(k, voiceID: nil).kind, k) }
    }

    func testChunkingKeepsSentencesWholeWhenPossible() {
        XCTAssertEqual(VoiceText.chunks("Short one.", maxLength: 100), ["Short one."])
        let text = String(repeating: "This is a sentence. ", count: 10).trimmingCharacters(in: .whitespaces)
        let parts = VoiceText.chunks(text, maxLength: 50)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 50 }, "\(parts)")
        XCTAssertEqual(parts.joined(separator: " "), text, "nothing lost or duplicated")
        let blob = String(repeating: "x", count: 130)
        XCTAssertEqual(VoiceText.chunks(blob, maxLength: 50).map(\.count), [50, 50, 30], "an unbreakable run is hard-split")
        XCTAssertEqual(VoiceText.chunks("   ", maxLength: 50), [], "blank text has nothing to say")
    }
}
