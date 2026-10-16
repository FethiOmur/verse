import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Room route (anytime calls, phase A): the microphone is the only channel and its turns are `room` turns.
final class RoomRouteTests: XCTestCase {

    private func engine(_ auto: RoomAuto = .questions, room: Bool = true) -> TurnEngine {
        var c = TurnConfig()
        c.roomMode = room
        c.roomAuto = auto
        return TurnEngine(config: c, bank: .empty, facts: .empty)
    }

    private func hear(_ text: String, _ e: TurnEngine) async -> [TurnEngine.Timed] {
        var out = await e.ingestTimed(ev(text, at: 10.0))
        out += await e.advance(to: 20)
        return out
    }

    private func kinds(_ t: [TurnEngine.Timed]) -> [TurnKind] { t.turnKinds }

    private func partialCues(_ t: [TurnEngine.Timed]) -> [Bool] {
        t.compactMap { if case .partial(_, _, _, let cue, _) = $0.event { return cue } else { return nil } }
    }

    func testRoomTurnsAreLabelledRoomAndNeverForAnyone() async {
        let e = engine()
        // "Alex" names the owner and "you" is a second person: in a meeting that is a question for him. In the room nobody
        // can be told from anybody, so the addressee stays unknown.
        let out = await hear("Alex can you walk me through how you built the routing service", e)
        let turns = out.turns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.speaker, .room)
        XCTAssertEqual(turns.first?.addressee, .unknown)
        XCTAssertEqual(kinds(out), [.question])
        for t in out { if case .partial(_, let sp, _, _, _) = t.event { XCTAssertEqual(sp, .room) } }
        XCTAssertEqual(partialCues(out).last, true)
    }

    func testAMeetingStaysAsItWas() async {
        let e = engine(room: false)
        let out = await hear("Alex can you walk me through how you built the routing service", e)
        XCTAssertEqual(out.turns.first?.speaker, .remote)
        XCTAssertEqual(out.turns.first?.addressee, .me)
    }

    /// A question needs a cue and six words to fire by itself in the room.
    func testCueGateNeedsSixWords() async {
        let short = await hear("Can you explain that please", engine())            // 5 words
        XCTAssertEqual(kinds(short), [.statement], "a question below six words is demoted: the brain fires nothing")
        XCTAssertEqual(partialCues(short).last, false)

        let six = await hear("Can you explain that to me", engine())              // 6 words
        XCTAssertEqual(kinds(six), [.question])
        XCTAssertEqual(partialCues(six).last, true)
    }

    func testTalkWithoutACueNeverFires() async {
        let out = await hear("We shipped the new routing service last quarter and it went well", engine())
        XCTAssertEqual(kinds(out), [.statement])
        XCTAssertEqual(partialCues(out).last, false)
        XCTAssertEqual(out.turns.first?.speaker, .room, "still sent, so card-now can answer it")
    }

    /// The live test's second question arrived over three turns; with the indirect cues the last one is a question the
    /// brain answers by itself, and the two that only set it up stay statements (the brain's silent probe decides on them).
    func testAnIndirectQuestionSplitOverThreeTurnsFiresOnTheLastOne() async {
        let setup1 = await hear("One of the big decisions you have made is which university or college to attend", engine())
        XCTAssertEqual(kinds(setup1), [.statement])
        XCTAssertEqual(partialCues(setup1).last, false)
        let setup2 = await hear("And an equally big if not bigger one is what your major will be", engine())
        XCTAssertEqual(kinds(setup2), [.statement])
        let ask = await hear("I'm interested in why you chose this school and in particular why you chose accounting as a major", engine())
        XCTAssertEqual(kinds(ask), [.question])
        XCTAssertEqual(partialCues(ask).last, true)
        XCTAssertEqual(ask.turns.first?.speaker, .room)
    }

    func testAutoOffMakesEveryTurnAFragment() async {
        let out = await hear("Can you walk me through how you built the routing service", engine(.off))
        XCTAssertEqual(kinds(out), [.fragment])
        XCTAssertEqual(partialCues(out).last, false)
        XCTAssertEqual(out.turns.count, 1, "the turn still goes to the brain: ⌥⌘↩ answers it")
    }

    func testMeetingKindsAreNotTouched() async {
        let out = await hear("Can you explain that please", engine(room: false))
        XCTAssertEqual(kinds(out), [.question])
        XCTAssertEqual(partialCues(out).last, true)
    }

    // MARK: runner, end to end on a memory clip

    /// A microphone-only clip (the `me` clip of a memory source, as the room route plays it) produces `room` turns and no
    /// `me` turns; the brain is the canned one.
    func testMicOnlyClipGivesRoomTurnsAndNoMeTurns() async throws {
        let f = try SayFixture.make(voice: "Samantha", text: "Can you tell me about yourself and your background? [[slnc 4000]]")
        defer { f.delete() }
        let clip = try PCMClip.read(f.file)
        let session = try TempSession()
        defer { session.delete() }

        var o = RunOptions(sessionDir: session.dir)
        o.source = .memory(remote: nil, me: clip)
        o.route = .room
        o.mode = .unprepared
        o.fakeBrain = true
        o.drainSeconds = 2
        o.brainDir = try brainDir()
        let rec = SinkRecorder()
        o.sink = rec.sink
        var transcriptChannels: Set<Channel> = []
        let seen = ChannelSet()
        o.transcriptTap = { seen.add($0.channel) }
        let code = await VerseRunner(options: o).run()
        transcriptChannels = seen.all
        XCTAssertEqual(code, 0)

        var speakers: [String] = []
        var texts: [String] = []
        for e in rec.all {
            if case .outbound(let obj) = e, obj.type == "turn" {
                speakers.append(obj[string: "speaker"] ?? "")
                texts.append(obj[string: "text"] ?? "")
                XCTAssertEqual(obj[string: "addressee"], "unknown")
            }
        }
        print("[room] turns \(texts) speakers \(speakers) channels \(transcriptChannels)")
        XCTAssertEqual(transcriptChannels, [.remote], "the microphone is the remote pipeline; there is no me channel")
        XCTAssertFalse(speakers.isEmpty, "the recognizer heard the question")
        XCTAssertTrue(speakers.allSatisfy { $0 == "room" }, "\(speakers)")
        XCTAssertFalse(speakers.contains("me"))
        XCTAssertTrue(texts.contains { $0.lowercased().contains("yourself") }, "\(texts)")
    }
}

final class ChannelSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<Channel> = []
    func add(_ c: Channel) { lock.lock(); set.insert(c); lock.unlock() }
    var all: Set<Channel> { lock.lock(); defer { lock.unlock() }; return set }
}
