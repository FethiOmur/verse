import Foundation
import os
import VerseAudio
import VerseSpeech
@testable import VerseTurns
import XCTest

/// Interim AUTO language (spec 2.5) on the Swift side: the language each turn is sent with, the shadow recognizer's plumbing, and
/// the real runner switching the call's language by itself (scripted recognizers, the real fake-transport brain process).
/// Fictional sentences; nothing is recorded or written.
final class AutoLanguageTurnTests: XCTestCase {

    private func engine(lang: String, room: Bool = false) -> TurnEngine {
        var c = TurnConfig()
        c.lang = lang
        c.roomMode = room
        return TurnEngine(config: c, bank: .empty, facts: .empty)
    }

    private func hear(_ text: String, _ e: TurnEngine, channel: Channel = .remote) async -> [TurnEngine.Timed] {
        var out = await e.ingestTimed(ev(text, at: 10.0, channel: channel))
        out += await e.advance(to: 20)
        return out
    }

    private func langs(_ t: [TurnEngine.Timed]) -> [String?] {
        t.compactMap { x -> String?? in
            switch x.event {
            case .partial, .turn: return .some(x.lang)
            default: return nil
            }
        }
    }

    func testAnEnglishQuestionInAnItalianSessionIsTaggedEnglish() async {
        let out = await hear("Can you walk me through how you built the routing service", engine(lang: "it"))
        XCTAssertEqual(out.turns.count, 1)
        XCTAssertFalse(langs(out).isEmpty)
        XCTAssertTrue(langs(out).allSatisfy { $0 == "en" }, "\(langs(out))")
        XCTAssertEqual(out.turnKinds, [.question], "the English cue list is used for English words, even before the engine switches")
        XCTAssertEqual(out.partials.last?.cue, true)
    }

    func testAnItalianQuestionInAnEnglishSessionIsTaggedItalian() async {
        let out = await hear("Puoi spiegarci come hai costruito il servizio di instradamento", engine(lang: "en"))
        XCTAssertTrue(langs(out).allSatisfy { $0 == "it" }, "\(langs(out))")
        XCTAssertEqual(out.turnKinds, [.question])
    }

    func testTurkishIsTagged() async {
        let out = await hear("Bana en gurur duyduğun projeyi anlatır mısın", engine(lang: "en"))
        XCTAssertTrue(langs(out).allSatisfy { $0 == "tr" }, "\(langs(out))")
    }

    func testAShortOrUnsureTextKeepsTheEnginesLanguage() async {
        let out = await hear("Okay thanks", engine(lang: "it"))
        XCTAssertTrue(langs(out).allSatisfy { $0 == "it" }, "two words are not judged: \(langs(out))")
    }

    func testTheRoomAndTheMeChannelAreTaggedToo() async {
        let room = await hear("Can you tell me how the migration went in the end", engine(lang: "it", room: true))
        XCTAssertTrue(langs(room).allSatisfy { $0 == "en" })
        XCTAssertEqual(room.turnKinds, [.question], "an English question reaches the room gate in an Italian session")
        let me = await hear("We wrote contract tests and a replay harness for it", engine(lang: "it"), channel: .me)
        XCTAssertTrue(langs(me).allSatisfy { $0 == "en" }, "\(langs(me))")
    }

    func testTheLangRidesOnThePartialAndTurnLinesOnly() throws {
        let turn = OutboundEvent.turn(turnID: "r1", speaker: .remote, text: "hi there how are you", addressee: .me, tAudioEnd: 1, kind: .statement)
        let part = OutboundEvent.partial(turnID: "r1", speaker: .remote, text: "hi", cue: false, tAudioEnd: 1)
        let hit = OutboundEvent.bankHit(turnID: "r1", bankID: "b1", score: 0.9)
        XCTAssertFalse(turn.jsonLine().contains("\"lang\""), "without a tag the line is what it always was")
        for (ev, lang) in [(turn, "en"), (part, "tr")] {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ev.jsonLine(lang: lang).utf8)) as? [String: Any])
            XCTAssertEqual(o["lang"] as? String, lang)
            XCTAssertEqual(OutboundEvent.decodeLenient(ev.jsonLine(lang: lang)), ev, "the tag does not break decoding")
        }
        XCTAssertFalse(hit.jsonLine(lang: "en").contains("\"lang\""), "only partial and turn carry it")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(turn.jsonLine().utf8)) as? NSDictionary)
        let nilTag = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(turn.jsonLine(lang: nil).utf8)) as? NSDictionary)
        XCTAssertEqual(plain, nilTag, "no tag: the same object")
    }
}

// MARK: - the shadow recognizer on a listen session

final class ShadowSessionTests: XCTestCase {

    final class Box: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var items: [ShadowResult] = []
        func add(_ r: ShadowResult) { lock.withLockUnchecked { items.append(r) } }
        var all: [ShadowResult] { lock.withLockUnchecked { items } }
    }

    /// Candidates take turns on the same audio; their results carry their language and session times; nothing they hear reaches
    /// the main event stream.
    func testCandidatesTakeTurnsAndTheirResultsAreShadowResultsOnly() async throws {
        let rig = SwapRig()
        rig.prepareDelay = 0.1
        rig.finishDelay = 0.05
        rig.scripts["en|room"] = [.remote: SwapScenario.utterance("so tell me about the project you are proudest of", from: 0.3)]
        rig.scripts["tr|room"] = [.remote: SwapScenario.utterance("bana projeni anlatır mısın bakalım", from: 0.3)]
        var cfg = ListenConfig(lang: "it", remoteBundleIDs: [], micEnabled: true, source: .live)
        cfg.micAsRemote = true
        let session = ListenSession(config: cfg, environment: rig.environment())
        let stream = try await session.start()
        let main = EventBox()
        let drain = Task { for await e in stream { main.add(e) } }
        let box = Box()
        var sc = ShadowConfig(candidates: ["en", "tr"], onResult: { box.add($0) })
        sc.slotSeconds = 2.6
        await session.setShadow(sc)
        try await Task.sleep(for: .seconds(7.5))
        await session.stop()
        await drain.value

        let finals = box.all.filter(\.isFinal)
        XCTAssertEqual(Set(finals.map(\.lang)), ["en", "tr"], "both candidates were heard: \(box.all.map { "\($0.lang):\($0.isFinal)" })")
        XCTAssertTrue(finals.allSatisfy { $0.channel == .remote })
        let en = try XCTUnwrap(finals.first { $0.lang == "en" })
        let tr = try XCTUnwrap(finals.first { $0.lang == "tr" })
        XCTAssertEqual(en.text, "so tell me about the project you are proudest of")
        XCTAssertLessThan(en.end, tr.start, "the English slot comes first and its times are session times")
        XCTAssertGreaterThan(en.start, 0.2, "offset by the audio the candidate had not heard yet")
        XCTAssertTrue(main.all.isEmpty, "the main recognizer (it) had no script: nothing from the shadow leaks into its stream")
    }

    /// A hinted candidate takes over before its turn.
    func testAHintBringsACandidateForward() async throws {
        let rig = SwapRig()
        rig.prepareDelay = 0.05
        rig.finishDelay = 0.05
        rig.scripts["tr|room"] = [.remote: SwapScenario.utterance("bana projeni anlatır mısın bakalım", from: 0.3)]
        var cfg = ListenConfig(lang: "it", remoteBundleIDs: [], micEnabled: true, source: .live)
        cfg.micAsRemote = true
        let session = ListenSession(config: cfg, environment: rig.environment())
        let stream = try await session.start()
        let drain = Task { for await _ in stream {} }
        let box = Box()
        var sc = ShadowConfig(candidates: ["en", "tr"], onResult: { box.add($0) })
        sc.slotSeconds = 30         // en would keep the audio for 30 s
        sc.preferAfterSeconds = 0.5
        await session.setShadow(sc)
        try await Task.sleep(for: .seconds(1.2))
        await session.preferShadow("tr")
        try await Task.sleep(for: .seconds(3.5))
        await session.stop()
        await drain.value
        XCTAssertTrue(box.all.contains { $0.lang == "tr" && $0.isFinal }, "tr was looked at after the hint: \(box.all.map(\.lang))")
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var items: [TranscriptEvent] = []
    func add(_ e: TranscriptEvent) { lock.withLockUnchecked { items.append(e) } }
    var all: [TranscriptEvent] { lock.withLockUnchecked { items } }
}

// MARK: - the runner switching the language by itself

private enum AutoScenario {
    static let it1 = "abbiamo spostato il servizio di instradamento la settimana scorsa"
    static let en1 = "we shipped the new routing service last week and it works well"
    static let en2 = "the migration finished on Tuesday and nobody noticed any downtime"
    static let after = "what was the hardest part of the whole migration"

    /// An Italian call whose recognizer is then made to hear English: two English finals in a row. `auto`: AUTO is on.
    /// Returns when the run is over.
    static func run(auto: Bool, waitForSwitch: Bool, extraSeconds: Double = 3.0, pinAfter: Double? = nil) async throws -> Outcome {
        let rig = SwapRig()
        rig.scripts["it|meeting"] = [.remote: SwapScenario.utterance(it1, from: 0.3)
                                     + SwapScenario.utterance(en1, from: 3.0)
                                     + SwapScenario.utterance(en2, from: 6.8)]
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance(after, from: 0.5)]
        let session = try TempSession()
        defer { session.delete() }
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = rig.environment()
        o.source = nil
        o.lang = "it"
        o.route = .meeting
        o.mode = .unprepared
        o.fakeBrain = true
        o.brainDir = try brainDir()
        o.seconds = 60
        o.drainSeconds = 2
        o.quietSeconds = 0.5
        o.autoLanguage = auto
        o.autoShadow = false
        let picked = Picked()
        o.onAutoLanguage = { picked.add($0) }
        let rec = SinkRecorder()
        o.sink = rec.sink
        o.transcriptURL = session.dir.appendingPathComponent("transcript.jsonl")
        let runner = VerseRunner(options: o)
        let task = Task { await runner.run() }
        let t0 = Date()
        while !rec.all.contains(where: { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }) {
            if Date().timeIntervalSince(t0) > 60 { runner.requestStop(); _ = await task.value; throw XCTSkip("the brain never became ready") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let start = Date()
        if let pin = pinAfter {
            try await Task.sleep(for: .seconds(pin))
            runner.setAutoLanguage(false)
        }
        if waitForSwitch {
            // The switch lands a little after the second English final (about 8.6 s of audio) plus the swap itself.
            while rig.built.filter({ $0.lang == "en" }).isEmpty, Date().timeIntervalSince(start) < 25 { try await Task.sleep(for: .milliseconds(50)) }
        } else {
            try await Task.sleep(for: .seconds(max(0, 11 - Date().timeIntervalSince(start))))
        }
        try await Task.sleep(for: .seconds(extraSeconds))
        runner.requestStop()
        let code = await task.value
        let transcript = (try? String(contentsOf: session.dir.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
        let rows = transcript.split(separator: "\n").compactMap { JSONValue.decodeObject(String($0)) }
        return Outcome(code: code, events: rec.all, built: rig.built, picked: picked.all, transcript: rows)
    }

    struct Outcome {
        var code: Int32
        var events: [RunnerEvent]
        var built: [SwapRig.Built]
        var picked: [String]
        var transcript: [[String: JSONValue]]
        var outbound: [[String: JSONValue]] { events.compactMap { if case .outbound(let o) = $0 { return o }; return nil } }
        var turns: [[String: JSONValue]] { outbound.filter { $0.type == "turn" } }
        var ownMetrics: [[String: JSONValue]] { events.compactMap { if case .metric(let o) = $0 { return o }; return nil } }
        func brainMetrics(_ stage: String) -> [[String: JSONValue]] {
            events.compactMap { if case .brain(let o) = $0, o.type == "metric", o[string: "stage"] == stage { return o }; return nil }
        }
    }

    final class Picked: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLockUnchecked { items.append(s) } }
        var all: [String] { lock.withLockUnchecked { items } }
    }
}

final class AutoLanguageRunTests: XCTestCase {

    nonisolated(unsafe) private static var autoRun: AutoScenario.Outcome?
    nonisolated(unsafe) private static var pinnedRun: AutoScenario.Outcome?

    private func autoRun() async throws -> AutoScenario.Outcome {
        if let o = Self.autoRun { return o }
        let o = try await AutoScenario.run(auto: true, waitForSwitch: true, extraSeconds: 4.5)
        Self.autoRun = o
        return o
    }

    private func pinnedRun() async throws -> AutoScenario.Outcome {
        if let o = Self.pinnedRun { return o }
        let o = try await AutoScenario.run(auto: false, waitForSwitch: false, extraSeconds: 0.5)
        Self.pinnedRun = o
        return o
    }

    /// Italian call, two English finals in a row: the call is on an English pipeline after, the brain was told, nothing restarted.
    func testTwoEnglishFinalsSwitchTheCallToEnglishInPlace() async throws {
        let o = try await autoRun()
        XCTAssertEqual(o.code, 0)
        XCTAssertEqual(o.built.filter { $0.channel == .remote }.map(\.lang), ["it", "en"], "one pipeline for Italian, then one for English: \(o.built)")
        XCTAssertEqual(o.picked, ["en"])
        let auto = o.ownMetrics.filter { $0[string: "stage"] == "lang_auto" }
        XCTAssertEqual(auto.count, 1)
        XCTAssertEqual(auto.first?[string: "from"], "it")
        XCTAssertEqual(auto.first?[string: "to"], "en")
        XCTAssertEqual(o.brainMetrics("lang_change").first?[string: "lang"], "en", "the brain got `control lang`")
        XCTAssertEqual(o.ownMetrics.filter { $0[string: "stage"] == "listen_swap" }.count, 1)
    }

    /// The turns before the switch are tagged with the language of their text (the Italian recognizer said English words), the
    /// ones after with English, and the numbering goes on.
    func testTurnsCarryTheirLanguageAndTheNumberingContinues() async throws {
        let o = try await autoRun()
        let ids = o.turns.compactMap { $0[string: "turn_id"] }
        XCTAssertGreaterThanOrEqual(ids.count, 3, "\(ids)")
        XCTAssertEqual(Set(ids).count, ids.count, "no id twice")
        XCTAssertEqual(ids, ids.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) })
        let byText = Dictionary(o.turns.compactMap { t in t[string: "text"].map { ($0, t[string: "lang"]) } }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byText[AutoScenario.it1], "it")
        XCTAssertEqual(byText[AutoScenario.en1], "en", "English words heard by the Italian recognizer: an English turn")
        XCTAssertEqual(byText[AutoScenario.en2], "en")
        XCTAssertEqual(byText[AutoScenario.after], "en", "after the switch")
        XCTAssertTrue(o.transcript.allSatisfy { $0[string: "lang"] != nil }, "the transcript file keeps the tag")
    }

    /// The same speech with the language pinned: no switch, no detection, and the Italian recognizer goes on.
    func testAPinnedLanguageNeverSwitches() async throws {
        let o = try await pinnedRun()
        XCTAssertEqual(o.built.filter { $0.channel == .remote }.map(\.lang), ["it"])
        XCTAssertTrue(o.picked.isEmpty)
        XCTAssertTrue(o.ownMetrics.filter { $0[string: "stage"] == "lang_auto" }.isEmpty)
        XCTAssertTrue(o.brainMetrics("lang_change").isEmpty)
        // The turns are still tagged by their text: the brain answers English words in English even without a switch.
        let byText = Dictionary(o.turns.compactMap { t in t[string: "text"].map { ($0, t[string: "lang"]) } }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byText[AutoScenario.en1], "en")
    }

    /// Switching AUTO off in the middle of a call pins it where it is.
    func testTurningAutoOffMidCallStopsTheSwitch() async throws {
        let o = try await AutoScenario.run(auto: true, waitForSwitch: false, extraSeconds: 0.5, pinAfter: 1.0)
        XCTAssertEqual(o.built.filter { $0.channel == .remote }.map(\.lang), ["it"], "pinned at 1 s: the English at 3 s and 6 s changes nothing: \(o.built)")
        XCTAssertTrue(o.picked.isEmpty)
    }
}
