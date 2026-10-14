import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Endpoint latency with a Nemotron-style recognizer, the fragment guard and the turn `kind`.
///
/// The timelines are taken from a real `verse-run --file --trace` run of the Nemotron 0.6B engine (560 ms chunks) on
/// synthetic speech with 22 s of leading silence (so the model was warm): text arrives in bursts every ~0.56 s,
/// the last word's token end lies up to 0.5 s before the acoustic end, and a final without any new words follows
/// 0.4-0.8 s after the speech ended.
final class TurnEndpointTests: XCTestCase {

    // MARK: harness

    /// Plays a timeline into the engine the way `verse-run` does: a level tick every 10 ms (loud inside `speech`,
    /// silent outside) and every transcript event at its `emittedAt`. Returns everything the engine emitted.
    private func play(_ engine: TurnEngine, speech: [ClosedRange<Double>], events: [TranscriptEvent], from: Double, until: Double) async -> [TurnEngine.Timed] {
        var out: [TurnEngine.Timed] = []
        var pending = events.sorted { $0.emittedAt < $1.emittedAt }
        var i = Int((from * 100).rounded())
        let end = Int((until * 100).rounded())
        while i <= end {
            let t = Double(i) / 100
            while let e = pending.first, e.emittedAt <= t + 0.0001 {
                out += await engine.ingestTimed(e)
                pending.removeFirst()
            }
            let loud = speech.contains { $0.contains(t) }
            out += await engine.noteRemoteLevel(loud ? -20 : nil, at: t)
            i += 1
        }
        return out
    }

    /// One utterance as Nemotron delivers it: volatile results (cumulative text, range starting at the utterance start)
    /// at `volatile` times, and a final with the same text at `finalAt` (no new words, like the engine's boundary final).
    private func nemotronUtterance(words: [String], start: Double, volatile: [(at: Double, words: Int, audioEnd: Double)],
                                   finalAt: Double?) -> [TranscriptEvent] {
        var evs = volatile.map { v in
            ev(words.prefix(v.words).joined(separator: " "), at: v.at, start: start, end: v.audioEnd)
        }
        if let f = finalAt, let last = volatile.last {
            evs.append(ev(words.prefix(last.words).joined(separator: " "), at: f, final: true, start: start, end: last.audioEnd))
        }
        return evs
    }

    private let statement = "We have been running the pilot for about three months now".split(separator: " ").map(String.init)

    // MARK: plain endpoint, Nemotron timeline

    /// The speech ends at A = 24.61. Volatile bursts at 22.48 ... 24.72, the last one carries the last word with a
    /// token end of 24.28 (0.33 s before the acoustic end); the final follows at 25.28. The old condition ("the
    /// recognizer's range reaches the end of the audio") never held here and the turn waited out the 1.5 s cap.
    func testPlainStatementNemotronBurstTimeline() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let evs = nemotronUtterance(words: statement, start: 21.88,
                                    volatile: [(22.48, 3, 22.12), (23.04, 5, 22.60), (23.61, 7, 23.32), (24.17, 9, 23.88), (24.72, 11, 24.28)],
                                    finalAt: 25.28)
        let out = await play(engine, speech: [21.9...24.61], events: evs, from: 20, until: 28)
        let turn = out.turns.first
        XCTAssertEqual(out.turns.count, 1)
        XCTAssertEqual(turn?.text, "We have been running the pilot for about three months now")
        let after = (turn?.at ?? 99) - 24.61
        XCTAssertLessThanOrEqual(after, 0.8, "turn came \(after) s after the speech ended")
        XCTAssertGreaterThanOrEqual(after, 0.55, "the plain endpoint must still wait for the quiet time")
    }

    /// Eight utterances from the live trace: (acoustic end, last volatile time, its token end, final time).
    /// Every turn must close 0.55-1.0 s after the acoustic end, the median at most 0.8 s.
    func testPlainEndpointLatencyOnRecordedNemotronTimelines() async {
        let rows: [(a: Double, last: Double, aEnd: Double, final: Double)] = [
            (24.61, 24.72, 24.28, 25.28), (31.21, 31.43, 31.32, 31.99), (37.00, 37.04, 37.00, 37.59), (44.51, 44.88, 44.36, 44.94),
            (51.81, 52.16, 51.64, 52.24), (57.81, 57.76, 57.32, 58.44), (65.01, 65.04, 64.68, 65.59), (69.81, 70.08, 69.56, 70.63),
        ]
        var delays: [Double] = []
        for r in rows {
            let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
            let start = r.a - 2.7
            // earlier bursts every 0.56 s before the last one
            var vol: [(at: Double, words: Int, audioEnd: Double)] = []
            var t = r.last - 0.56 * 3
            var n = 4
            while t < r.last - 0.01 { vol.append((t, n, min(t - 0.4, r.aEnd - 0.3))); t += 0.56; n += 2 }
            vol.append((r.last, 11, r.aEnd))
            let evs = nemotronUtterance(words: statement, start: start, volatile: vol, finalAt: r.final)
            let out = await play(engine, speech: [(start + 0.02)...r.a], events: evs, from: r.a - 4, until: r.a + 3)
            XCTAssertEqual(out.turns.count, 1, "row \(r)")
            let d = (out.turns.first?.at ?? 99) - r.a
            delays.append(d)
            XCTAssertLessThanOrEqual(d, 1.0, "row \(r): turn \(d) s after the speech ended")
            XCTAssertGreaterThanOrEqual(d, 0.55, "row \(r): turn \(d) s after the speech ended, before the quiet time")
        }
        let sorted = delays.sorted()
        let p50 = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        print("[testPlainEndpointLatencyOnRecordedNemotronTimelines] delays after acoustic end:",
              delays.map { String(format: "%.2f", $0) }.joined(separator: " "), String(format: "p50 %.2f max %.2f", p50, sorted.last!))
        XCTAssertLessThanOrEqual(p50, 0.8)
    }

    /// The recognizer is silent after the speech ended (no burst, no final): the quiet time plus the catch-up wait
    /// closes the turn, not the old 1.5 s cap.
    func testPlainStatementWithoutAnyResultAfterTheSpeechEnded() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let evs = nemotronUtterance(words: statement, start: 21.88,
                                    volatile: [(22.48, 3, 22.12), (23.04, 5, 22.60), (23.61, 7, 23.32), (24.17, 9, 23.88), (24.40, 11, 24.10)],
                                    finalAt: nil)
        let out = await play(engine, speech: [21.9...24.61], events: evs, from: 20, until: 28)
        let after = (out.turns.first?.at ?? 99) - 24.61
        XCTAssertLessThanOrEqual(after, 0.85, "turn came \(after) s after the speech ended")
        XCTAssertGreaterThanOrEqual(after, 0.55)
        XCTAssertEqual(out.turns.first?.text, "We have been running the pilot for about three months now")
    }

    /// The last words arrive late (the speech ended at 24.61, the burst with "now" only at 25.0): the turn must wait
    /// for them and contain them.
    func testLateBurstStillLandsInTheTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let evs = nemotronUtterance(words: statement, start: 21.88,
                                    volatile: [(22.48, 3, 22.12), (23.04, 5, 22.60), (23.61, 7, 23.32), (24.17, 9, 23.88), (25.0, 11, 24.5)],
                                    finalAt: nil)
        let out = await play(engine, speech: [21.9...24.61], events: evs, from: 20, until: 28)
        XCTAssertEqual(out.turns.first?.text, "We have been running the pilot for about three months now")
    }

    /// A question with a cue keeps the fast endpoint on the same kind of timeline: the last burst comes right after the
    /// quiet began (0.04 s, 0.2 s later), with the token end close to the sound end or 0.3 s before it.
    func testCueQuestionNemotronTimelineStaysFast() async {
        let q = "What results did Lantern deliver".split(separator: " ").map(String.init)
        for (last, tokenEnd, final) in [(37.04, 37.00, 37.59), (37.04, 36.70, 37.59), (37.20, 36.70, 37.60), (37.20, 37.00, 37.60)] {
            let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
            let evs = nemotronUtterance(words: q, start: 35.4,
                                        volatile: [(35.93, 2, 35.88), (36.48, 3, 36.12), (last, 5, tokenEnd)], finalAt: final)
            let out = await play(engine, speech: [35.42...37.00], events: evs, from: 34, until: 40)
            let after = (out.turns.first?.at ?? 99) - 37.0
            XCTAssertEqual(out.turns.first?.text, "What results did Lantern deliver")
            // A result only counts as "the recognizer saw the end" 0.1 s after the quiet began; a burst at +0.04 s waits
            // for the final instead (+0.59 s).
            let bound = last - 37.0 >= 0.1 ? 0.4 : 0.65
            XCTAssertLessThanOrEqual(after, bound, "cue question closed \(after) s after the speech ended (last burst at \(last), token end \(tokenEnd))")
        }
    }

    /// `t_audio_end` of a remote turn is the acoustic end once levels are known, not the (earlier) token end.
    func testTurnAudioEndIsTheAcousticEndWithLevels() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let evs = nemotronUtterance(words: statement, start: 21.88,
                                    volatile: [(22.48, 3, 22.12), (23.04, 5, 22.60), (23.61, 7, 23.32), (24.17, 9, 23.88), (24.72, 11, 24.28)],
                                    finalAt: 25.28)
        let out = await play(engine, speech: [21.9...24.61], events: evs, from: 20, until: 28)
        let t = out.turnAudioEnds.first ?? 0
        XCTAssertEqual(t, 24.6, accuracy: 0.1, "token end was 24.28, the speech ended at 24.61")
    }

    /// A 0.15 s dip inside a sentence ("that makes sense ... and I appreciate the detail", said without a real pause) must
    /// not close the turn: only a quiet of at least the endpoint time does.
    func testShortDipInsideASentenceDoesNotCloseTheTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let evs = [ev("that", at: 49.07, start: 48.56, end: 48.64), ev("that makes sense", at: 49.63, start: 48.56, end: 49.20),
                   ev("that makes sense and I appreciate", at: 50.76, start: 48.56, end: 50.40),
                   ev("that makes sense and I appreciate the detail", at: 51.31, start: 48.56, end: 50.88),
                   ev("that makes sense and I appreciate the detail", at: 51.87, final: true, start: 48.56, end: 50.88)]
        let out = await play(engine, speech: [48.60...49.65, 49.80...51.0], events: evs, from: 40, until: 55)
        XCTAssertEqual(out.turns.map(\.text), ["that makes sense and I appreciate the detail"], "the turn was split: \(out.turns.map(\.text))")
        let after = (out.turns.first?.at ?? 99) - 51.0
        XCTAssertLessThanOrEqual(after, 0.8)
    }

    // MARK: fragment guard

    /// "... and we": cut off in the middle of a clause. No turn until 1.2 s of silence, and the words that follow
    /// within that time belong to the same turn.
    func testFragmentWaitsForLongSilenceWithLevels() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        let words = "We have been running the pilot for about three months and we".split(separator: " ").map(String.init)
        let evs = nemotronUtterance(words: words, start: 21.88,
                                    volatile: [(23.04, 5, 22.60), (24.17, 9, 23.88), (24.72, 12, 24.28)], finalAt: 25.28)
        let out = await play(engine, speech: [21.9...24.61], events: evs, from: 20, until: 28)
        let turn = out.turns.first
        XCTAssertEqual(out.turns.count, 1)
        XCTAssertEqual(turn?.text, "We have been running the pilot for about three months and we")
        let after = (turn?.at ?? 0) - 24.61
        XCTAssertGreaterThanOrEqual(after, 1.15, "a fragment closed after only \(after) s of silence")
        XCTAssertLessThanOrEqual(after, 1.45)
        XCTAssertEqual(out.turnKinds, [.fragment])
    }

    func testFragmentContinuesIntoTheSameTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        // "... and we" at 24.72, the speaker goes on at 25.5 (0.9 s of silence): one turn with both halves.
        let first = nemotronUtterance(words: "We have been running the pilot and we".split(separator: " ").map(String.init), start: 21.88,
                                      volatile: [(23.04, 5, 22.60), (24.17, 7, 23.88), (24.72, 9, 24.28)], finalAt: nil)
        let second = [ev("We have been running the pilot and we ship every week", at: 26.2, start: 21.88, end: 26.0)]
        let out = await play(engine, speech: [21.9...24.61, 25.5...26.0], events: first + second, from: 20, until: 30)
        XCTAssertEqual(out.turns.count, 1, "the fragment must not be emitted on its own: \(out.turns.map(\.text))")
        XCTAssertEqual(out.turns.first?.text, "We have been running the pilot and we ship every week")
        XCTAssertEqual(out.turnKinds, [.statement])
        XCTAssertGreaterThanOrEqual((out.turns.first?.at ?? 0) - 26.0, 0.55)
    }

    func testFragmentWithoutLevelsWaits1200ms() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Tell me about the pilot and", at: 10.0, start: 8))
        let early = await engine.advance(to: 11.1)
        XCTAssertTrue(early.turns.isEmpty, "a text ending in a conjunction closed after 1.1 s")
        let due = await engine.advance(to: 11.25)
        XCTAssertEqual(due.turns.first?.at ?? 0, 11.2, accuracy: 0.05)
        XCTAssertEqual(due.turnKinds, [.fragment])
    }

    func testFewerThanThreeWordsIsAFragment() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Thank you", at: 10.0, start: 9))
        let early = await engine.advance(to: 10.9)
        XCTAssertTrue(early.turns.isEmpty)
        let due = await engine.advance(to: 11.25)
        XCTAssertEqual(due.turns.first?.text, "Thank you")
        XCTAssertEqual(due.turnKinds, [.fragment])
        // three words are enough
        let e2 = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await e2.ingestTimed(ev("That sounds great", at: 20.0, start: 19))
        let t2 = await e2.advance(to: 20.65)
        XCTAssertEqual(t2.turns.first?.at ?? 0, 20.6, accuracy: 0.05)
        XCTAssertEqual(t2.turnKinds, [.statement])
    }

    func testFragmentEnders() {
        for text in ["We shipped it and we", "I wanted to talk about the", "So I think we should go to", "It happened because",
                     "We had a plan but", "The pilot went well so", "Tell me what I", "Can you walk me through",
                     "We worked on the API and um"] {
            XCTAssertTrue(Cues.isFragment(text), "should be a fragment: \(text)")
        }
        for text in ["We shipped it in March", "Why should we hire you", "Where are you from", "What are you working on",
                     "That sounds great.", "Do you have any questions for us", "What did you do", "I think we are done now."] {
            XCTAssertFalse(Cues.isFragment(text), "should be finished: \(text)")
        }
        XCTAssertTrue(Cues.isFragment("Sure."), "fewer than three words")
        XCTAssertTrue(Cues.isFragment("And you"))
        XCTAssertTrue(Cues.isFragment("Ho lavorato con il", lang: "it"))
        XCTAssertFalse(Cues.isFragment("Ho lavorato sul pilota", lang: "it"))
        XCTAssertTrue(Cues.isFragment("Bu projeyi ve", lang: "tr"))
        XCTAssertFalse(Cues.isFragment("Bu proje çok iyi gitti", lang: "tr"))
    }

    /// A new recognizer utterance that starts 0.8 s after a fragment ("We") is its continuation, not a new turn.
    func testGapAfterAFragmentDoesNotSplitTheTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Okay so we", at: 3.0, final: true, start: 0, end: 2.0))
        let out = await engine.ingestTimed(ev("shipped it in March", at: 3.9, start: 2.8, end: 3.8))
        XCTAssertTrue(out.turns.isEmpty, "the fragment was split off: \(out.turns.map(\.text))")
        XCTAssertEqual(out.partials.last?.text, "Okay so we shipped it in March")
        let end = await engine.advance(to: 5.0)
        XCTAssertEqual(end.turns.first?.text, "Okay so we shipped it in March")
        XCTAssertEqual(end.turns.first?.id, "r1")
    }

    // MARK: kind

    func testKindForSixExamples() {
        let cases: [(String, TurnKind)] = [
            ("Can you walk me through your last project", .question),      // cue: auxiliary first
            ("What results did Lantern deliver", .question),               // wh-word
            ("Do you have any questions for us", .question),
            ("We shipped it in March and it went well", .statement),
            ("The delivery volume doubled after the second release", .statement),
            ("We have been running the pilot for about three months and we", .fragment),
            ("Thanks", .fragment),                                          // fewer than three words
            ("So the pilot went well?", .question),                         // closing "?" without a cue
        ]
        for (text, kind) in cases { XCTAssertEqual(Cues.kind(of: text), kind, text) }
    }

    func testTurnEventCarriesKind() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var all: [TurnEngine.Timed] = []
        _ = await engine.ingestTimed(ev("What results did Lantern deliver", at: 1.0, start: 0))
        all += await engine.advance(to: 2.0)
        _ = await engine.ingestTimed(ev("We shipped it in March and it went well", at: 10.0, start: 9))
        all += await engine.advance(to: 11.0)
        _ = await engine.ingestTimed(ev("We shipped it and we", at: 20.0, start: 19))
        all += await engine.advance(to: 22.0)
        XCTAssertEqual(all.turnKinds, [.question, .statement, .fragment])
        // the wire line has it
        let line = all.first { if case .turn = $0.event { return true } else { return false } }?.event.jsonLine() ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        XCTAssertEqual(obj?["kind"] as? String, "question")
    }
}
