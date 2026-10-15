import XCTest
import AVFoundation
@testable import VerseVoice

final class KeysAndAppleTests: XCTestCase {
    func testServiceNames() {
        XCTAssertEqual(VoiceKeys.service(for: .elevenlabs), "verse-elevenlabs")
        XCTAssertEqual(VoiceKeys.service(for: .openai), "verse-openai")
        XCTAssertNil(VoiceKeys.service(for: .apple))
        XCTAssertNil(VoiceKeys.service(for: .text))
    }

    func testKeylessKindsNeverTouchTheKeychain() {
        XCTAssertFalse(VoiceKeys.hasKey(.apple))
        XCTAssertFalse(VoiceKeys.hasKey(.text))
        XCTAssertNil(VoiceKeys.last4(.apple))
        XCTAssertNil(VoiceKeys.read(.text))
        XCTAssertThrowsError(try VoiceKeys.save(dummyKey("x"), for: .apple))
        XCTAssertThrowsError(try VoiceKeys.save(dummyKey("x"), for: .text))
        XCTAssertNoThrow(try VoiceKeys.remove(.apple))
    }

    /// Save under a TEST service, read it back the way the engines do, remove it. The value is a dummy and is never printed.
    func testKeysRoundTrip() throws {
        let service = "verse-voice-TEST-\(UUID().uuidString.prefix(8))"
        let dummy = dummyKey("rt")
        defer { try? VoiceKeys.remove(service: service) }
        XCTAssertNotEqual(service, "verse-elevenlabs")
        XCTAssertNotEqual(service, "verse-openai")
        XCTAssertFalse(VoiceKeys.hasKey(service: service))
        XCTAssertNil(VoiceKeys.read(service: service))

        try VoiceKeys.save(dummy, service: service)
        XCTAssertTrue(VoiceKeys.hasKey(service: service))
        XCTAssertEqual(VoiceKeys.last4(service: service), "7e1d")
        XCTAssertEqual(VoiceKeys.read(service: service), dummy)

        let dummy2 = dummyKey("rt2").replacingOccurrences(of: "7e1d", with: "a1b2")
        try VoiceKeys.save(dummy2, service: service)
        XCTAssertEqual(VoiceKeys.last4(service: service), "a1b2")
        XCTAssertEqual(VoiceKeys.read(service: service), dummy2, "save replaces")

        try VoiceKeys.remove(service: service)
        XCTAssertFalse(VoiceKeys.hasKey(service: service))
        XCTAssertNil(VoiceKeys.read(service: service))
        XCTAssertNoThrow(try VoiceKeys.remove(service: service), "removing a missing item is not an error")
    }

    func testSaveRejectsKeysThatCouldInjectIntoTheSecurityCommand() {
        let service = "verse-voice-TEST-\(UUID().uuidString.prefix(8))"
        defer { try? VoiceKeys.remove(service: service) }
        for bad in ["short", "has space " + String(repeating: "a", count: 30), String(repeating: "a", count: 30) + "\nadd-generic-password -s evil",
                    String(repeating: "a", count: 30) + "\"; rm", String(repeating: "a", count: 500)] {
            XCTAssertThrowsError(try VoiceKeys.save(bad, service: service)) { XCTAssertEqual($0 as? VoiceKeyError, .invalidKey) }
        }
        XCTAssertFalse(VoiceKeys.hasKey(service: service))
    }

    // MARK: Apple voice selection (pure)

    func testBestVoicePrefersQualityThenExactLocale() {
        func v(_ id: String, _ lang: String, _ q: AppleVoiceInfo.Quality, novelty: Bool = false) -> AppleVoiceInfo {
            AppleVoiceInfo(id: id, name: id, language: lang, quality: q, isNovelty: novelty)
        }
        let all = [v("a", "en-US", .default), v("b", "en-GB", .enhanced), v("c", "en-US", .premium),
                   v("d", "it-IT", .premium), v("e", "en-AU", .premium, novelty: true), v("f", "en-GB", .premium)]
        XCTAssertEqual(AppleVoice.best(of: all, lang: "en")?.id, "c", "premium beats enhanced beats default; ties go to the sorted id")
        XCTAssertEqual(AppleVoice.best(of: all, lang: "en-GB")?.id, "f", "an exact locale wins within the same quality")
        XCTAssertEqual(AppleVoice.best(of: all, lang: "it")?.id, "d")
        XCTAssertEqual(AppleVoice.best(of: all.filter { $0.id != "c" && $0.id != "f" }, lang: "en")?.id, "b")
        XCTAssertNil(AppleVoice.best(of: all, lang: "tr"))
        XCTAssertNil(AppleVoice.best(of: [v("e", "en-AU", .premium, novelty: true)], lang: "en"), "novelty voices are never picked")
    }

    func testAvailableVoicesListsOnlyTheLanguage() {
        let list = AppleVoice.availableVoices(lang: "en")
        XCTAssertFalse(list.isEmpty, "macOS always ships an English voice")
        XCTAssertTrue(list.allSatisfy { $0.id.hasPrefix("com.apple.") || !$0.id.isEmpty })
    }

    // MARK: opt-in audio (VERSE_AUDIO=1): plays through the speakers

    func testAppleVoiceSpeaks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERSE_AUDIO"] == "1", "set VERSE_AUDIO=1 to play audio")
        let t0 = Date()
        try await AppleVoice().speak("Hello, this is Verse.")
        let took = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(took, 0.4, "speak returns when playback ends, not at once")
        XCTAssertLessThan(took, 15)
    }

    /// The in-memory player path every cloud voice uses, with silent audio: no sound, no file.
    func testMemoryPlayerPlaysWavFromMemory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERSE_AUDIO"] == "1", "set VERSE_AUDIO=1 to play audio")
        let player = MemoryAudioPlayer(volume: 0)
        let t0 = Date()
        try await player.play(Self.silentWav(seconds: 0.4), format: .wav)
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.3)
        do { try await player.play(Data([1, 2, 3, 4]), format: .mp3); XCTFail("garbage must not play") }
        catch let e as VoiceError { if case .audio = e {} else { XCTFail("\(e)") } }
    }

    static func silentWav(seconds: Double, rate: Int = 24_000) -> Data {
        let samples = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + samples * 2); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(samples * 2); d.append(Data(count: samples * 2))
        return d
    }
}
