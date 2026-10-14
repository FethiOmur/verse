import Foundation
import VerseSpeech
import VerseTurns
import XCTest

final class TurnLogicTests: XCTestCase {

    // MARK: cues

    func testCueEnglish() {
        XCTAssertTrue(Cues.hasCue("Can you walk me through your last project", lang: "en"))
        XCTAssertFalse(Cues.hasCue("I worked on the API", lang: "en"))
        XCTAssertFalse(Cues.hasCue("Could you um", lang: "en"), "a hesitation tail never sets the cue")
        XCTAssertFalse(Cues.hasCue("Can you walk me through uh", lang: "en"))
        // wh-words, auxiliary-first order, "tell me", "walk me through"
        XCTAssertTrue(Cues.hasCue("What results did Lantern deliver", lang: "en"))
        XCTAssertTrue(Cues.hasCue("Do you have any questions for us", lang: "en"))
        XCTAssertTrue(Cues.hasCue("Have you worked with route planning", lang: "en"))
        XCTAssertTrue(Cues.hasCue("Alex, how would you approach this", lang: "en"))
        XCTAssertTrue(Cues.hasCue("so tell me about the pilot", lang: "en"))
        XCTAssertTrue(Cues.hasCue("I want you to walk me through the design", lang: "en"))
        XCTAssertTrue(Cues.hasCue("Thanks. Why do you want to join", lang: "en"))
        // statements stay quiet, also with wh-words in the middle of a clause
        XCTAssertFalse(Cues.hasCue("The thing I liked most about the project", lang: "en"))
        XCTAssertFalse(Cues.hasCue("We shipped it in March and it went well", lang: "en"))
        XCTAssertFalse(Cues.hasCue("", lang: "en"))
    }

    func testCueItalianAndTurkish() {
        XCTAssertTrue(Cues.hasCue("Come hai gestito il progetto", lang: "it"))
        XCTAssertTrue(Cues.hasCue("Perché vuoi lavorare con noi", lang: "it"))
        XCTAssertTrue(Cues.hasCue("Mi può raccontare del pilota", lang: "it"))
        XCTAssertFalse(Cues.hasCue("Ho lavorato sul pilota", lang: "it"))
        XCTAssertFalse(Cues.hasCue("Come ehm", lang: "it"))
        XCTAssertTrue(Cues.hasCue("Bu projeyi bitirdin mi", lang: "tr"))
        XCTAssertTrue(Cues.hasCue("Bunu nasıl yaptın", lang: "tr"))
        XCTAssertTrue(Cues.hasCue("Bu iş ne zaman bitecek", lang: "tr"))
        XCTAssertTrue(Cues.hasCue("Hangi aracı kullandınız", lang: "tr"))
        XCTAssertFalse(Cues.hasCue("Bu proje çok iyi gitti", lang: "tr"))
        XCTAssertFalse(Cues.hasCue("Nasıl şey", lang: "tr"))
    }

    func testEndsComplete() {
        XCTAssertTrue(Cues.endsComplete("Can you walk me through your last project", lang: "en"))
        XCTAssertFalse(Cues.endsComplete("Can you walk me through", lang: "en"), "ends in a preposition")
        XCTAssertFalse(Cues.endsComplete("what did you do and", lang: "en"), "ends in a conjunction")
        XCTAssertFalse(Cues.endsComplete("what is the", lang: "en"))
        XCTAssertFalse(Cues.endsComplete("Can you", lang: "en"))
        XCTAssertTrue(Cues.endsComplete("Why should we hire you", lang: "en"))
        XCTAssertFalse(Cues.endsComplete("could you um", lang: "en"))
    }

    // MARK: endpoint

    func testEndpointCueFast() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        // A finished cue question frozen from t = 10.0: the turn is due at 10.3 (+-50 ms).
        let first = await engine.ingestTimed(ev("Can you walk me through your last project", at: 10.0))
        XCTAssertTrue(first.turns.isEmpty)
        XCTAssertTrue(first.partials.first?.cue == true)
        let early = await engine.advance(to: 10.25)
        XCTAssertTrue(early.turns.isEmpty, "turn came before 300 ms")
        let due = await engine.advance(to: 10.36)
        XCTAssertEqual(due.turns.count, 1)
        XCTAssertEqual(due.turns.first?.at ?? 0, 10.3, accuracy: 0.05)
        XCTAssertEqual(due.turns.first?.id, "r1")

        // A statement waits 600 ms.
        _ = await engine.ingestTimed(ev("I worked on the API", at: 20.0, start: 19))
        let a = await engine.advance(to: 20.5)
        XCTAssertTrue(a.turns.isEmpty)
        let b = await engine.advance(to: 20.65)
        XCTAssertEqual(b.turns.first?.at ?? 0, 20.6, accuracy: 0.05)
        XCTAssertEqual(b.turns.first?.id, "r2")

        // A cue question that is not finished ("... walk me through") ends in a preposition: a fragment, which
        // neither uses the fast endpoint nor the 600 ms one but waits for 1.2 s of silence.
        _ = await engine.ingestTimed(ev("Can you walk me through", at: 30.0, start: 29))
        let c = await engine.advance(to: 30.65)
        XCTAssertTrue(c.turns.isEmpty, "an unfinished clause must not use the fast or the plain endpoint")
        let d = await engine.advance(to: 31.25)
        XCTAssertEqual(d.turns.first?.at ?? 0, 31.2, accuracy: 0.05)
        XCTAssertEqual(d.turnKinds, [.fragment])
    }

    func testTextChangeResetsEndpoint() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("What results did Lantern", at: 5.0))
        let mid = await engine.advance(to: 5.2)
        XCTAssertTrue(mid.turns.isEmpty)
        _ = await engine.ingestTimed(ev("What results did Lantern deliver", at: 5.25))
        let still = await engine.advance(to: 5.45)
        XCTAssertTrue(still.turns.isEmpty, "the new words restart the quiet time")
        let done = await engine.advance(to: 5.6)
        XCTAssertEqual(done.turns.first?.text, "What results did Lantern deliver")
        XCTAssertEqual(done.turns.first?.at ?? 0, 5.55, accuracy: 0.05)
    }

    func testMeStartsEndsTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Can you walk me through your last project", at: 10.0))
        // Alex starts talking at 10.1, long before the 300 ms timeout.
        let out = await engine.ingestTimed(ev("Sure", at: 10.1, channel: .me, start: 10.0))
        let turns = out.turns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, .remote)
        XCTAssertEqual(turns.first?.id, "r1")
        XCTAssertEqual(turns.first?.at ?? 0, 10.1, accuracy: 0.001, "emitted immediately")
        // The me turn is its own turn, ended by quiet or by the next remote event.
        let later = await engine.advance(to: 10.9)
        let meTurn = later.turns.first
        XCTAssertEqual(meTurn?.id, "m1")
        XCTAssertEqual(meTurn?.speaker, .me)
        XCTAssertEqual(meTurn?.text, "Sure")
        XCTAssertEqual(meTurn?.addressee, .unknown)
    }

    func testRemoteAfterMeEndsMeTurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Well I built the pipeline", at: 1.0, channel: .me))
        let out = await engine.ingestTimed(ev("Okay and what about the cost", at: 1.3, start: 1.0))
        XCTAssertEqual(out.turns.map(\.id), ["m1"])
        XCTAssertEqual(out.partials.first?.id, "r1")
        // The question started right after Alex stopped talking: it is for Alex.
        let end = await engine.advance(to: 3.0)
        XCTAssertEqual(end.turns.first?.addressee, .me)
    }

    func testHesitationOnlyTurnIsDropped() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("um", at: 1.0))
        let out = await engine.advance(to: 3.0)
        XCTAssertTrue(out.turns.isEmpty)
    }

    // MARK: addressee

    func testAddressee() async {
        let cfg = TurnConfig(ownerName: "Alex", otherNames: ["Marco"])
        func addressee(_ text: String) async -> Addressee? {
            let engine = TurnEngine(config: cfg, bank: .empty, facts: .empty)
            _ = await engine.ingestTimed(ev(text, at: 1.0))
            return await engine.advance(to: 3.0).turns.first?.addressee
        }
        let a1 = await addressee("Alex, how would you approach the migration")
        let a2 = await addressee("Marco, can you share the numbers")
        let a3 = await addressee("What is the status of the rollout")
        let a4 = await addressee("What would your first month look like")
        let a5 = await addressee("Marco and Alex, what do you think")
        XCTAssertEqual(a1, .me)
        XCTAssertEqual(a2, .other)
        XCTAssertEqual(a3, .unknown)
        XCTAssertEqual(a4, .me, "second person")
        XCTAssertEqual(a5, .me, "the owner's name wins when both are named")

        // The recognizer's spelling of the name counts through aliases.
        let aliased = TurnEngine(config: TurnConfig(ownerName: "Alex", ownerAliases: ["Fi", "Festi"]), bank: .empty, facts: .empty)
        _ = await aliased.ingestTimed(ev("Fi, what is the plan", at: 1.0))
        let r = await aliased.advance(to: 3.0)
        XCTAssertEqual(r.turns.first?.addressee, .me)
    }

    func testAddresseeAfterMeTurnWithin3s() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("That is how we did it", at: 1.0, channel: .me))
        _ = await engine.advance(to: 2.0)                         // the me turn ends at 1.0 (last text change)
        _ = await engine.ingestTimed(ev("What was the hardest part", at: 3.5, start: 3.0))
        let near = await engine.advance(to: 5.0)
        XCTAssertEqual(near.turns.first?.addressee, .me, "a question 2.5 s after Alex spoke is for Alex")

        let engine2 = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine2.ingestTimed(ev("That is how we did it", at: 1.0, channel: .me))
        _ = await engine2.advance(to: 2.0)
        _ = await engine2.ingestTimed(ev("What was the hardest part", at: 8.0, start: 7.5))
        let far = await engine2.advance(to: 9.0)
        XCTAssertEqual(far.turns.first?.addressee, .unknown)
    }

    func testAddresseeItalianTurkish() async {
        let it = TurnEngine(config: TurnConfig(lang: "it"), bank: .empty, facts: .empty)
        _ = await it.ingestTimed(ev("Come hai gestito tu il progetto", at: 1.0))
        let itOut = await it.advance(to: 3.0)
        XCTAssertEqual(itOut.turns.first?.addressee, .me)
        let tr = TurnEngine(config: TurnConfig(lang: "tr"), bank: .empty, facts: .empty)
        _ = await tr.ingestTimed(ev("Bu projeyi ne zaman bitirmeyi planlıyorsun", at: 1.0))
        let trOut = await tr.advance(to: 3.0)
        XCTAssertEqual(trOut.turns.first?.addressee, .me)
    }

    // MARK: transcript assembly

    func testSegmentsFinalReplacesVolatileAndNextSegmentAppends() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("tell me about", at: 1.0, start: 0, end: 1.0))
        _ = await engine.ingestTimed(ev("tell me about the pilot", at: 1.5, start: 0, end: 1.5))
        // a final settles the range and corrects a word
        _ = await engine.ingestTimed(ev("Tell me about the pilot,", at: 1.7, final: true, start: 0, end: 1.6))
        // the next volatile result starts where the final ended
        let out = await engine.ingestTimed(ev("and the courier", at: 1.9, start: 1.6, end: 1.9))
        XCTAssertEqual(out.partials.last?.text, "Tell me about the pilot, and the courier")
        let end = await engine.advance(to: 4.0)
        XCTAssertEqual(end.turns.first?.text, "Tell me about the pilot, and the courier")
    }

    func testLateFinalAfterEndpointDoesNotOpenATurn() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("What results did Lantern deliver", at: 5.0, start: 0, end: 4.9))
        let t = await engine.advance(to: 5.4)
        XCTAssertEqual(t.turns.count, 1)
        // The recognizer's settled version arrives after the endpoint, covering the same audio.
        let late = await engine.ingestTimed(ev("What results did Lantern deliver?", at: 5.9, final: true, start: 0, end: 4.9))
        XCTAssertTrue(late.isEmpty, "a late final for a closed turn is only a correction")
        let more = await engine.advance(to: 9.0)
        XCTAssertTrue(more.turns.isEmpty)
    }

    func testCumulativeResultAfterEndpointOpensTurnWithOnlyNewWords() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("Can you walk me through your last project", at: 5.0, start: 0, end: 5.0))
        let t = await engine.advance(to: 5.4)
        XCTAssertEqual(t.turns.first?.text, "Can you walk me through your last project")
        // The speaker kept going; the recognizer's text still starts with the closed turn's words.
        let out = await engine.ingestTimed(ev("Can you walk me through your last project and what did you learn", at: 7.0, start: 0, end: 7.0))
        XCTAssertEqual(out.partials.first?.id, "r2")
        XCTAssertEqual(out.partials.first?.text, "and what did you learn")
        let more = await engine.ingestTimed(ev("Can you walk me through your last project and what did you learn there", at: 7.2, start: 0, end: 7.2))
        XCTAssertEqual(more.partials.first?.text, "and what did you learn there")
        let end = await engine.advance(to: 9.0)
        XCTAssertEqual(end.turns.first?.id, "r2")
        XCTAssertEqual(end.turns.first?.text, "and what did you learn there")

        // Several endpoints inside one cumulative recognizer result: each turn only gets its own words.
        let chain = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await chain.ingestTimed(ev("What did you build", at: 2.0, start: 0, end: 2.0))
        let c1 = await chain.advance(to: 2.4)
        XCTAssertEqual(c1.turns.first?.text, "What did you build")
        _ = await chain.ingestTimed(ev("What did you build and why did you leave", at: 4.0, start: 0, end: 4.0))
        let c2 = await chain.advance(to: 4.4)
        XCTAssertEqual(c2.turns.first?.text, "and why did you leave")
        let c3 = await chain.ingestTimed(ev("What did you build and why did you leave and who was on the team", at: 6.0, start: 0, end: 6.0))
        XCTAssertEqual(c3.partials.first?.text, "and who was on the team")
        XCTAssertEqual(c3.partials.first?.id, "r3")
    }

    func testPartialsForEveryVolatileRemoteEvent() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var all: [TurnEngine.Timed] = []
        for (i, text) in ["what", "what results", "what results did", "what results did Lantern"].enumerated() {
            all += await engine.ingestTimed(ev(text, at: 1.0 + Double(i) * 0.1))
        }
        XCTAssertEqual(all.partials.map(\.text), ["what", "what results", "what results did", "what results did Lantern"])
        XCTAssertEqual(all.partials.map(\.cue), [false, true, true, true])
        XCTAssertEqual(Set(all.partials.map(\.id)), ["r1"])
    }

    // MARK: audio-driven endpoint

    /// The recognizer delivers its text in bursts about a second apart. While the speaker is still talking the text
    /// does not change between bursts; with audio levels the endpoint must wait for the audio to go quiet.
    func testEndpointFollowsAudioBetweenBursts() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        var turns: [TurnEngine.Timed] = []
        _ = await engine.ingestTimed(ev("Can you walk me through the lantern project", at: 3.0, start: 0, end: 3.0))
        // audio stays loud until 3.9 while no new text arrives (a burst gap)
        var t = 3.0
        while t < 3.9 { turns += await engine.noteRemoteLevel(-20, at: t); t += 0.01 }
        XCTAssertTrue(turns.turns.isEmpty, "the speaker is still talking; the text-only timer must not fire")
        _ = await engine.ingestTimed(ev("Can you walk me through the lantern project and what results did it deliver", at: 3.95, start: 0, end: 3.95))
        // then quiet
        while t < 4.6 { turns += await engine.noteRemoteLevel(nil, at: t); t += 0.01 }
        let turn = turns.turns.first
        XCTAssertNotNil(turn)
        XCTAssertEqual(turn?.text, "Can you walk me through the lantern project and what results did it deliver")
        // quiet since ~3.9, the recognizer has caught up (range end 3.95): due at ~4.2
        XCTAssertEqual(turn?.at ?? 0, 4.2, accuracy: 0.08)
    }

    func testEndpointWaitsForRecognizerToCatchUpWithTheAudio() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("What results did Lantern", at: 2.0, start: 0, end: 2.0))
        var turns: [TurnEngine.Timed] = []
        var t = 2.0
        // the speaker said "deliver" until 2.8; the recognizer has only seen audio up to 2.0
        while t < 2.8 { turns += await engine.noteRemoteLevel(-20, at: t); t += 0.01 }
        while t < 3.3 { turns += await engine.noteRemoteLevel(nil, at: t); t += 0.01 }
        XCTAssertTrue(turns.turns.isEmpty, "audio was quiet for 0.5 s but the recognizer had not seen the last words")
        let burst = await engine.ingestTimed(ev("What results did Lantern deliver", at: 3.32, start: 0, end: 3.3))
        XCTAssertTrue(burst.turns.isEmpty, "the rest of the burst must still land in this turn")
        var after: [TurnEngine.Timed] = []
        while t < 3.6 { after += await engine.noteRemoteLevel(nil, at: t); t += 0.01 }
        XCTAssertEqual(after.turns.first?.text, "What results did Lantern deliver")
        XCTAssertEqual(after.turns.first?.at ?? 0, 3.40, accuracy: 0.05, "last text change + burst settle")
    }

    func testEndpointCapWhenAudioNeverGoesQuiet() async {
        // Music under the voice: the text-based cap ends the turn 1.5 s after the last text change.
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        _ = await engine.ingestTimed(ev("What results did Lantern deliver", at: 2.0, start: 0, end: 2.0))
        var turns: [TurnEngine.Timed] = []
        var t = 2.0
        while t < 4.0 { turns += await engine.noteRemoteLevel(-25, at: t); t += 0.01 }
        XCTAssertEqual(turns.turns.first?.at ?? 0, 3.5, accuracy: 0.05)
    }

    func testNewTurnAfterLongAudioGap() async {
        let engine = TurnEngine(config: TurnConfig(), bank: .empty, facts: .empty)
        // A settled sentence (audio 0 - 2.0) delivered at 3.0, then new audio that starts 0.8 s after it ended.
        _ = await engine.ingestTimed(ev("I worked on the API", at: 3.0, final: true, start: 0, end: 2.0))
        let out = await engine.ingestTimed(ev("Why did you leave", at: 3.5, start: 2.8, end: 3.4))
        XCTAssertEqual(out.turns.map(\.id), ["r1"], "the gap closes the first turn although its timer has not run out")
        XCTAssertEqual(out.turns.first?.text, "I worked on the API")
        XCTAssertEqual(out.partials.first?.id, "r2")
        XCTAssertEqual(out.partials.first?.text, "Why did you leave")
    }
}
