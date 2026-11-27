@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import VerseAudio
import VerseSpeech
@testable import VerseTurns
import XCTest

/// "Rehearse a line": a typed line enters where recognised speech enters. These runs use the real `VerseRunner`, `ListenSession`,
/// `TurnEngine` and the fake-transport brain process (`--fake`, no network); only the recognizer and the audio sources differ.
final class RehearsalRunnerTests: XCTestCase {
    static let question = "So why do you want to join our team next year?"
    static let answer = "Mostly because the product is close to what I built before"
    static let step = 0.18

    // MARK: pure pieces

    func testPartialPlanGrowsWordByWordToTheWholeLine() {
        XCTAssertEqual(RehearsalFeed.partialPlan("How are you"), ["How", "How are", "How are you"])
        XCTAssertEqual(RehearsalFeed.partialPlan("  Tell\nme   more "), ["Tell", "Tell me", "Tell me more"])
        XCTAssertEqual(RehearsalFeed.partialPlan(""), [])
        let long = RehearsalFeed.partialPlan(Self.question)
        XCTAssertLessThanOrEqual(long.count, RehearsalFeed.maxPartials)
        XCTAssertEqual(long.last, RehearsalFeed.clean(Self.question))
        // Each partial grows the one before it.
        for (a, b) in zip(long, long.dropFirst()) { XCTAssertTrue(b.hasPrefix(a) && b.count > a.count, "\(a) -> \(b)") }

        let results = RehearsalFeed.results(for: "How are you", start: 2, step: 0.5)
        XCTAssertEqual(results.map(\.text), ["How", "How are", "How are you", "How are you"])
        XCTAssertEqual(results.map(\.isFinal), [false, false, false, true])
        XCTAssertEqual(results.map(\.end), [2.5, 3.0, 3.5, 4.0])
    }

    /// The rehearsal environment builds no microphone, no process tap and asks for no permission.
    func testTheRehearsalEnvironmentCapturesNoAudio() throws {
        let feed = RehearsalFeed()
        let env = feed.environment()
        var cfg = ListenConfig(lang: "en", remoteBundleIDs: defaultRemoteBundleIDs, micEnabled: true, source: .live)
        let remote = try env.makeRemoteSource(cfg)
        let mic = try env.makeMicSource(cfg)
        XCTAssertTrue(remote is RehearsalSilenceSource, "remote: \(String(describing: remote))")
        XCTAssertTrue(mic is RehearsalSilenceSource, "me: \(String(describing: mic))")
        XCTAssertFalse(remote is ProcessTapSource)
        XCTAssertFalse(mic is MicSource)
        XCTAssertEqual(remote?.targetIsProducingOutput(), false, "silence reads as quiet, never as a dead stream")
        XCTAssertEqual(env.permissions.status(.microphone), .granted)
        XCTAssertEqual(env.permissions.status(.audioCapture), .granted)
        cfg.micAsRemote = true
        XCTAssertNil(try env.makeMicSource(cfg), "the room route has one channel, as with real audio")
        XCTAssertEqual(feed.sourcesMade, ["rehearsal (them, silence)", "rehearsal (me, silence)"])

        var o = RunOptions(sessionDir: URL(fileURLWithPath: "/nonexistent"))
        o.autoLanguage = true
        o.file = URL(fileURLWithPath: "/nonexistent.wav")
        feed.apply(to: &o)
        XCTAssertNotNil(o.listenEnvironment)
        XCTAssertNil(o.file)
        XCTAssertFalse(o.autoLanguage)
        XCTAssertFalse(o.autoShadow)
        XCTAssertEqual(o.seconds, 12 * 3600)
    }

    func testWorkspaceCopiesAndRemovesOnlyItsOwnFolder() throws {
        let session = try TempSession()
        defer { session.delete() }
        let copy = try RehearsalWorkspace.make(copying: session.dir)
        XCTAssertEqual(copy.lastPathComponent, session.dir.lastPathComponent)
        XCTAssertTrue(copy.deletingLastPathComponent().lastPathComponent.hasPrefix(RehearsalWorkspace.prefix))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("pack.md").path))
        XCTAssertFalse(RehearsalWorkspace.remove(session.dir), "a folder that is not a workspace is never removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.dir.path))
        XCTAssertTrue(RehearsalWorkspace.remove(copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }

    // MARK: the run

    /// A typed line as them and one as me give the same partial and turn lines to the brain, with the same detector fields (cue,
    /// kind, addressee), as the same text coming out of a recognizer; nothing is written to the prepared folder.
    func testTypedLinesReachTheBrainLikeRecognisedTextAndLeaveThePreparedFolderAlone() async throws {
        let prepared = try TempSession(bank: [(id: "b1", question: "Why do you want to join our team?",
                                               paraphrases: ["why do you want to join us", "why join our team"])])
        defer { prepared.delete() }
        let before = try Self.snapshot(prepared.dir)

        // 1. Rehearsal: the typed lines, on a temporary copy.
        let workspace = try RehearsalWorkspace.make(copying: prepared.dir)
        defer { RehearsalWorkspace.remove(workspace) }
        let feed = RehearsalFeed(stepSeconds: Self.step)
        var o = try Self.options(sessionDir: workspace)
        feed.apply(to: &o)
        let typed = try await Self.run(o) { listening in
            feed.say(.them, Self.question)
            try await Task.sleep(for: .seconds(Self.lineSeconds(Self.question) + 2.5))
            feed.say(.me, Self.answer)
            _ = listening
        }

        // 2. The same text, recognised: a scripted recognizer delivers the same results on the same timeline.
        let qStart = 0.3
        let aStart = qStart + Self.lineSeconds(Self.question) + 2.5
        let scripts: [Channel: [EngineResult]] = [.remote: RehearsalFeed.results(for: Self.question, start: qStart, step: Self.step),
                                                  .me: RehearsalFeed.results(for: Self.answer, start: aStart, step: Self.step)]
        let other = try TempSession(bank: [(id: "b1", question: "Why do you want to join our team?",
                                            paraphrases: ["why do you want to join us", "why join our team"])])
        defer { other.delete() }
        var r = try Self.options(sessionDir: other.dir)
        r.listenEnvironment = ListenEnvironment(
            permissions: FixedPermissions(),
            makeRemoteSource: { _ in RecordingSource(label: "tap") },
            makeMicSource: { cfg in cfg.micAsRemote ? nil : RecordingSource(label: "mic") },
            makeEngine: { cfg in ScriptedRecognizer(lang: cfg.lang, scripts: scripts) })
        r.source = .live
        r.seconds = 60
        let heard = try await Self.run(r) { _ in }

        let typedLines = Self.brainLines(typed.events)
        let heardLines = Self.brainLines(heard.events)
        print("[rehearsal] typed:\n" + typedLines.joined(separator: "\n"))
        print("[rehearsal] recognised:\n" + heardLines.joined(separator: "\n"))

        // Both speakers made it through as turns, the question with its detector fields.
        let turns = typed.events.outbound.filter { $0.type == "turn" }
        let them = try XCTUnwrap(turns.first { $0[string: "speaker"] == "remote" }, "a turn for them")
        let me = try XCTUnwrap(turns.first { $0[string: "speaker"] == "me" }, "a turn for me")
        XCTAssertEqual(them[string: "text"], RehearsalFeed.clean(Self.question))
        XCTAssertEqual(them[string: "kind"], "question")
        XCTAssertNotNil(them[string: "addressee"])
        XCTAssertEqual(me[string: "text"], RehearsalFeed.clean(Self.answer))
        XCTAssertTrue(typed.events.outbound.contains { $0.type == "partial" && $0[string: "speaker"] == "remote" && $0["cue"] != nil },
                      "growing partials with the question cue field went to the brain")
        XCTAssertEqual(typedLines, heardLines, "a typed line is the same to the pipeline as the same text recognised")

        // No audio source other than the rehearsal's silence was built.
        XCTAssertFalse(feed.sourcesMade.isEmpty)
        XCTAssertTrue(feed.sourcesMade.allSatisfy { $0.hasPrefix("rehearsal (") }, "\(feed.sourcesMade)")

        // The run wrote into the copy, never into the prepared folder.
        let written = (try? String(contentsOf: workspace.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertTrue(written.contains(RehearsalFeed.clean(Self.question)), "the transcript went to the temporary copy")
        XCTAssertEqual(try Self.snapshot(prepared.dir), before, "the prepared session folder is unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.dir.appendingPathComponent("transcript.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.dir.appendingPathComponent("events.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.dir.appendingPathComponent("summary.md").path))
    }

    // MARK: helpers

    /// How long a line takes to say: its partials and its final, one step each.
    static func lineSeconds(_ text: String) -> Double { Double(RehearsalFeed.partialPlan(text).count + 1) * step }

    static func options(sessionDir: URL) throws -> RunOptions {
        var o = RunOptions(sessionDir: sessionDir)
        o.lang = "en"
        o.fakeBrain = true
        o.brainDir = try brainDir()
        o.drainSeconds = 2
        o.quietSeconds = 0.5
        o.stopGraceSeconds = 10
        o.transcriptURL = sessionDir.appendingPathComponent("transcript.jsonl")
        return o
    }

    struct Outcome { var code: Int32; var events: [RunnerEvent] }

    /// Runs until listening starts, calls `drive`, waits for the turn engine to settle, then stops.
    static func run(_ base: RunOptions, drive: (Date) async throws -> Void) async throws -> Outcome {
        var o = base
        let rec = SinkRecorder()
        o.sink = rec.sink
        let runner = VerseRunner(options: o)
        let task = Task { await runner.run() }
        let t0 = Date()
        while !rec.all.contains(where: { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }) {
            if Date().timeIntervalSince(t0) > 60 { runner.requestStop(); _ = await task.value; throw XCTSkip("listening never started") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let listening = Date()
        try await drive(listening)
        // Both lines said and their turns closed (endpoint silence), with room to spare.
        let total = lineSeconds(question) + 2.5 + lineSeconds(answer) + 4.0
        let deadline = listening.addingTimeInterval(total + 6)
        while Date() < deadline {
            let meTurn = rec.all.outbound.contains { $0.type == "turn" && $0[string: "speaker"] == "me" }
            if meTurn, Date().timeIntervalSince(listening) > total { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        runner.requestStop()
        return Outcome(code: await task.value, events: rec.all)
    }

    /// The partial and turn lines that went to the brain, without their times (the two runs start their clocks apart).
    static func brainLines(_ events: [RunnerEvent]) -> [String] {
        events.outbound.filter { $0.type == "partial" || $0.type == "turn" }.map { o in
            var keep = o
            keep["t_audio_end"] = nil
            keep["dir"] = nil
            return JSONValue.object(keep).description
        }
    }

    /// Every file in a folder with its size and modification date.
    static func snapshot(_ dir: URL) throws -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let a = try fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            out[name] = "\(a[.size] ?? 0) \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }
}

/// Says the scripted results of its channel once the audio it was fed reaches each result's end, like a streaming recognizer.
/// 16-bit input, as Apple's analyzer asks for (a Float32 `AnalyzerInput` traps on macOS 27).
final class ScriptedRecognizer: TranscriptionEngine, @unchecked Sendable {
    let lang: String
    let engineName = "scripted"
    private let scripts: [Channel: [EngineResult]]
    private let lock = OSAllocatedUnfairLock()
    private var channel: Channel = .remote
    private var task: Task<Void, Never>?

    init(lang: String, scripts: [Channel: [EngineResult]]) {
        self.lang = lang
        self.scripts = scripts
    }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) { lock.withLockUnchecked { self.channel = channel } }
    func prepare() async throws -> AVAudioFormat { RehearsalEngine.format }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        var pending = scripts[lock.withLockUnchecked { channel }] ?? []
        task = Task.detached {
            var fed = 0.0
            for await item in input {
                fed += Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                while let r = pending.first, r.end <= fed {
                    onResult(r)
                    pending.removeFirst()
                }
            }
        }
    }

    func finish() async throws { await task?.value }
    func cancel() async { task?.cancel() }
}

private extension Array where Element == RunnerEvent {
    var outbound: [[String: JSONValue]] { compactMap { if case .outbound(let o) = $0 { return o }; return nil } }
}
