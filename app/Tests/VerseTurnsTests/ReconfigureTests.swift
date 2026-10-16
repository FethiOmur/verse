import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// `TurnEngine.reconfigure` (anytime-swap): the engine takes the new route and language mid-call and keeps the call.
final class ReconfigureTests: XCTestCase {

    private func engine(room: Bool = false, lang: String = "en", partials: Bool = false) -> TurnEngine {
        var c = TurnConfig()
        c.lang = lang
        c.roomMode = room
        c.emitMePartials = partials
        return TurnEngine(config: c, bank: .empty, facts: .empty)
    }

    private func say(_ e: TurnEngine, _ text: String, at t: Double, lang: String = "en", channel: Channel = .remote) async -> [TurnEngine.Timed] {
        var out = await e.ingestTimed(TranscriptEvent(channel: channel, text: text, isFinal: false, audioStart: t - 1, audioEnd: t, emittedAt: t, lang: lang))
        out += await e.advance(to: t + 3)
        return out
    }

    /// Turn numbers go on across a reconfigure: r1, r2, r3, never a second r1.
    func testTurnNumbersContinueAcrossAReconfigure() async {
        let e = engine(room: true)
        var ids: [String] = []
        ids += await say(e, "can you walk me through how you built the routing service", at: 5).turns.map(\.id)
        _ = await e.flush(at: 9)
        await e.reconfigure(roomMode: false)
        ids += await say(e, "how did you test it before the release", at: 15).turns.map(\.id)
        await e.reconfigure(lang: "it")
        ids += await say(e, "come hai costruito il servizio di instradamento", at: 25, lang: "it").turns.map(\.id)
        XCTAssertEqual(ids, ["r1", "r2", "r3"])
    }

    /// Flush then reconfigure: the open turn is finalized once; the new recognizer's words after it are a new turn, even when they
    /// repeat the old words (a fresh recognizer is not a continuation).
    func testAnOpenTurnIsClosedOnceAndTheNextOneIsNew() async {
        let e = engine(room: true)
        let open = await e.ingestTimed(TranscriptEvent(channel: .remote, text: "and what was the hardest", isFinal: false, audioStart: 4, audioEnd: 5,
                                                       emittedAt: 5, lang: "en"))
        XCTAssertEqual(open.partials.map(\.id), ["r1"])
        let closed = await e.flush(at: 6)
        XCTAssertEqual(closed.turns.map(\.id), ["r1"])
        XCTAssertEqual(closed.turns.map(\.text), ["and what was the hardest"])
        let again = await e.flush(at: 7)
        XCTAssertTrue(again.turns.isEmpty, "nothing is left to close twice")
        await e.reconfigure(roomMode: false)
        // The new pipeline's times continue after the old ones; the first words repeat the old turn's start.
        let next = await say(e, "and what was the hardest", at: 12)
        XCTAssertEqual(next.turns.map(\.id), ["r2"])
        XCTAssertEqual(next.turns.map(\.text), ["and what was the hardest"], "a new turn with its own words")
    }

    /// The route decides the speaker, the addressee, follow partials and the card gate.
    func testTheRouteSettingsFollowTheReconfigure() async {
        let e = engine(room: true)
        let room = await say(e, "can you walk me through how you built the routing service", at: 5)
        XCTAssertEqual(room.turns.map(\.speaker), [.room])
        XCTAssertEqual(room.turns.map(\.addressee), [.unknown])
        let cfg0 = await e.currentConfig
        XCTAssertTrue(cfg0.roomMode)
        XCTAssertFalse(cfg0.emitMePartials)

        await e.reconfigure(roomMode: false, emitMePartials: true)
        let meeting = await say(e, "owner can you walk me through how you built the routing service", at: 15)
        XCTAssertEqual(meeting.turns.map(\.speaker), [.remote])
        XCTAssertEqual(meeting.turns.map(\.addressee), [.me])
        let cfg1 = await e.currentConfig
        XCTAssertFalse(cfg1.roomMode)
        XCTAssertTrue(cfg1.emitMePartials)

        // the owner's own words give follow partials now ...
        let me = await e.ingestTimed(TranscriptEvent(channel: .me, text: "we wrote contract tests and a replay harness", isFinal: false, audioStart: 20,
                                                     audioEnd: 22, emittedAt: 22, lang: "en"))
        let mePartials = (me + (await e.advance(to: 24))).compactMap { t -> String? in
            if case .partial(_, let sp, let text, _, _) = t.event, sp == .me { return text }
            return nil
        }
        XCTAssertFalse(mePartials.isEmpty, "follow partials flow in the meeting")
        _ = await e.flush(at: 25)

        // ... and not after the swap back to the room.
        await e.reconfigure(roomMode: true, emitMePartials: false)
        let back = await say(e, "can you tell me how the migration went in the end", at: 35)
        XCTAssertEqual(back.turns.map(\.speaker), [.room])
    }

    /// The language decides which words are a question.
    func testTheLanguageSettingFollowsTheReconfigure() async {
        let e = engine()
        let en = await say(e, "come hai costruito il servizio di instradamento", at: 5)
        XCTAssertEqual(en.turnKinds, [.statement], "no English cue in it")
        await e.reconfigure(lang: "it")
        let it = await say(e, "come hai costruito il servizio di instradamento", at: 15, lang: "it")
        XCTAssertEqual(it.turnKinds, [.question], "\"come\" is an Italian cue")
        let cfg = await e.currentConfig
        XCTAssertEqual(cfg.lang, "it")
    }

    /// Nil leaves a setting alone.
    func testNilLeavesTheSettingsAsTheyAre() async {
        let e = engine(room: true, partials: true)
        await e.reconfigure()
        let cfg = await e.currentConfig
        XCTAssertTrue(cfg.roomMode)
        XCTAssertTrue(cfg.emitMePartials)
        XCTAssertEqual(cfg.lang, "en")
    }
}
