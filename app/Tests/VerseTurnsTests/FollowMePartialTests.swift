import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// "Follow my answer", Swift side of the wire: the owner's own speech reaches the brain as `me` partials when the setting is
/// on, and nothing else about the turn logic changes.
final class FollowMePartialTests: XCTestCase {

    private func script() -> [TranscriptEvent] {
        [ev("Can you tell me about your last project", at: 1.0, start: 0.0),
         ev("Can you tell me about your last project?", at: 2.0, final: true, start: 0.0),
         ev("Well I built", at: 3.0, channel: .me, start: 2.6),
         ev("Well I built a weather app", at: 3.6, channel: .me, start: 2.6),
         ev("Well I built a weather app", at: 4.0, channel: .me, final: true, start: 2.6),   // same words: nothing new
         ev("for my family and then", at: 4.8, channel: .me, start: 4.2)]
    }

    private func run(emit: Bool) async -> [TurnEngine.Timed] {
        var cfg = TurnConfig()
        cfg.emitMePartials = emit
        let engine = TurnEngine(config: cfg, bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        for e in script() { out += await engine.ingestTimed(e) }
        out += await engine.advance(to: 12)
        return out
    }

    private func mePartials(_ out: [TurnEngine.Timed]) -> [(id: String, text: String)] {
        out.compactMap {
            if case .partial(let id, .me, let text, _, _) = $0.event { return (id, text) }
            return nil
        }
    }

    func testMePartialsGrowWithHisWordsWhenFollowIsOn() async {
        let out = await run(emit: true)
        let p = mePartials(out)
        XCTAssertEqual(p.map(\.text), ["Well I built", "Well I built a weather app", "Well I built a weather app for my family and then"],
                       "one partial per change of his text, none for the unchanged final")
        XCTAssertEqual(Set(p.map(\.id)).count, 1, "all of them belong to his one turn")
        XCTAssertTrue(out.turns.contains { $0.speaker == .me }, "the closed me turn still goes out as before")
    }

    /// The setting is the only difference: with it off the event stream is exactly what it was, and turning it on adds
    /// the me partials without touching the turn events or their timing.
    func testTurnLogicIsIdenticalWithAndWithoutMePartials() async {
        let off = await run(emit: false)
        let on = await run(emit: true)
        XCTAssertTrue(mePartials(off).isEmpty, "off by default: no me partial ever leaves the engine")
        func withoutMePartials(_ a: [TurnEngine.Timed]) -> [TurnEngine.Timed] {
            a.filter { if case .partial(_, .me, _, _, _) = $0.event { return false }; return true }
        }
        XCTAssertEqual(withoutMePartials(on).map(\.event), off.map(\.event))
        XCTAssertEqual(withoutMePartials(on).map(\.at), off.map(\.at))
        XCTAssertFalse(TurnConfig().emitMePartials)
    }

    func testEchoThatIsDroppedNeverBecomesAMePartial() async {
        var cfg = TurnConfig()
        cfg.emitMePartials = true
        let engine = TurnEngine(config: cfg, bank: .empty, facts: .empty)
        var out: [TurnEngine.Timed] = []
        out += await engine.ingestTimed(ev("Can you tell me about your last project", at: 1.0, start: 0.0))
        out += await engine.ingestTimed(ev("Can you tell me about your last", at: 1.02, channel: .me, start: 0.0, end: 1.0))   // speaker bleed
        XCTAssertTrue(mePartials(out).isEmpty)
    }

    /// `RunOptions.follow` is what puts the flag into `start`, in the explicit form the brain reads.
    func testRunOptionsFollowDefaultsOff() {
        XCTAssertFalse(RunOptions(sessionDir: URL(fileURLWithPath: "/tmp/x")).follow)
        XCTAssertTrue(BrainCommand.start(sessionDir: "/tmp/x", lang: "en", follow: true).jsonLine().contains("\"follow\":true"))
        XCTAssertTrue(BrainCommand.start(sessionDir: "/tmp/x", lang: "en").jsonLine().contains("\"follow\":false"))
    }

    /// The runner sends `start` with the flag, also to a restarted brain (a fake brain that logs its stdin and crashes on
    /// the first turn).
    func testTheRunnerSendsTheFollowFlagInStart() async throws {
        for flag in [true, false] {
            let session = try TempSession(bank: [("b001", "Can you tell me about yourself?", ["Walk us through your background."])])
            defer { session.delete() }
            let fake = try CrashingBrain()
            defer { fake.delete() }
            let fixture = try SayFixture.make(voice: "Samantha", text: "Hello there.")
            defer { fixture.delete() }
            var o = RunOptions(sessionDir: session.dir)
            o.file = fixture.file
            o.brainDir = fake.dir
            o.drainSeconds = 1
            o.readyTimeout = 10
            o.follow = flag
            o.sink = { _ in }
            _ = await VerseRunner(options: o).run()
            let starts = fake.stdinLog.filter { $0.contains("\"type\":\"start\"") }
            // The fake brain crashes on the first turn, so the runner starts it twice: the restart carries the flag too.
            XCTAssertEqual(starts.count, 2, "stdin: \(fake.stdinLog)")
            XCTAssertTrue(starts.allSatisfy { $0.contains("\"follow\":\(flag)") }, "start lines: \(starts)")
            for pid in fake.pids { XCTAssertTrue(processIsGone(pid), "brain \(pid) still running") }
        }
    }
}
