import Foundation
@testable import VerseTurns
import XCTest

/// The additive protocol of the anytime-calls spec (section 3), Swift side: `start` fields, the two new controls, the
/// `room` speaker, and a decoder that shrugs at what it does not know.
final class AnytimeWireTests: XCTestCase {

    private func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
    }

    /// A session that sets none of the new fields sends exactly the line it always did.
    func testDefaultStartLineIsUnchanged() {
        XCTAssertEqual(BrainCommand.start(sessionDir: "/tmp/x y", lang: "en").jsonLine(),
                       #"{"follow":false,"lang":"en","session_dir":"/tmp/x y","type":"start"}"#)
        XCTAssertEqual(BrainCommand.start(sessionDir: "/s", lang: "it", follow: true).jsonLine(),
                       #"{"follow":true,"lang":"it","session_dir":"/s","type":"start"}"#)
    }

    /// Golden: every field set.
    func testStartLineWithAllFields() {
        let me = MeProfilePaths(core: "/p/me.md", library: "/p/me.library.jsonl", facts: "/p/me.facts.jsonl")
        let line = BrainCommand.start(sessionDir: "/sessions/adhoc-20261016-1432-room", lang: "tr", follow: false,
                                      mode: .unprepared, route: .room, me: me, roomAuto: .questions).jsonLine()
        XCTAssertEqual(line, #"{"follow":false,"lang":"tr","me":{"core":"/p/me.md","facts":"/p/me.facts.jsonl","library":"/p/me.library.jsonl"},"mode":"unprepared","room_auto":"questions","route":"room","session_dir":"/sessions/adhoc-20261016-1432-room","type":"start"}"#)
    }

    func testEachFieldAloneAndRoomAutoOff() throws {
        let o = try object(BrainCommand.start(sessionDir: "/s", lang: "en", mode: .prepared, route: .phone, roomAuto: .off).jsonLine())
        XCTAssertEqual(o["mode"] as? String, "prepared")
        XCTAssertEqual(o["route"] as? String, "phone")
        XCTAssertEqual(o["room_auto"] as? String, "off")
        XCTAssertNil(o["me"], "no me layer: the key is absent, not null")
    }

    func testMeProfilePathsDefaultsToTheProfileFolder() {
        let p = MeProfilePaths(directory: URL(fileURLWithPath: "/x/profile"))
        XCTAssertEqual(p, MeProfilePaths(core: "/x/profile/me.md", library: "/x/profile/me.library.jsonl", facts: "/x/profile/me.facts.jsonl"))
        XCTAssertTrue(MeProfilePaths.defaultDirectory.path.hasSuffix("Application Support/Verse/profile"))
    }

    func testControlLines() {
        XCTAssertEqual(BrainCommand.cardNow.jsonLine(), #"{"action":"card_now","type":"control"}"#)
        XCTAssertEqual(BrainCommand.setLanguage("it").jsonLine(), #"{"action":"lang","lang":"it","type":"control"}"#)
        XCTAssertEqual(BrainCommand.stop.jsonLine(), #"{"action":"stop","type":"control"}"#)
    }

    func testRoomSpeakerRoundTrips() throws {
        let turn = OutboundEvent.turn(turnID: "r1", speaker: .room, text: "Can you tell me about the project", addressee: .unknown, tAudioEnd: 4.2, kind: .question)
        let o = try object(turn.jsonLine())
        XCTAssertEqual(o["speaker"] as? String, "room")
        XCTAssertEqual(o["addressee"] as? String, "unknown")
        XCTAssertEqual(OutboundEvent.decodeLenient(turn.jsonLine()), turn)
        let partial = OutboundEvent.partial(turnID: "r1", speaker: .room, text: "Can you", cue: false, tAudioEnd: 1)
        XCTAssertEqual(OutboundEvent.decodeLenient(partial.jsonLine()), partial)
    }

    /// The decoder skips what it does not know: a `notice`, a future type, garbage.
    func testUnknownEventTypesAreIgnored() {
        XCTAssertNil(OutboundEvent.decodeLenient(#"{"type":"notice","kind":"me_conflicts","items":[],"turn_id":"x"}"#))
        XCTAssertNil(OutboundEvent.decodeLenient(#"{"type":"something_new","turn_id":"x"}"#))
        XCTAssertNil(OutboundEvent.decodeLenient("not json"))
        XCTAssertNotNil(OutboundEvent.decodeLenient(OutboundEvent.partial(turnID: "r1", speaker: .remote, text: "hi", cue: false, tAudioEnd: 1).jsonLine()))
    }

    /// A `notice` goes through the runner's classification like any brain line, and an unknown notice kind decodes to nothing.
    func testNoticeDoesNotBreakTheRunnerEvents() throws {
        let line = #"{"type":"notice","kind":"me_conflicts","items":[{"me":"m412","pack":"f003","topic":"team size"}]}"#
        let o = try XCTUnwrap(JSONValue.decodeObject(line))
        XCTAssertEqual(RunnerEvent.classify(o, fromBrain: true), .brain(o))
        XCTAssertEqual(BrainNotice(o), .meConflicts([MeConflict(me: "m412", pack: "f003", topic: "team size")]))

        let missing = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"me_missing"}"#))
        XCTAssertEqual(BrainNotice(missing), .meMissing)

        let future = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"notice","kind":"from_the_future","x":1}"#))
        XCTAssertNil(BrainNotice(future))
        XCTAssertEqual(RunnerEvent.classify(future, fromBrain: true), .brain(future))
        XCTAssertNil(BrainNotice(try XCTUnwrap(JSONValue.decodeObject(#"{"type":"delta","id":"a"}"#))), "not a notice")
    }

    func testReadyStatusCarriesTheMeLayer() throws {
        let ready = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"status","state":"ready","message":"","me":{"tokens":3140,"built_at":"2026-10-16"}}"#))
        XCTAssertEqual(MeLayerInfo(readyStatus: ready)?.tokens, 3140)
        XCTAssertEqual(MeLayerInfo(readyStatus: ready)?.builtAt, "2026-10-16")
        let none = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"status","state":"ready","message":"","me":null}"#))
        XCTAssertNil(MeLayerInfo(readyStatus: none))
        let old = try XCTUnwrap(JSONValue.decodeObject(#"{"type":"status","state":"ready","message":""}"#))
        XCTAssertNil(MeLayerInfo(readyStatus: old), "an older brain reports no me field")
    }

    // MARK: runner options -> start

    func testRunnerSendsOnlyWhatDiffersFromAPreparedMeeting() throws {
        let dir = URL(fileURLWithPath: "/tmp/s")
        var o = RunOptions(sessionDir: dir)
        XCTAssertEqual(VerseRunner(options: o).startCommand(), .start(sessionDir: "/tmp/s", lang: "en", follow: false))

        o.follow = true
        o.mode = .unprepared
        o.route = .room
        o.me = MeProfilePaths(core: "a", library: "b", facts: "c")
        o.roomAuto = .off
        o.lang = "it"
        XCTAssertEqual(VerseRunner(options: o).startCommand(),
                       .start(sessionDir: "/tmp/s", lang: "it", follow: false, mode: .unprepared, route: .room,
                              me: MeProfilePaths(core: "a", library: "b", facts: "c"), roomAuto: .off),
                       "no follow in the room route (there is no me channel), room_auto only there")

        o.route = .meeting
        o.mode = .prepared
        XCTAssertEqual(VerseRunner(options: o).startCommand(),
                       .start(sessionDir: "/tmp/s", lang: "it", follow: true, me: MeProfilePaths(core: "a", library: "b", facts: "c")))
    }
}
