import Foundation
import VerseSpeech
import XCTest

final class VerseSpeechTests: XCTestCase {

    /// Samantha (clean en_US voice) through the file source at real-time pace: volatile text arrives before the
    /// final, and the last word shows up <= 1.0 s after the acoustic end of the audio.
    func testFileSourceEnglish() async throws {
        let script = "What is the main risk in the current release plan?"
        let fixture = try SayFixture.make(voice: "Samantha", text: script)
        defer { fixture.delete() }
        let clip = try PCMClip.read(fixture.file)
        let bounds = try XCTUnwrap(clip.speechBounds())

        let session = ListenSession(config: ListenConfig(lang: "en", micEnabled: false, source: .file(fixture.file)))
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        let originValue = await session.channelOrigin(.remote)
        let origin = try XCTUnwrap(originValue)

        XCTAssertFalse(events.isEmpty, "no transcript events")
        XCTAssertTrue(events.allSatisfy { $0.channel == .remote && $0.lang == "en" })
        let firstVolatile = try XCTUnwrap(events.first { !$0.isFinal }, "no volatile event")
        let firstFinal = try XCTUnwrap(events.first { $0.isFinal }, "no final event")
        XCTAssertLessThan(firstVolatile.emittedAt, firstFinal.emittedAt, "volatile text must come before the final")

        let lastWord = try XCTUnwrap(words(script).last)
        let acousticEnd = origin + bounds.end
        let seen = try XCTUnwrap(events.first { words($0.text).contains(lastWord) }, "last word '\(lastWord)' never appeared")
        let lag = seen.emittedAt - acousticEnd
        let finalText = events.filter(\.isFinal).map(\.text).joined(separator: " ")
        print(String(format: "[testFileSourceEnglish] last-word lag %.3f s (word '%@' first in a %@ event); final lag %.3f s; %d events; final text: %@",
                     lag, lastWord, seen.isFinal ? "final" : "volatile", firstFinal.emittedAt - acousticEnd, events.count, finalText))
        XCTAssertLessThanOrEqual(lag, 1.0, "last word appeared \(lag) s after the acoustic end")
    }

    /// Yelda (tr_TR) on DictationTranscriber with frequent finalization: lang is tr, and finals are emitted while
    /// the audio is still playing, not only at the end-of-stream flush.
    func testTurkishDictation() async throws {
        let script = "Bu projeyi ne zaman bitirmeyi planlıyorsun? [[slnc 2500]] Ekip bu kararı destekliyor mu?"
        let fixture = try SayFixture.make(voice: "Yelda", text: script)
        defer { fixture.delete() }
        let clip = try PCMClip.read(fixture.file)

        let session = ListenSession(config: ListenConfig(lang: "tr", micEnabled: false, source: .file(fixture.file)))
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        let originValue = await session.channelOrigin(.remote)
        let origin = try XCTUnwrap(originValue)
        let engines = await session.engineNames()

        XCTAssertEqual(engines[.remote], "DictationTranscriber+frequentFinalization")
        XCTAssertFalse(events.isEmpty, "no transcript events")
        XCTAssertTrue(events.allSatisfy { $0.lang == "tr" && $0.channel == .remote })
        let finals = events.filter(\.isFinal)
        XCTAssertFalse(finals.isEmpty, "no final events")
        let clipEnd = origin + clip.duration
        let finalsDuringAudio = finals.filter { $0.emittedAt < clipEnd }
        let tr = Locale(identifier: "tr_TR")
        print(String(format: "[testTurkishDictation] %d events, %d finals, %d finals before the clip ended (%.2f s); finals: %@",
                     events.count, finals.count, finalsDuringAudio.count, clip.duration,
                     finals.map { String(format: "%.2fs '%@'", $0.emittedAt - origin, $0.text) }.joined(separator: " | ")))
        XCTAssertFalse(finalsDuringAudio.isEmpty, "no final arrived before the end of the audio (frequent finalization not working)")
        let finalWords = finals.flatMap { words($0.text, locale: tr) }
        XCTAssertTrue(finalWords.contains("projeyi") || finalWords.contains("ekip"),
                      "Turkish finals do not contain expected words: \(finalWords)")
    }

    func testEngineRouting() {
        XCTAssertEqual(EngineFactory.defaultKind(for: "en"), .speechTranscriber)
        XCTAssertEqual(EngineFactory.defaultKind(for: "it"), .speechTranscriber)
        XCTAssertEqual(EngineFactory.defaultKind(for: "tr"), .dictationTranscriber)
        XCTAssertThrowsError(try EngineFactory.make(lang: "tr", kind: .whisperKit))
    }

    func testTranscriptEventJSONShape() throws {
        let e = TranscriptEvent(channel: .me, text: "hi", isFinal: true, audioStart: 1, audioEnd: 2, emittedAt: 3, lang: "en")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["channel", "text", "isFinal", "audioStart", "audioEnd", "emittedAt", "lang"])
        XCTAssertEqual(obj["channel"] as? String, "me")
    }
}
