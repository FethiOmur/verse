@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import VerseAudio
import VerseSpeech
@testable import VerseTurns
import XCTest

// MARK: - the rig: fake audio, a scripted recognizer, the real runner and the real (fake-transport) brain process

/// Delivers exact zeros at real-time pace until stopped, and remembers when (host clock) its first and last chunk went out. No
/// audio is read or written anywhere: the recognizer below is scripted.
final class RecordingSource: AudioCaptureSource, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Never>?
    private var first: Double?
    private var last: Double?
    let label: String
    init(label: String) { self.label = label }
    var routeDescription: String { "recording stand-in (\(label))" }
    func targetIsProducingOutput() -> Bool? { false }
    /// Host time (seconds) of the first and the last chunk this source delivered.
    var firstChunk: Double? { lock.withLockUnchecked { first } }
    var lastChunk: Double? { lock.withLockUnchecked { last } }

    func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        let t0 = clock.now()
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            let cc = ContinuousClock()
            let base = cc.now
            var i = 0
            while !Task.isCancelled {
                try? await cc.sleep(until: base + .seconds(Double(i + 1) * 0.01))
                if Task.isCancelled { break }
                let host = HostTime.nowSeconds()
                self?.lock.withLockUnchecked {
                    if self?.first == nil { self?.first = host }
                    self?.last = host
                }
                onChunk(AudioChunk(samples: [Float](repeating: 0, count: 480), sampleRate: 48000, startTime: t0 + Double(i) * 0.01))
                i += 1
            }
        }
        lock.withLockUnchecked { task = t }
    }

    func stop() {
        let t = lock.withLockUnchecked { () -> Task<Void, Never>? in let t = task; task = nil; return t }
        t?.cancel()
    }
}

/// What each pipeline of a run was built from and what it did, in order.
final class SwapRig: @unchecked Sendable {
    struct Built: Equatable { var lang: String; var room: Bool; var channel: Channel }
    private let lock = OSAllocatedUnfairLock()
    private var built_: [Built] = []
    private var sources_: [RecordingSource] = []
    /// "lang|room" or "lang|meeting" -> what the recognizer of that channel says when the audio it was fed reaches `end`.
    var scripts: [String: [Channel: [EngineResult]]] = [:]
    /// What a real recognizer costs: loading a model, and flushing at the end of its input.
    var prepareDelay = 0.4
    var finishDelay = 0.15

    var built: [Built] { lock.withLockUnchecked { built_ } }
    var sources: [RecordingSource] { lock.withLockUnchecked { sources_ } }
    func addBuilt(_ b: Built) { lock.withLockUnchecked { built_.append(b) } }
    func addSource(_ s: RecordingSource) { lock.withLockUnchecked { sources_.append(s) } }

    func environment() -> ListenEnvironment {
        ListenEnvironment(
            permissions: FixedPermissions(),
            makeRemoteSource: { [self] cfg in
                // The room route's microphone is the remote source; a meeting's is the process tap.
                let s = RecordingSource(label: cfg.micAsRemote ? "mic as room" : "tap")
                addSource(s)
                return s
            },
            makeMicSource: { [self] cfg in
                if cfg.micAsRemote { return nil }
                let s = RecordingSource(label: "mic")
                addSource(s)
                return s
            },
            makeEngine: { [self] cfg in SwapEngine(lang: cfg.lang, room: cfg.micAsRemote, rig: self) })
    }
}

/// A recognizer that says what the test scripted once the audio it was fed reaches the end of each result, and settles its last
/// volatile text into a final when its input ends (as a real one does).
final class SwapEngine: TranscriptionEngine, @unchecked Sendable {
    let lang: String
    let engineName = "swap-fake"
    private let room: Bool
    private let rig: SwapRig
    private let lock = OSAllocatedUnfairLock()
    private var channel: Channel = .remote
    private var task: Task<Void, Never>?

    init(lang: String, room: Bool, rig: SwapRig) {
        self.lang = lang
        self.room = room
        self.rig = rig
    }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) {
        lock.withLockUnchecked { self.channel = channel }
        rig.addBuilt(.init(lang: lang, room: room, channel: channel))
    }

    func prepare() async throws -> AVAudioFormat {
        try? await Task.sleep(for: .seconds(rig.prepareDelay))
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        let ch = lock.withLockUnchecked { channel }
        var pending = (rig.scripts["\(lang)|\(room ? "room" : "meeting")"]?[ch] ?? []).sorted { $0.end < $1.end }
        task = Task.detached {
            var fed = 0.0
            var lastVolatile: EngineResult?
            for await item in input {
                fed += Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                while let r = pending.first, r.end <= fed {
                    onResult(r)
                    lastVolatile = r.isFinal ? nil : r
                    pending.removeFirst()
                }
            }
            if let v = lastVolatile { onResult(EngineResult(text: v.text, isFinal: true, start: v.start, end: v.end)) }
        }
    }

    func finish() async throws {
        await task?.value
        try? await Task.sleep(for: .seconds(rig.finishDelay))
    }

    func cancel() async { task?.cancel() }
}

/// One finished run of the rig and everything it showed.
struct SwapOutcome {
    var code: Int32
    var events: [RunnerEvent]
    var tapped: [TranscriptEvent]
    var rig: SwapRig
    var pidBefore: Int32
    var pidAfter: Int32
    var swapped: Bool
    var sessionDir: URL
    var summaryExists: Bool
    /// What the session folder's transcript.jsonl held at the end (read before the temp folder went away).
    var transcriptIDs: [String]
    /// A second `switchListening` to the route and language the call already had was refused.
    var repeatRefused: Bool

    var outbound: [[String: JSONValue]] { events.compactMap { if case .outbound(let o) = $0 { return o }; return nil } }
    var turns: [[String: JSONValue]] { outbound.filter { $0.type == "turn" } }
    var partials: [[String: JSONValue]] { outbound.filter { $0.type == "partial" } }
    var brainMetrics: [[String: JSONValue]] { events.compactMap { if case .brain(let o) = $0, o.type == "metric" { return o }; return nil } }
    func brainMetrics(_ stage: String) -> [[String: JSONValue]] { brainMetrics.filter { $0[string: "stage"] == stage } }
    var ownMetrics: [[String: JSONValue]] { events.compactMap { if case .metric(let o) = $0 { return o }; return nil } }
    func ownMetrics(_ stage: String) -> [[String: JSONValue]] { ownMetrics.filter { $0[string: "stage"] == stage } }

    /// Milliseconds of audio nobody listened to: from the last chunk of the old pipeline's last source to the first chunk of the
    /// new pipeline's first source (host clock, measured on the fake sources, independent of anything the runner reports).
    func gapMs(oldSources: [RecordingSource], newSources: [RecordingSource]) -> Double? {
        guard let a = oldSources.compactMap(\.lastChunk).max(), let b = newSources.compactMap(\.firstChunk).min() else { return nil }
        return (b - a) * 1000
    }
}

enum SwapScenario {
    /// A sentence the way a streaming recognizer delivers it: the words so far, again and again as it grows (one more word every
    /// `gap` seconds), and with `final` the same text once more as a settled result.
    static func utterance(_ text: String, from start: Double, gap: Double = 0.2, final: Bool = true) -> [EngineResult] {
        let words = text.split(separator: " ").map(String.init)
        var out: [EngineResult] = []
        for k in 1...words.count {
            out.append(EngineResult(text: words[..<k].joined(separator: " "), isFinal: false, start: start, end: start + gap * Double(k)))
        }
        if final { out.append(EngineResult(text: text, isFinal: true, start: start, end: start + gap * Double(words.count))) }
        return out
    }

    /// The sentence that is still being said (never finished) when the swap cuts in.
    static let open = "and what was the hardest part of the whole migration"
    static func openScript() -> [EngineResult] { utterance(open, from: 3.2, gap: 0.25, final: false) }

    /// Runs the real `VerseRunner` on the fake rig with the fake-transport brain (`--fake`). `swapAt`: seconds after the listen
    /// session started at which `switchListening` is called; `stopAfter`: seconds after the swap returned at which the run is asked to stop.
    static func run(startRoute: AudioRoute, lang: String = "en", swapRoute: AudioRoute? = nil, swapLang: String? = nil,
                    rig: SwapRig, swapAt: Double = 3.4, stopAfter: Double = 3.6) async throws -> SwapOutcome {
        let session = try TempSession()
        defer { session.delete() }
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = rig.environment()
        o.source = nil
        o.lang = lang
        o.route = startRoute
        o.mode = .unprepared
        o.follow = true
        o.fakeBrain = true
        o.brainDir = try brainDir()
        o.seconds = 60
        o.drainSeconds = 2
        o.quietSeconds = 0.5
        let rec = SinkRecorder()
        o.sink = rec.sink
        let tapped = TapBox()
        o.transcriptTap = { tapped.add($0) }
        o.transcriptURL = session.dir.appendingPathComponent("transcript.jsonl")
        let runner = VerseRunner(options: o)
        let task = Task { await runner.run() }

        // Wait for the listen session (the brain is warm by then).
        let t0 = Date()
        while !rec.all.contains(where: { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }) {
            if Date().timeIntervalSince(t0) > 60 { runner.requestStop(); _ = await task.value; throw XCTSkip("the brain never became ready") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let listenStart = Date()
        let pidBefore = runner.brainPID
        try await Task.sleep(for: .seconds(max(0, swapAt - Date().timeIntervalSince(listenStart))))
        let swapped = await runner.switchListening(route: swapRoute, lang: swapLang)
        let repeated = await runner.switchListening(route: swapRoute, lang: swapLang)
        try await Task.sleep(for: .seconds(stopAfter))
        let pidAfter = runner.brainPID
        runner.requestStop()
        let code = await task.value
        let summary = FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("summary.md").path)
        let transcript = (try? String(contentsOf: session.dir.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
        let ids = transcript.split(separator: "\n").compactMap { JSONValue.decodeObject(String($0))?[string: "turn_id"] }
        return SwapOutcome(code: code, events: rec.all, tapped: tapped.all, rig: rig, pidBefore: pidBefore, pidAfter: pidAfter,
                           swapped: swapped, sessionDir: session.dir, summaryExists: summary, transcriptIDs: ids, repeatRefused: !repeated)
    }
}

final class TapBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var events: [TranscriptEvent] = []
    func add(_ e: TranscriptEvent) { lock.withLockUnchecked { events.append(e) } }
    var all: [TranscriptEvent] { lock.withLockUnchecked { events } }
}

private func number(_ id: String) -> Int { Int(id.dropFirst()) ?? -1 }

// MARK: - the tests

/// Switching the route or the language in the middle of a call (anytime-swap): only the audio and recognition side is rebuilt; the
/// brain process, the session, the turn numbering and the summary are the call's.
final class ListenSwapTests: XCTestCase {

    // The scenarios are expensive (a real brain process, seconds of fake real-time audio): each runs once for the whole class.
    nonisolated(unsafe) private static var roomToMeeting: SwapOutcome?
    nonisolated(unsafe) private static var meetingToRoom: SwapOutcome?
    nonisolated(unsafe) private static var languageSwap: SwapOutcome?

    /// Room -> meeting. Leg 0 (room, English): one finished question, then a sentence that is still growing when the swap
    /// cuts in. Leg 1 (meeting, English): the other side asks a question, then Alex answers on the `me` channel.
    private func roomToMeeting() async throws -> SwapOutcome {
        if let o = Self.roomToMeeting { return o }
        let rig = SwapRig()
        rig.scripts["en|room"] = [.remote: SwapScenario.utterance("can you walk me through how you built the routing service", from: 0.3)
                                  + SwapScenario.openScript()]
        rig.scripts["en|meeting"] = [
            .remote: SwapScenario.utterance("how did you test it before the release", from: 0.3),
            .me: SwapScenario.utterance("we wrote contract tests and a replay harness", from: 2.2),
        ]
        let o = try await SwapScenario.run(startRoute: .room, swapRoute: .meeting, rig: rig, stopAfter: 4.4)
        Self.roomToMeeting = o
        return o
    }

    private func meetingToRoom() async throws -> SwapOutcome {
        if let o = Self.meetingToRoom { return o }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [
            .remote: SwapScenario.utterance("how did you test it before the release", from: 0.3) + SwapScenario.openScript(),
            .me: SwapScenario.utterance("we wrote contract tests and a replay harness", from: 2.2),
        ]
        rig.scripts["en|room"] = [.remote: SwapScenario.utterance("can you tell me how the migration went in the end", from: 0.3)]
        let o = try await SwapScenario.run(startRoute: .meeting, swapRoute: .room, rig: rig, swapAt: 3.6)
        Self.meetingToRoom = o
        return o
    }

    private func languageSwap() async throws -> SwapOutcome {
        if let o = Self.languageSwap { return o }
        let rig = SwapRig()
        rig.scripts["en|meeting"] = [.remote: SwapScenario.utterance("how did you test it before the release", from: 0.3) + SwapScenario.openScript()]
        // No question mark and no English cue: it is a question only when the engine knows the language is Italian now.
        rig.scripts["it|meeting"] = [.remote: SwapScenario.utterance("come hai costruito il servizio di instradamento", from: 0.3)]
        let o = try await SwapScenario.run(startRoute: .meeting, swapRoute: nil, swapLang: "it", rig: rig, stopAfter: 3.0)
        Self.languageSwap = o
        return o
    }

    // MARK: same process, same folder

    func testASwapKeepsTheSameBrainProcessAndSessionFolder() async throws {
        for (name, o) in [("route", try await roomToMeeting()), ("language", try await languageSwap())] {
            XCTAssertTrue(o.swapped, "\(name): the switch was applied")
            XCTAssertEqual(o.code, 0)
            XCTAssertGreaterThan(o.pidBefore, 0)
            XCTAssertEqual(o.pidBefore, o.pidAfter, "\(name): the brain process is the one that started the call")
            XCTAssertEqual(o.ownMetrics("session_t0").count, 1, "\(name): one start of the call")
            XCTAssertEqual(o.ownMetrics("session_t0").first?[double: "brain_pid"].map(Int32.init), o.pidBefore)
            let brainStatuses = o.events.compactMap { e -> String? in
                if case .brain(let b) = e, b.type == "status" { return b[string: "state"] }
                return nil
            }
            XCTAssertEqual(brainStatuses.filter { $0 == "ready" }.count, 1, "\(name): the brain was warmed once, not again after the swap")
            XCTAssertFalse(o.events.contains { if case .status(let st, _) = $0 { return st == "restarting" || st == "error" }; return false })
            // The session folder is the call's: one transcript.jsonl with the turns from before and after the swap, and one summary.
            XCTAssertEqual(o.transcriptIDs, o.turns.compactMap { $0[string: "turn_id"] }, "\(name): every turn sent is in the folder's transcript, in order")
            XCTAssertTrue(o.summaryExists, "\(name): summary.md was written into the same folder")
            XCTAssertTrue(o.repeatRefused, "\(name): asking for the route and language the call already has changes nothing")
            XCTAssertEqual(o.ownMetrics("listen_swap").count, 1)
        }
    }

    // MARK: numbering

    func testTurnIdsContinueAcrossTheSwap() async throws {
        for (name, o) in [("route", try await roomToMeeting()), ("language", try await languageSwap())] {
            let ids = o.turns.compactMap { $0[string: "turn_id"] }
            XCTAssertEqual(Set(ids).count, ids.count, "\(name): every turn id is used once: \(ids)")
            let remote = ids.filter { $0.hasPrefix("r") }.map(number)
            XCTAssertEqual(remote, Array(1...remote.count), "\(name): r1, r2, r3 ... with no restart at the swap: \(ids)")
            let swapAt = try XCTUnwrap(o.events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "listen_swap" }; return false })
            let before = o.events[..<swapAt].compactMap { e -> String? in
                if case .outbound(let b) = e, b.type == "turn" { return b[string: "turn_id"] }
                return nil
            }
            let after = o.events[swapAt...].compactMap { e -> String? in
                if case .outbound(let b) = e, b.type == "turn" { return b[string: "turn_id"] }
                return nil
            }
            XCTAssertFalse(before.isEmpty, "\(name): turns before the swap")
            XCTAssertFalse(after.isEmpty, "\(name): turns after the swap")
            let lastBefore = before.filter { $0.hasPrefix("r") }.map(number).max() ?? 0
            let firstAfter = after.filter { $0.hasPrefix("r") }.map(number).min() ?? 0
            XCTAssertEqual(firstAfter, lastBefore + 1, "\(name): the first new turn is the next number (\(before) | \(after))")
            // Event times continue on one timeline: nothing the recognizer said after the swap is dated before what it said earlier.
            let ends = o.tapped.map(\.audioEnd)
            let swapOffset = try XCTUnwrap(o.ownMetrics("listen_swap").first?[double: "offset"])
            let late = o.tapped.filter { $0.emittedAt >= swapOffset }
            XCTAssertFalse(late.isEmpty)
            XCTAssertTrue(late.allSatisfy { $0.audioStart >= swapOffset - 0.001 }, "\(name): the new pipeline's audio times start at the swap offset")
            XCTAssertEqual(ends.count, o.tapped.count)
        }
    }

    // MARK: language

    func testALanguageSwapSendsControlLangAndTheNewRecognizerLanguageIsUsed() async throws {
        let o = try await languageSwap()
        XCTAssertTrue(o.swapped)
        // The brain got `control lang` (it answers with a metric) and no route change.
        XCTAssertEqual(o.brainMetrics("lang_change").map { $0[string: "lang"] }, ["it"])
        XCTAssertTrue(o.brainMetrics("route_change").isEmpty, "only the language changed")
        // The recognizers of the new pipeline were built for Italian; the old ones for English.
        let langs = o.rig.built.map(\.lang)
        XCTAssertEqual(langs, ["en", "en", "it", "it"], "tap + mic per meeting pipeline")
        XCTAssertEqual(o.rig.built.map(\.room), [false, false, false, false])
        // What it heard is tagged Italian, and the turn engine reads it as Italian: no "?" and no English cue, yet a question.
        XCTAssertTrue(o.tapped.contains { $0.lang == "it" && $0.text.contains("instradamento") })
        XCTAssertTrue(o.tapped.filter { $0.lang == "en" }.allSatisfy { !$0.text.contains("instradamento") })
        let italian = try XCTUnwrap(o.turns.first { ($0[string: "text"] ?? "").contains("instradamento") })
        XCTAssertEqual(italian[string: "kind"], "question")
        XCTAssertEqual(o.ownMetrics("listen_swap").first?[string: "lang"], "it")
    }

    // MARK: route

    func testASwapFromRoomToMeetingEnablesTheMeChannelAndFollowMode() async throws {
        let o = try await roomToMeeting()
        XCTAssertTrue(o.swapped)
        // Pipelines: room = one (the microphone as remote); meeting = remote + me.
        XCTAssertEqual(o.rig.built, [.init(lang: "en", room: true, channel: .remote),
                                     .init(lang: "en", room: false, channel: .remote), .init(lang: "en", room: false, channel: .me)])
        XCTAssertTrue(o.tapped.contains { $0.channel == .me }, "the owner's own channel is open after the swap")
        // The brain was told: route changed, follow mode went from off (room) to on.
        XCTAssertEqual(o.brainMetrics("route_change").map { $0[string: "route"] }, ["meeting"])
        let follow = o.brainMetrics("follow_state").map { $0[bool: "on"] }
        XCTAssertEqual(follow, [false, true], "follow: off in the room, on in the meeting")
        // Before: room speaker, never `me`. After: remote and me, and the owner's own partials (follow my answer) flow.
        let speakers = o.turns.compactMap { $0[string: "speaker"] }
        XCTAssertEqual(speakers, ["room", "room", "remote", "me"], "\(o.turns.map { "\($0[string: "turn_id"] ?? "") \($0[string: "speaker"] ?? ""): \($0[string: "text"] ?? "")" })")
        XCTAssertTrue(o.partials.contains { $0[string: "speaker"] == "me" }, "follow mode: the owner's partials reach the brain")
        let swapAt = try XCTUnwrap(o.events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "listen_swap" }; return false })
        let mePartialsBefore = o.events[..<swapAt].filter { if case .outbound(let b) = $0 { return b[string: "speaker"] == "me" }; return false }
        XCTAssertTrue(mePartialsBefore.isEmpty)
        // The addressee logic is a meeting's again after the swap.
        let remoteTurn = try XCTUnwrap(o.turns.first { $0[string: "speaker"] == "remote" })
        XCTAssertEqual(remoteTurn[string: "addressee"], "me")
        XCTAssertEqual(o.turns.first?[string: "addressee"], "unknown", "room turns are for nobody in particular")
    }

    func testASwapFromMeetingToRoomTurnsFollowOffAndClosesTheMeChannel() async throws {
        let o = try await meetingToRoom()
        XCTAssertTrue(o.swapped)
        XCTAssertEqual(o.rig.built, [.init(lang: "en", room: false, channel: .remote), .init(lang: "en", room: false, channel: .me),
                                     .init(lang: "en", room: true, channel: .remote)])
        XCTAssertEqual(o.brainMetrics("route_change").map { $0[string: "route"] }, ["room"])
        XCTAssertEqual(o.brainMetrics("follow_state").map { $0[bool: "on"] }, [true, false])
        let swapAt = try XCTUnwrap(o.events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "listen_swap" }; return false })
        let after = o.events[swapAt...].compactMap { e -> [String: JSONValue]? in if case .outbound(let b) = e { return b }; return nil }
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0[string: "speaker"] != "me" }, "no me turn or partial after the swap: there is no me channel")
        XCTAssertTrue(after.contains { $0[string: "speaker"] == "room" })
        // me partials did flow while the call was a meeting.
        let before = o.events[..<swapAt].filter { if case .outbound(let b) = $0 { return b[string: "speaker"] == "me" }; return false }
        XCTAssertFalse(before.isEmpty, "follow mode was on in the meeting")
        // Nothing of the old me channel is left behind to turn up later.
        XCTAssertTrue(o.tapped.filter { $0.emittedAt >= (o.ownMetrics("listen_swap").first?[double: "offset"] ?? 0) }.allSatisfy { $0.channel == .remote })
    }

    // MARK: partials open at the swap

    func testAPartialOpenAtTheSwapIsFinalizedOnceAndNeverDuplicated() async throws {
        for (name, o) in [("room to meeting", try await roomToMeeting()), ("meeting to room", try await meetingToRoom()), ("language", try await languageSwap())] {
            let swapAt = try XCTUnwrap(o.events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "listen_swap" }; return false })
            // The growing sentence ("and what was the hardest ...") was open when the old pipeline stopped.
            let growing = o.turns.filter { ($0[string: "text"] ?? "").hasPrefix("and what was") }
            XCTAssertEqual(growing.count, 1, "\(name): exactly one turn for the open sentence: \(growing)")
            let id = try XCTUnwrap(growing.first?[string: "turn_id"])
            let turnIndex = try XCTUnwrap(o.events.firstIndex { if case .outbound(let b) = $0 { return b.type == "turn" && b[string: "turn_id"] == id }; return false })
            XCTAssertLessThan(turnIndex, swapAt, "\(name): it was closed by the swap, before the new pipeline started")
            // Its partials all precede its turn; no partial or turn with that id comes after.
            let later = o.events[(turnIndex + 1)...].filter { if case .outbound(let b) = $0 { return b[string: "turn_id"] == id }; return false }
            XCTAssertTrue(later.isEmpty, "\(name): nothing for \(id) after its turn")
            // The text of that turn is the last thing the old recognizer said, not a half-sentence and not a doubled one.
            let text = try XCTUnwrap(growing.first?[string: "text"])
            XCTAssertTrue(SwapScenario.open.hasPrefix(text), "\(name): the turn is the sentence so far, once: \(text)")
            XCTAssertGreaterThanOrEqual(text.split(separator: " ").count, 3, "\(name): the recognizer had said a few words: \(text)")
            // And the new pipeline's first words start a new turn instead of continuing it.
            let ids = o.turns.compactMap { $0[string: "turn_id"] }
            XCTAssertEqual(Set(ids).count, ids.count)
        }
    }

    // MARK: summary / stop

    func testStopAfterASwapRunsTheSummaryOnceAndCoversTurnsFromBeforeAndAfter() async throws {
        for (name, o) in [("route", try await roomToMeeting()), ("language", try await languageSwap())] {
            XCTAssertEqual(o.code, 0)
            let finals = o.brainMetrics("summary_final")
            XCTAssertEqual(finals.count, 1, "\(name): the end-of-meeting summary ran once, at the end of the call")
            // The brain's final merge saw every finalized turn of the call: the ones before the swap and the ones after.
            let sent = o.turns.count
            XCTAssertGreaterThanOrEqual(sent, 3)
            XCTAssertEqual(finals.first?[double: "turns"].map(Int.init), sent, "\(name): the summary covers all \(sent) turns sent to the brain")
            let swapAt = try XCTUnwrap(o.events.firstIndex { if case .metric(let m) = $0 { return m[string: "stage"] == "listen_swap" }; return false })
            let summaryAt = try XCTUnwrap(o.events.firstIndex { if case .brain(let b) = $0 { return b[string: "stage"] == "summary_final" }; return false })
            XCTAssertGreaterThan(summaryAt, swapAt, "\(name): not at the swap")
            XCTAssertTrue(o.summaryExists, "\(name)")
            // No final summary before the swap: the swap did not run the end-of-meeting steps.
            XCTAssertFalse(o.events[..<swapAt].contains { if case .brain(let b) = $0 { return b[string: "stage"] == "summary_final" || (b.type == "summary" && b[bool: "final"] == true) }; return false })
        }
    }

    // MARK: the gap

    func testTheGapOfASwapIsUnderOneAndAHalfSeconds() async throws {
        let o = try await roomToMeeting()
        let sources = o.rig.sources
        XCTAssertEqual(sources.map(\.label), ["mic as room", "tap", "mic"])
        // The new pipeline's recognizer needed 0.4 s to load (rig.prepareDelay) and 0.15 s to flush (rig.finishDelay); the load
        // happened while the old pipeline still listened, so the gap is the flush plus the start of the new sources.
        let gap = try XCTUnwrap(o.gapMs(oldSources: [sources[0]], newSources: [sources[1], sources[2]]))
        let reported = try XCTUnwrap(o.ownMetrics("listen_swap").first?[double: "gap_ms"])
        print(String(format: "[swap] measured gap between the last old chunk and the first new chunk: %.0f ms (runner reports %.0f ms; model load %.0f ms hidden behind the old pipeline, flush %.0f ms)",
                     gap, reported, o.rig.prepareDelay * 1000, o.rig.finishDelay * 1000))
        XCTAssertLessThan(gap, 1500)
        XCTAssertGreaterThan(gap, 0)
        XCTAssertLessThan(reported, 1500)
        let lg = try await languageSwap()
        let ls = lg.rig.sources
        let gap2 = try XCTUnwrap(lg.gapMs(oldSources: [ls[0], ls[1]], newSources: [ls[2], ls[3]]))
        print(String(format: "[swap] language swap gap: %.0f ms", gap2))
        XCTAssertLessThan(gap2, 1500)
    }

    // MARK: not possible

    func testASwapThatChangesNothingOrComesOutOfTurnIsRefused() async throws {
        let session = try TempSession()
        defer { session.delete() }
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = SwapRig().environment()
        o.route = .room
        o.fakeBrain = true
        o.brainDir = try brainDir()
        let runner = VerseRunner(options: o)
        let early = await runner.switchListening(route: .meeting)
        XCTAssertFalse(early, "nothing is listening yet")
    }
}
