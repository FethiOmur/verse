import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// The "me" channel end to end (real recognizers on synthetic `say` speech, fake brain): the owner's speech lands as `me`
/// turns and never gets an answer; speaker bleed (the remote voice in the microphone) is dropped by the defenses.
final class MeChannelTests: XCTestCase {

    private struct Outcome {
        var meTurns: [String] = []              // text of every turn sent to the brain with speaker me
        var remoteTurns: [(id: String, text: String)] = []
        var answeredTurnIDs: Set<String> = []   // turns with S/F/D text
        var meTranscriptEvents = 0              // me results that reached the turn engine
        var meTurnIDs: Set<String> = []
    }

    private func sampleSession() throws -> TempSession {
        try TempSession(bank: [("b001", "Can you tell me about yourself and your background?", ["Walk us through your background."])])
    }

    private func run(remote: PCMClip, me: PCMClip, gate: Bool, guardOn: Bool) async throws -> Outcome {
        let session = try sampleSession()
        defer { session.delete() }
        var o = RunOptions(sessionDir: session.dir)
        o.source = .memory(remote: remote, me: me)
        o.fakeBrain = true
        o.drainSeconds = 2
        o.brainDir = try brainDir()
        if !gate { o.bleedGate.threshold = 2.0 }
        o.turn.echoGuardEnabled = guardOn
        let rec = SinkRecorder()
        o.sink = rec.sink
        let counter = EventCounter()
        o.transcriptTap = { e in if e.channel == .me { counter.add() } }
        let code = await VerseRunner(options: o).run()
        XCTAssertEqual(code, 0)
        var out = Outcome()
        out.meTranscriptEvents = counter.n
        for e in rec.all {
            switch e {
            case .outbound(let obj) where obj.type == "turn":
                let id = obj[string: "turn_id"] ?? "", text = obj[string: "text"] ?? ""
                if obj[string: "speaker"] == "me" { out.meTurns.append(text); out.meTurnIDs.insert(id) } else { out.remoteTurns.append((id, text)) }
            case .brain(let obj) where obj.type == "delta":
                if !(obj[string: "text"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty, let id = obj[string: "turn_id"] { out.answeredTurnIDs.insert(id) }
            default: break
            }
        }
        return out
    }

    private func clip(_ voice: String, _ text: String) throws -> PCMClip {
        let f = try SayFixture.make(voice: voice, text: text)
        defer { f.delete() }
        return try PCMClip.read(f.file)
    }

    /// Alex answers the question: his speech is a `me` turn, the question is answered once, and nothing is ever attached
    /// to a me turn.
    func testAlexLandsAsMeTurnAndNeverGetsAnAnswer() async throws {
        let remote = try clip("Samantha", "Can you tell me about yourself and your background? [[slnc 9000]]")
        let me = try clip("Mara", "[[slnc 5200]] Sure, I build data pipelines and route planners.")
        let r = try await run(remote: remote, me: me, gate: true, guardOn: true)
        print("[me channel] remote \(r.remoteTurns), me \(r.meTurns), answered \(r.answeredTurnIDs)")
        XCTAssertTrue(r.meTurns.contains { $0.lowercased().contains("pipelines") }, "the owner's answer is a me turn: \(r.meTurns)")
        XCTAssertTrue(r.meTurnIDs.allSatisfy { $0.hasPrefix("m") })
        XCTAssertTrue(r.answeredTurnIDs.isDisjoint(with: r.meTurnIDs), "an answer was attached to a me turn: \(r.answeredTurnIDs)")
        let questionAnswers = r.remoteTurns.filter { r.answeredTurnIDs.contains($0.id) }
        XCTAssertEqual(questionAnswers.count, 1, "the question is answered once: \(r.remoteTurns)")
        XCTAssertEqual(r.remoteTurns.count, 1, "one remote turn for one question: \(r.remoteTurns)")
    }

    // MARK: speaker bleed

    /// The microphone with the speakers on: the remote clip 26 dB down, 40 ms late, plus a little room noise.
    private func bleed(of remote: PCMClip) -> PCMClip {
        var g = LCG(state: 11)
        let lag = Int(0.040 * remote.sampleRate)
        let s = ([Float](repeating: 0, count: lag) + remote.samples.map { $0 * 0.05 }).map { $0 + g.next(0.002) }
        return PCMClip(samples: s, sampleRate: remote.sampleRate)
    }

    private func bleedRun(gate: Bool, guardOn: Bool) async throws -> Outcome {
        let remote = try clip("Samantha", "Can you tell me about yourself and your background? [[slnc 6000]]")
        return try await run(remote: remote, me: bleed(of: remote), gate: gate, guardOn: guardOn)
    }

    /// Both defenses on (the app today plus the text guard): no invented me turn, the question answered once, whole.
    func testBleedIsDroppedWithBothDefenses() async throws {
        let r = try await bleedRun(gate: true, guardOn: true)
        print("[bleed both] remote \(r.remoteTurns), me turns \(r.meTurns), me events at engine \(r.meTranscriptEvents)")
        XCTAssertTrue(r.meTurns.isEmpty, "echo became a me turn: \(r.meTurns)")
        XCTAssertEqual(r.remoteTurns.count, 1, "\(r.remoteTurns)")
        XCTAssertEqual(r.answeredTurnIDs, Set(r.remoteTurns.map(\.id)))
    }

    /// The text guard alone (envelope gate off): the echo reaches the engine as me results and is dropped there.
    func testBleedIsDroppedByTheTextGuardAlone() async throws {
        let r = try await bleedRun(gate: false, guardOn: true)
        print("[bleed guard only] remote \(r.remoteTurns), me turns \(r.meTurns), me events at engine \(r.meTranscriptEvents)")
        if r.meTranscriptEvents == 0 { throw XCTSkip("the microphone recognizer heard nothing of the bleed, so the guard was not exercised") }
        XCTAssertTrue(r.meTurns.isEmpty, "echo became a me turn: \(r.meTurns)")
        XCTAssertEqual(r.remoteTurns.count, 1, "\(r.remoteTurns)")
    }

    /// Control: both defenses off, the same echo cuts the question up and invents me turns.
    func testWithoutDefensesTheBleedBecomesMeTurns() async throws {
        let r = try await bleedRun(gate: false, guardOn: false)
        print("[bleed none] remote \(r.remoteTurns), me turns \(r.meTurns), me events at engine \(r.meTranscriptEvents)")
        if r.meTranscriptEvents == 0 { throw XCTSkip("the microphone recognizer heard nothing of the bleed") }
        XCTAssertFalse(r.meTurns.isEmpty, "expected the unguarded echo to produce me turns")
    }
}

final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var n: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Deterministic noise in [-a, a].
struct LCG {
    var state: UInt64
    mutating func next(_ a: Float) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * a
    }
}
