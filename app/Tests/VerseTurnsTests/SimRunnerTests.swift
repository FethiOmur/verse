import Foundation
import os
import VerseSpeech
@testable import VerseTurns
import VerseVoice
import XCTest

// SimRunner against a fake brain transport, a fake voice whose playback the test releases, and a fake mic on a clock
// the test moves. Nothing here touches audio hardware or the network.

final class FakeSimBrain: SimBrainTransport, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let cont: AsyncStream<String>.Continuation
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    init() { (lines, cont) = AsyncStream.makeStream(of: String.self) }

    func send(_ line: String) { lock.withLock { $0.append(line) } }
    func close() async { cont.finish() }
    func say(_ obj: [String: Any]) { cont.yield(SimText.line(obj)) }

    var sent: [[String: JSONValue]] { lock.withLock { $0 }.compactMap { JSONValue.decodeObject($0) } }
    func sent(_ type: String) -> [[String: JSONValue]] { sent.filter { $0.type == type } }
    /// The sent message types in order, `spoken`/`answer` with their ids.
    var trace: [String] {
        sent.map { o in
            switch o.type {
            case "spoken": return "spoken:\(o[string: "id"] ?? "")"
            case "answer": return "answer:\(o[string: "q_id"] ?? "")"
            default: return o.type
            }
        }
    }
}

/// Playback blocks until the test calls `release()` (or `hold` is false).
final class FakeVoice: VoiceEngine, @unchecked Sendable {
    let kind: VoiceKind
    private let lock = OSAllocatedUnfairLock<(hold: Bool, waiting: [CheckedContinuation<Void, Never>], spoken: [String])>(
        initialState: (true, [], []))

    init(kind: VoiceKind = .apple, hold: Bool = true) {
        self.kind = kind
        lock.withLock { $0.hold = hold }
    }

    func speak(_ sentence: String) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { s -> Bool in
                s.spoken.append(sentence)
                if s.hold { s.waiting.append(c); return false }
                return true
            }
            if resumeNow { c.resume() }
        }
    }

    func stop() async { release() }

    /// Ends every sentence that is playing now.
    func release() {
        let w = lock.withLock { s -> [CheckedContinuation<Void, Never>] in let w = s.waiting; s.waiting = []; return w }
        for c in w { c.resume() }
    }

    var playingCount: Int { lock.withLock { $0.waiting.count } }
    var spoken: [String] { lock.withLock { $0.spoken } }
}

final class FakeMic: SimMic, @unchecked Sendable {
    private let stream: AsyncStream<TranscriptEvent>
    private let cont: AsyncStream<TranscriptEvent>.Continuation
    private let clock = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    init() { (stream, cont) = AsyncStream.makeStream(of: TranscriptEvent.self) }

    func start() async throws -> AsyncStream<TranscriptEvent> { stream }
    func now() async -> TimeInterval { clock.withLock { $0 } }
    func stop() async { cont.finish() }

    var t: TimeInterval {
        get { clock.withLock { $0 } }
        set { clock.withLock { $0 = newValue } }
    }

    /// A mic result covering [start, end] heard at the current time.
    func hear(_ text: String, start: Double, end: Double, final: Bool = false) {
        cont.yield(TranscriptEvent(channel: .me, text: text, isFinal: final, audioStart: start, audioEnd: end, emittedAt: t, lang: "en"))
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[SimEvent]>(initialState: [])
    func add(_ e: SimEvent) { lock.withLock { $0.append(e) } }
    var all: [SimEvent] { lock.withLock { $0 } }
    var listening: [String] { all.compactMap { if case .listening(let q) = $0 { return q }; return nil } }
    var answers: [(String, String)] { all.compactMap { if case .answerSent(let q, let t) = $0 { return (q, t) }; return nil } }
}

final class SimRunnerTests: XCTestCase {
    private var brain: FakeSimBrain!
    private var voice: FakeVoice!
    private var mic: FakeMic!
    private var log: EventLog!
    private var runner: SimRunner!

    private func make(voiceKind: VoiceKind = .apple, hold: Bool = true, doneGrace: TimeInterval = 0) async {
        brain = FakeSimBrain()
        voice = FakeVoice(kind: voiceKind, hold: hold)
        mic = FakeMic()
        log = EventLog()
        var cfg = SimRunner.Config()
        cfg.tickInterval = 0.01
        cfg.doneGrace = doneGrace
        let l = log!
        runner = SimRunner(transport: brain, voice: voice, mic: mic, config: cfg, sink: { l.add($0) })
        await runner.start(sessionDir: URL(fileURLWithPath: "/tmp/sim-x"), mode: .coach, voice: voiceKind)
    }

    override func tearDown() async throws {
        await runner?.stop()
    }

    /// Polls until `cond` holds (the runner works on its own tasks).
    private func until(_ what: String, timeout: TimeInterval = 3, _ cond: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// A quiet moment for things that must NOT happen.
    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    func testSimStartFirst() async {
        await make()
        let start = brain.sent.first
        XCTAssertEqual(start?.type, "sim_start")
        XCTAssertEqual(start?[string: "mode"], "coach")
        XCTAssertEqual(start?[string: "voice"], "apple")
        XCTAssertEqual(start?[string: "session_dir"], "/tmp/sim-x")
    }

    func testSaySpokenListenThenMicOpens() async {
        await make()
        brain.say(["type": "say", "id": "s1", "text": "Thanks for coming in.", "final": false])
        brain.say(["type": "say", "id": "s1", "text": "Tell me about yourself.", "final": true])
        brain.say(["type": "listen", "q_id": "q1"])
        await until("first sentence playing") { voice.playingCount == 1 }
        await settle()
        XCTAssertTrue(log.listening.isEmpty, "mic must stay closed while the line plays")
        XCTAssertTrue(brain.sent("spoken").isEmpty, "no spoken before the final sentence played")

        voice.release()   // first sentence ends; spoken still not sent (not final)
        await until("second sentence playing") { voice.playingCount == 1 }
        XCTAssertTrue(brain.sent("spoken").isEmpty)
        XCTAssertTrue(log.listening.isEmpty)

        voice.release()   // the final sentence ends
        await until("mic open") { log.listening == ["q1"] }
        XCTAssertEqual(voice.spoken, ["Thanks for coming in.", "Tell me about yourself."])
        XCTAssertEqual(brain.trace, ["sim_start", "spoken:s1"])
        // the order of what the app did: say -> played -> spoken -> listening
        let order = log.all.compactMap { e -> String? in
            switch e {
            case .say(let id, _, let f): return f ? "say-final:\(id)" : "say:\(id)"
            case .spoken(let id): return "spoken:\(id)"
            case .listening(let q): return "listen:\(q)"
            default: return nil
            }
        }
        XCTAssertEqual(order, ["say:s1", "say-final:s1", "spoken:s1", "listen:q1"])
    }

    func testListenBeforePlaybackEndsWaitsForSpoken() async {
        await make()
        brain.say(["type": "say", "id": "s4", "text": "Why us?", "final": true])
        await until("playing") { voice.playingCount == 1 }
        brain.say(["type": "listen", "q_id": "q3"])
        await settle()
        XCTAssertTrue(log.listening.isEmpty, "a listen does not open the mic while the line plays")
        voice.release()
        await until("mic open") { log.listening == ["q3"] }
        let trace = brain.trace
        XCTAssertEqual(trace.last, "spoken:s4")
    }

    func testMicInputDuringPlaybackIsDropped() async {
        await make()
        mic.t = 1
        brain.say(["type": "say", "id": "s2", "text": "Walk me through a project.", "final": true])
        brain.say(["type": "listen", "q_id": "q2"])
        await until("playing") { voice.playingCount == 1 }
        // the interviewer's own voice through the speakers
        mic.hear("walk me through a project", start: 1.0, end: 2.5, final: true)
        await until("dropped") { await runner.droppedMicEvents == 1 }
        XCTAssertTrue(brain.sent("partial").isEmpty)

        mic.t = 3
        await runner.tick(now: 3)
        voice.release()
        await until("mic open") { log.listening == ["q2"] }
        // its tail arrives late from the recognizer: audio started well before the mic opened
        mic.hear("a project", start: 1.8, end: 2.6, final: true)
        await until("tail dropped") { await runner.droppedMicEvents == 2 }
        XCTAssertTrue(brain.sent("partial").isEmpty)
        XCTAssertFalse(log.all.contains { if case .answerText = $0 { return true }; return false })
    }

    /// Opens the mic for `q` with line `id` at mic time `t`.
    private func openMic(line id: String, q: String, at t: Double) async {
        mic.t = t
        await runner.tick(now: t)
        brain.say(["type": "say", "id": id, "text": "Question \(q)?", "final": true])
        brain.say(["type": "listen", "q_id": q])
        await until("playing \(id)") { voice.playingCount == 1 }
        voice.release()
        await until("mic open \(q)") { log.listening.last == q && log.listening.count == log.answers.count + 1 }
    }

    func testPartialSentDuringAnswerAndSilenceEndsIt() async {
        await make()
        await openMic(line: "s1", q: "q1", at: 10)
        mic.hear("I led", start: 10.5, end: 11.0)
        await until("partial") { brain.sent("partial").count == 1 }
        let p = brain.sent("partial")[0]
        XCTAssertEqual(p[string: "text"], "I led")
        XCTAssertEqual(p[string: "speaker"], "me")

        mic.t = 11.6
        await runner.tick(now: 11.6)
        mic.hear("I led Lantern, um, an LLM pipeline.", start: 10.5, end: 12.0, final: true)
        await until("answer text") { log.all.contains(.answerText("I led Lantern, um, an LLM pipeline.")) }
        // 1.9 s after the last word: still answering
        await runner.tick(now: 13.9)
        await settle()
        XCTAssertTrue(brain.sent("answer").isEmpty)
        // 2.0 s: the answer ends, exactly once
        await runner.tick(now: 14.0)
        await until("answer") { brain.sent("answer").count == 1 }
        await runner.tick(now: 20)
        await settle()
        XCTAssertEqual(brain.sent("answer").count, 1)
        let a = brain.sent("answer")[0]
        XCTAssertEqual(a[string: "q_id"], "q1")
        XCTAssertEqual(a[string: "text"], "I led Lantern, um, an LLM pipeline.")
        XCTAssertEqual(a[double: "t_start"], 10.5)
        XCTAssertEqual(a[double: "t_end"], 12.0)
        XCTAssertEqual(a[double: "words"], 7)
        XCTAssertEqual(a[double: "fillers"], 1)
        XCTAssertEqual(log.answers.map(\.0), ["q1"])
        // the mic is closed again: later speech is dropped
        let dropped = await runner.droppedMicEvents
        mic.hear("and also", start: 21, end: 21.5)
        await until("dropped after answer") { await runner.droppedMicEvents == dropped + 1 }
    }

    func testDoneAnsweringEndsAtOnceAndOnlyOnce() async {
        await make()
        await openMic(line: "s9", q: "q2", at: 5)
        mic.hear("We measured it with a golden set", start: 5.4, end: 7.0, final: true)
        await until("answer text") { log.all.contains(.answerText("We measured it with a golden set")) }
        await runner.doneAnswering()
        await until("answer") { brain.sent("answer").count == 1 }
        await runner.doneAnswering()
        await runner.tick(now: 30)
        await settle()
        XCTAssertEqual(brain.sent("answer").count, 1)
        XCTAssertEqual(brain.sent("answer")[0][string: "text"], "We measured it with a golden set")
    }

    func testDoneAnsweringGraceCollectsLateWords() async {
        await make(doneGrace: 0.4)
        await openMic(line: "s3", q: "q1", at: 5)
        mic.hear("Three hundred", start: 5.5, end: 6.0)
        await until("text") { log.all.contains(.answerText("Three hundred")) }
        await runner.doneAnswering()
        mic.hear("Three hundred invoices.", start: 5.5, end: 6.3, final: true)
        await until("final text") { log.all.contains(.answerText("Three hundred invoices.")) }
        await runner.tick(now: 5.2)
        await settle()
        XCTAssertTrue(brain.sent("answer").isEmpty, "inside the grace")
        await runner.tick(now: 5.5)
        await until("answer") { brain.sent("answer").count == 1 }
        XCTAssertEqual(brain.sent("answer")[0][string: "text"], "Three hundred invoices.")
    }

    func testNonConsecutiveIDs() async {
        await make()
        await openMic(line: "s7", q: "q1", at: 1)
        mic.hear("Answer one.", start: 1.5, end: 2.0, final: true)
        await until("text") { log.all.contains(.answerText("Answer one.")) }
        await runner.tick(now: 4.1)
        await until("answer 1") { brain.sent("answer").count == 1 }
        // the silence prompt took an id in between; the next lines skip numbers
        await openMic(line: "s12", q: "q5", at: 5)
        mic.hear("Answer two.", start: 5.5, end: 6.0, final: true)
        await until("text 2") { log.all.contains(.answerText("Answer two.")) }
        await runner.tick(now: 8.1)
        await until("answer 2") { brain.sent("answer").count == 2 }
        XCTAssertEqual(brain.trace, ["sim_start", "spoken:s7", "partial", "answer:q1", "spoken:s12", "partial", "answer:q5"])
    }

    func testSilencePromptClosesMicUntilItsListen() async {
        await make()
        await openMic(line: "s1", q: "q1", at: 1)
        // 20 s later the brain offers to repeat: a new line for the same question
        brain.say(["type": "say", "id": "s2", "text": "Take your time — shall I repeat the question?", "final": true])
        brain.say(["type": "listen", "q_id": "q1"])
        await until("prompt playing") { voice.playingCount == 1 }
        mic.hear("take your time", start: 21, end: 22, final: true)
        await until("dropped") { await runner.droppedMicEvents == 1 }
        voice.release()
        await until("mic open again") { log.listening == ["q1", "q1"] }
        XCTAssertEqual(brain.trace, ["sim_start", "spoken:s1", "spoken:s2"])
    }

    func testControlsSendAndSkipStopsPlayback() async {
        await make()
        brain.say(["type": "say", "id": "s1", "text": "First.", "final": false])
        brain.say(["type": "say", "id": "s1", "text": "Second.", "final": true])
        await until("playing") { voice.playingCount == 1 }
        await runner.control(.repeat)
        await runner.control(.skip)
        await until("stopped") { voice.playingCount == 0 }
        await settle()
        XCTAssertEqual(voice.spoken, ["First."], "skip drops the queued sentence")
        XCTAssertTrue(brain.sent("spoken").isEmpty, "a skipped line is never reported as spoken")
        await runner.control(.end)
        XCTAssertEqual(brain.sent("control").compactMap { $0[string: "action"] }, ["repeat", "skip", "end"])
    }

    func testCoachProgressAndReport() async {
        await make()
        brain.say(["type": "sim_progress", "q_index": 3, "q_total": 8])
        brain.say(["type": "coach", "q_id": "q3", "lines": ["- Lead with the result [e2].", "Name the golden set [e3, e1]; it shows rigour."]])
        brain.say(["type": "sim_report", "path": "/tmp/sim-x/report.html"])
        await until("ended") { log.all.contains(.ended(code: 0)) }
        XCTAssertTrue(log.all.contains(.progress(index: 3, total: 8)))
        XCTAssertTrue(log.all.contains(.coach(qID: "q3", lines: ["- Lead with the result.", "Name the golden set; it shows rigour."])))
        XCTAssertTrue(log.all.contains(.report(path: "/tmp/sim-x/report.html")))
    }

    func testTextVoiceOpensMicWithoutWaiting() async {
        brain = FakeSimBrain()
        mic = FakeMic()
        log = EventLog()
        let l = log!
        runner = SimRunner(transport: brain, voice: TextVoice(), mic: mic, sink: { l.add($0) })
        await runner.start(sessionDir: URL(fileURLWithPath: "/tmp/sim-x"), mode: .realistic, voice: .text)
        brain.say(["type": "say", "id": "s1", "text": "Hello.", "final": true])
        brain.say(["type": "listen", "q_id": "q1"])
        await until("mic open") { log.listening == ["q1"] }
        XCTAssertEqual(brain.trace, ["sim_start", "spoken:s1"])
    }

    func testCitationsStripped() {
        XCTAssertEqual(SimText.stripCitations("Say the number [e2]."), "Say the number.")
        XCTAssertEqual(SimText.stripCitations("Use Lantern [e1, e3] and the golden set [e4]"), "Use Lantern and the golden set")
        XCTAssertEqual(SimText.stripCitations("No citations here."), "No citations here.")
        XCTAssertEqual(SimText.stripCitations("Array [0] stays"), "Array [0] stays")
    }

    func testDisclosureOnlyForCloudVoices() {
        XCTAssertTrue(SimText.needsAIDisclosure(.elevenlabs))
        XCTAssertTrue(SimText.needsAIDisclosure(.openai))
        XCTAssertFalse(SimText.needsAIDisclosure(.apple))
        XCTAssertFalse(SimText.needsAIDisclosure(.text))
    }

    func testFillersAndWords() {
        XCTAssertEqual(SimText.fillerCount("Um, I kind of, you know, basically shipped it. Like, actually."), 6)
        XCTAssertEqual(SimText.fillerCount("I liked it"), 0)
        XCTAssertEqual(SimText.wordCount("  two  words "), 2)
    }
}
