import Darwin
import Foundation
import os
import VerseSpeech

public enum OutputFormat: String, Sendable {
    /// One JSON object per line: the brain's lines verbatim, plus `chip` and local `metric` lines.
    case json
    /// The same events as short human-readable lines.
    case text
}

/// A decoded JSON value, so runner events can cross actor boundaries and be compared in tests.
public enum JSONValue: Sendable, Equatable, Codable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let d) = self { return d }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    public var description: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let a): return "[" + a.map(\.description).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0):\(o[$0]!.description)" }.joined(separator: ",") + "}"
        }
    }

    /// One JSON object line, or nil when the line is not a JSON object.
    public static func decodeObject(_ line: String) -> [String: JSONValue]? {
        guard let d = line.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d),
              case .object(let o) = v else { return nil }
        return o
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    subscript(string key: String) -> String? { self[key]?.string }
    subscript(double key: String) -> Double? { self[key]?.double }
    subscript(bool key: String) -> Bool? { self[key]?.bool }
    var type: String { self[string: "type"] ?? "" }
}

/// What the runner reports to a front end (the app's overlay). Every line `verse-run` prints maps to exactly one
/// event, in the same order; `object` gives that line back. `outbound` and `ended` are sink-only extras (`outbound`
/// is printed only with `--echo`).
public enum RunnerEvent: Sendable, Equatable {
    /// A line from the brain's stdout, decoded (`delta`, `select`, `opener_status`, `status`, `metric`, ...).
    case brain([String: JSONValue])
    /// A fact chip from the turn engine (`{type:"chip", turn_id, kind, text, source_ref, fact_id}`).
    case chip([String: JSONValue])
    /// A metric the runner measures itself (`session_t0`, `turn_sent`, `first_text`).
    case metric([String: JSONValue])
    /// A status the runner makes itself: `restarting` and `error` (brain supervision), `permission_denied`
    /// (message = `audioCapture` | `microphone`, sink only), `listen_failed` (sink only).
    case status(state: String, message: String)
    /// A problem the listen session reported while running (`{type:"issue", code, message}`).
    case issue(code: String, message: String)
    /// Raw loudness of the last 200 ms per channel in dBFS (nil: exact silence or no such channel), about ten times a
    /// second (sink only; nothing is printed). It moves the "Listening" label with the sound, before any text exists.
    case level(remoteDbfs: Double?, meDbfs: Double?)
    /// A line sent to the brain (`partial`, `turn`, `bank_hit`), with `dir:"to_brain"`.
    case outbound([String: JSONValue])
    /// The run is over (sink only). Exit code as `run()` returns it.
    case ended(exitCode: Int32)

    /// The JSON object `verse-run` prints for this event (nil for `ended`).
    public var object: [String: JSONValue]? {
        switch self {
        case .brain(let o), .chip(let o), .metric(let o), .outbound(let o): return o
        case .status(let st, let m): return ["type": .string("status"), "state": .string(st), "message": .string(m)]
        case .issue(let c, let m): return ["type": .string("issue"), "code": .string(c), "message": .string(m)]
        case .ended, .level: return nil
        }
    }

    /// Classifies one line the runner would print. `fromBrain`: the line came verbatim from the brain.
    static func classify(_ o: [String: JSONValue], fromBrain: Bool) -> RunnerEvent {
        if fromBrain { return .brain(o) }
        if o[string: "dir"] == "to_brain" { return .outbound(o) }
        switch o.type {
        case "chip": return .chip(o)
        case "metric": return .metric(o)
        case "status": return .status(state: o[string: "state"] ?? "", message: o[string: "message"] ?? "")
        case "issue": return .issue(code: o[string: "code"] ?? "", message: o[string: "message"] ?? "")
        default: return .metric(o)
        }
    }
}

public struct RunOptions: Sendable {
    public var sessionDir: URL
    public var lang = "en"
    /// Stop listening after this long. nil: a file plays to its end; live listens for `defaultLiveSeconds`.
    public var seconds: Double?
    public var file: URL?
    /// Tests and the replay harness: an explicit listen source (e.g. `.memory(remote:me:)` for both speakers).
    /// Overrides `file`; nil: `file` when set, otherwise live.
    public var source: ListenConfig.Source?
    public var micEnabled = true
    /// With `file`: keep the real microphone open as "me" while the file plays as the remote channel (the app's
    /// "Play test file as remote"). Off (the default, and `--file` of `verse-run`): the file run is remote-only.
    public var micWithFile = false
    /// The echo gate of the microphone channel (envelope correlation with the remote channel). Bleed measurements switch
    /// it off by setting a threshold above 1 (`verse-run --no-bleed-gate`).
    public var bleedGate = BleedGate()
    public var bundleIDs = defaultRemoteBundleIDs
    public var brainDir: URL?
    /// Brain with canned replies (`--fake`): no network, no key. For tests of the plumbing.
    public var fakeBrain = false
    public var budgetUSD: Double?
    public var turn = TurnConfig()
    /// "Follow my answer": the brain gets `follow:true` in `start` and the owner's own partials (speaker `me`). Never in the
    /// room route: there is no `me` channel to follow.
    public var follow = false
    /// Anytime calls (spec 2.1, 3). `mode` and `route` go to the brain in `start` only when they are not today's
    /// (prepared, meeting). `.room` makes the microphone the only audio: its turns are `room` turns, with no `me` channel.
    public var mode = SessionMode.prepared
    public var route = AudioRoute.meeting
    /// The permanent "me" layer's files, or nil (the layer is off; `start` carries no `me`).
    public var me: MeProfilePaths?
    /// Room route: which room turns get a card by themselves (Settings → Meetings → "Room auto cards").
    public var roomAuto = RoomAuto.questions
    /// How long to wait for the brain's answers after the audio ended, at most.
    public var drainSeconds = 15.0
    /// ... and how long the brain must be quiet before that wait ends early.
    public var quietSeconds = 3.0
    public var readyTimeout = 45.0
    public var format = OutputFormat.json
    /// Also print the partial/turn/bank_hit lines that go to the brain.
    public var echoOutbound = false
    /// Log every transcript event and the remote level (10 per second) to stderr.
    public var trace = false
    /// When set, every event goes here instead of stdout (already decoded), plus the sink-only extras. nil: stdout,
    /// byte for byte as before.
    public var sink: (@Sendable (RunnerEvent) -> Void)?
    /// T4: every transcript event of both channels, as it leaves the recognizer, before the turn engine sees it. The
    /// app's teleprompter takes the `Channel.me` events from here instead of opening a second microphone session.
    public var transcriptTap: (@Sendable (TranscriptEvent) -> Void)?
    /// Tests: with a sink, also write every line verse-run would print here, so one run can be checked for sink/stdout
    /// parity (two separate runs differ in timing-dependent lines such as hedges).
    public var mirrorOutput: FileHandle?
    /// When set, every finalized turn (both speakers) is appended here as one JSON line
    /// `{turn_id, speaker, text, addressee, kind, t_audio_end}` and flushed. Text only, never audio.
    public var transcriptURL: URL?
    /// How long after it was sent a question still counts as "being answered" when the brain crashes (it is re-sent
    /// to the restarted brain).
    public var resendWindowSeconds = 20.0

    public static let defaultLiveSeconds = 60.0

    public init(sessionDir: URL) { self.sessionDir = sessionDir }
}

/// The headless end-to-end run: ListenSession -> TurnEngine -> brain child process -> stdout (or `RunOptions.sink`).
///
/// Nothing here writes audio. The brain is killed on every way out: normal end, `requestStop()` (SIGINT/SIGTERM) and errors.
/// Supervision: when the brain exits unexpectedly it is restarted once with the same session; a second crash stops
/// listening and ends the run with `status error`.
public final class VerseRunner: @unchecked Sendable {
    private enum Input: Sendable {
        case event(TranscriptEvent)
        case tick(TimeInterval, Double?)
        case ended
    }

    private enum BrainPhase: Sendable {
        /// The first brain is starting; a crash here fails the run (no restart).
        case starting
        case running
        case restarting
        case failed
    }

    private let options: RunOptions
    private let outLock = OSAllocatedUnfairLock()
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let logFn: @Sendable (String) -> Void

    private struct State {
        var stopRequested = false
        var shuttingDown = false
        var wall0 = 0.0
        var lastBrainLine = Date()
        var lastTurnSent: Date?
        var turnsSent = 0
        var turnSentWall: [String: (wall: Double, audioEnd: Double)] = [:]
        var firstTextDone: Set<String> = []
        var ready: String?
        var lineBuf: [String: String] = [:]
        var session: ListenSession?
        // supervision
        var brain: BrainProcess?
        var reader: Task<Void, Never>?
        var phase = BrainPhase.starting
        var restarts = 0
        var lastQuestion: (event: OutboundEvent, sent: Date)?
        var pendingQuestion: OutboundEvent?
        var brainFailed = false
        /// The turn engine of the running session, for the brain's paraphrase hits (`noteBrainBankHit`).
        var engine: TurnEngine?
    }

    private let transcript = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    /// How often a `.level` event is sent to the sink.
    public static let levelPeriodMs = 100

    public init(options: RunOptions, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.options = options
        self.logFn = log
    }

    /// Ends listening early (SIGINT, the app's Stop). The run still shuts the brain down.
    public func requestStop() {
        let session = state.withLock { s -> ListenSession? in s.stopRequested = true; return s.session }
        if let session { Task { await session.stop() } }
    }

    /// The pid of the brain that is running now (0 when none).
    public var brainPID: Int32 { state.withLock { $0.brain?.pid ?? 0 } }

    // MARK: output

    /// A line as verse-run prints it. With a sink the line is decoded and handed over instead.
    private func emit(_ line: String, fromBrain: Bool = false) {
        if line.isEmpty { return }
        outLock.withLockUnchecked {
            if let sink = options.sink {
                if let o = JSONValue.decodeObject(line) { sink(RunnerEvent.classify(o, fromBrain: fromBrain)) }
                options.mirrorOutput?.write(Data((line + "\n").utf8))
            } else {
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        }
    }

    /// Sink-only events (nothing is printed for them).
    private func emitSinkOnly(_ e: RunnerEvent) {
        guard let sink = options.sink else { return }
        outLock.withLockUnchecked { sink(e) }
    }

    private func emitJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let s = String(decoding: d, as: UTF8.self)
        if options.format == .json || options.sink != nil { emit(s) } else { emit(Self.textLine(obj)) }
    }

    private func log(_ s: String) { logFn(s) }

    // MARK: run

    /// Runs to the end. Exit code: 0 ok, 1 failure, 2 bad session folder, 3 permission denied.
    public func run() async -> Int32 {
        let code = await runInner()
        closeTranscript()
        emitSinkOnly(.ended(exitCode: code))
        return code
    }

    private func runInner() async -> Int32 {
        let o = options
        guard FileManager.default.fileExists(atPath: o.sessionDir.appendingPathComponent("pack.md").path) else {
            log("session folder has no pack.md: \(o.sessionDir.path)")
            return 2
        }
        var turnCfg = o.turn
        turnCfg.lang = o.lang
        if o.follow, o.route != .room { turnCfg.emitMePartials = true }
        if o.route == .room {
            turnCfg.roomMode = true
            turnCfg.roomAuto = o.roomAuto
        }
        let bank: Bank, facts: FactIndex
        do {
            bank = try Bank.load(sessionDir: o.sessionDir)
            facts = try FactIndex.load(sessionDir: o.sessionDir)
        } catch {
            log("cannot read the session folder: \(error)")
            return 2
        }
        let engine = TurnEngine(config: turnCfg, bank: bank, facts: facts)
        state.withLock { $0.engine = engine }
        openTranscript()

        // The brain first: its pre-warm must be done before the first question is heard.
        let brainDir: URL
        do {
            brainDir = try BrainProcess.locateBrainDir(explicit: o.brainDir)
            try spawnBrain(dir: brainDir)
        } catch {
            log("\(error)")
            return 1
        }
        func stopBrain() async {
            let (b, r) = state.withLock { s -> (BrainProcess?, Task<Void, Never>?) in s.shuttingDown = true; return (s.brain, s.reader) }
            await b?.shutdown()
            await r?.value
        }

        let readyState = await startAndWaitReady()
        if readyState == Self.stoppedWhileStarting {
            // Stop pressed while the brain was still warming: end at once instead of waiting out readyTimeout.
            log("stop requested while the brain was starting")
            await stopBrain()
            return 0
        }
        if readyState == nil || readyState == "error" || readyState == "credit_exhausted" {
            log("brain did not become ready (\(readyState ?? "timeout")); stopping")
            await stopBrain()
            return 1
        }
        state.withLock { if $0.phase == .starting { $0.phase = .running } }
        let firstPID = brainPID

        // Listening.
        let source: ListenConfig.Source = o.source ?? (o.file.map { .file($0) } ?? .live)
        let mic: Bool
        switch source {
        case .live: mic = o.micEnabled
        case .file: mic = o.micEnabled && o.micWithFile
        case .memory(let remote, let me): mic = o.route == .room ? (me ?? remote) != nil : me != nil
        }
        var cfg = ListenConfig(lang: o.lang, remoteBundleIDs: o.bundleIDs, micEnabled: mic, source: source)
        cfg.micAsRemote = o.route == .room
        cfg.voiceProcessing = false
        cfg.micWithFile = o.micWithFile
        cfg.bleedGate = o.bleedGate
        let session = ListenSession(config: cfg)
        let stream: AsyncStream<TranscriptEvent>
        do {
            stream = try await session.start()
        } catch let e as ListenError {
            log("listen failed: \(e.description)")
            if case .permissionDenied(let kind) = e {
                emitSinkOnly(.status(state: "permission_denied", message: kind.rawValue))
            } else {
                emitSinkOnly(.status(state: "listen_failed", message: e.description))
            }
            await stopBrain()
            return e.code == "permission_denied" ? 3 : 1
        } catch {
            log("listen failed: \(error)")
            emitSinkOnly(.status(state: "listen_failed", message: "\(error)"))
            await stopBrain()
            return 1
        }
        let stopEarly = state.withLock { s -> Bool in s.session = session; return s.stopRequested || s.brainFailed }
        let now0 = await session.now()
        let origin = await session.channelOrigin(.remote) ?? 0
        let originMe = await session.channelOrigin(.me)
        let wall0 = Date().timeIntervalSince1970 - now0
        state.withLock { $0.wall0 = wall0 }
        var t0: [String: Any] = ["type": "metric", "turn_id": "", "stage": "session_t0", "t": Text.ms(wall0), "origin_remote": Text.ms(origin),
                                 "source": "verse-run", "lang": o.lang, "fake_brain": o.fakeBrain, "brain_pid": Int(firstPID)]
        if let originMe { t0["origin_me"] = Text.ms(originMe) }
        emitJSON(t0)
        if stopEarly { await session.stop() }

        let (inputs, cont) = AsyncStream.makeStream(of: Input.self, bufferingPolicy: .unbounded)
        let pump = Task {
            for await e in stream { cont.yield(.event(e)) }
            cont.yield(.ended)
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let t = await session.now()
                let level = await session.levels(window: 0.1)[.remote]
                cont.yield(.tick(t, level?.rmsDbfs))
            }
        }
        // Raw level for the overlay's "Listening" label (a front end only: nothing without a sink).
        let levelTask: Task<Void, Never>? = options.sink == nil ? nil : Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.levelPeriodMs))
                if Task.isCancelled { break }
                let lv = await session.levels(window: 0.2)
                self?.emitSinkOnly(.level(remoteDbfs: lv[.remote]?.rmsDbfs, meDbfs: lv[.me]?.rmsDbfs))
            }
        }
        let issues = Task { [weak self] in
            for await issue in session.issues {
                self?.emitJSON(["type": "issue", "code": issue.code, "message": issue.description])
            }
        }
        let timer = Task { [weak self] in
            var isLive = false
            if case .live = source { isLive = true }
            let limit = o.seconds ?? (isLive ? RunOptions.defaultLiveSeconds : nil)
            guard let limit else { return }
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { self?.log("time limit reached"); await session.stop() }
        }

        loop: for await input in inputs {
            switch input {
            case .event(let e):
                o.transcriptTap?(e)
                if o.trace { log(String(format: "trace event %@ t=%.2f audio=%.2f-%.2f final=%@ %@", e.channel.rawValue, e.emittedAt, e.audioStart, e.audioEnd, e.isFinal ? "y" : "n", e.text)) }
                dispatch(await engine.ingestTimed(e))
                for d in await engine.takeEchoDrops() {
                    emitJSON(["type": "metric", "turn_id": "", "stage": "echo_guard_dropped", "text": d.text, "is_final": d.isFinal,
                              "audio_start": Text.ms(d.audioStart), "audio_end": Text.ms(d.audioEnd), "similarity": Text.ms(d.similarity),
                              "source": "verse-run"])
                }
            case .tick(let t, let db):
                if o.trace, Int(t * 100) % 10 == 0 { log(String(format: "trace level t=%.2f %@", t, db.map { String(format: "%.1f dBFS", $0) } ?? "silent")) }
                dispatch(await engine.noteRemoteLevel(db, at: t))
            case .ended:
                break loop
            }
        }
        ticker.cancel()
        levelTask?.cancel()
        timer.cancel()
        pump.cancel()
        dispatch(await engine.flush(at: await session.now()))
        // What the two echo defenses discarded (text and times only), one line each plus a total.
        for d in session.droppedEchoLog {
            emitJSON(["type": "metric", "turn_id": "", "stage": "echo_gate_dropped", "text": d.text, "is_final": d.isFinal,
                      "audio_start": Text.ms(d.audioStart), "audio_end": Text.ms(d.audioEnd), "score": Text.ms(d.score), "source": "verse-run"])
        }
        if o.trace {
            for d in session.gateDecisions {
                let w = d.features.window
                var row: [String: Any] = ["type": "metric", "turn_id": "", "stage": "echo_gate_decision", "text": d.text, "is_final": d.isFinal,
                                          "audio_start": Text.ms(d.audioStart), "audio_end": Text.ms(d.audioEnd), "score": Text.ms(d.features.score),
                                          "lag_ms": Text.ms(d.features.lagMs), "mic_only": Text.ms(w.micOnlyShare), "remote_active": Text.ms(w.remoteActiveShare),
                                          "verdict": d.verdict.rawValue, "source": "verse-run"]
                if let x = w.ratioDb { row["ratio_db"] = Text.ms(x) }
                if let x = w.meDb { row["me_db"] = Text.ms(x) }
                if let x = w.remoteDb { row["remote_db"] = Text.ms(x) }
                emitJSON(row)
            }
        }
        var summary: [String: Any] = ["type": "metric", "turn_id": "", "stage": "listen_summary",
                                      "echo_gate_dropped": session.droppedEchoEvents, "source": "verse-run"]
        if let r = await session.channelOrigin(.remote) { summary["origin_remote"] = Text.ms(r) }
        if let m = await session.channelOrigin(.me) { summary["origin_me"] = Text.ms(m) }
        emitJSON(summary)

        // Let the brain finish what it has started.
        await drain()
        await session.stop()
        issues.cancel()
        await stopBrain()
        return state.withLock { $0.brainFailed } ? 1 : 0
    }

    // MARK: brain supervision

    private func brainArgs() -> [String] {
        var args: [String] = []
        if options.fakeBrain { args.append("--fake") }
        if let b = options.budgetUSD { args += ["--budget-usd", String(b)] }
        return args
    }

    /// Starts a brain process and its stdout reader, and makes it the current one.
    private func spawnBrain(dir: URL) throws {
        let b = try BrainProcess(brainDir: dir, extraArgs: brainArgs(), onStderr: { [logFn] l in logFn("[brain] " + l) })
        try b.start()
        let reader = Task { [weak self] in
            for await line in b.lines { self?.handleBrainLine(line) }
            self?.brainEnded(b, dir: dir)
        }
        state.withLock { s in
            s.brain = b
            s.reader = reader
            s.ready = nil
        }
    }

    /// The `start` message: the anytime-calls fields only where they differ from a prepared meeting session, so that one
    /// produces exactly the line it always did.
    func startCommand() -> BrainCommand {
        let room = options.route == .room
        return .start(sessionDir: options.sessionDir.path, lang: options.lang, follow: options.follow && !room,
                      mode: options.mode == .prepared ? nil : options.mode, route: options.route == .meeting ? nil : options.route,
                      me: options.me, roomAuto: room ? options.roomAuto : nil)
    }

    /// ⌥⌘↩: the brain answers the latest remote/room turn now (the open partial, else the last final). Nothing happens
    /// when no brain is running.
    public func cardNow() { sendControl(.cardNow) }

    /// The session language from now on. The listen engines restart on the Swift side (the controller); this only tells the
    /// brain which language the cards come in.
    public func setLanguage(_ lang: String) { sendControl(.setLanguage(lang)) }

    private func sendControl(_ c: BrainCommand) {
        let brain: BrainProcess? = state.withLock { s in s.phase == .running ? s.brain : nil }
        brain?.send(c.jsonLine())
    }

    /// Sends `start` to the current brain and waits for its first readiness status.
    private func startAndWaitReady() async -> String? {
        guard let b = state.withLock({ $0.brain }) else { return "error" }
        b.send(startCommand().jsonLine())
        return await waitReady(timeout: options.readyTimeout, brain: b)
    }

    private func brainEnded(_ b: BrainProcess, dir: URL) {
        enum Next { case nothing, reportStartup, restart, fail }
        let next: Next = state.withLock { s in
            guard !s.shuttingDown, s.brain === b else { return .nothing }
            switch s.phase {
            case .starting: return .reportStartup
            case .failed: return .nothing
            case .running, .restarting:
                if s.restarts == 0 {
                    s.restarts = 1
                    s.phase = .restarting
                    if let q = s.lastQuestion, Date().timeIntervalSince(q.sent) <= options.resendWindowSeconds { s.pendingQuestion = q.event }
                    return .restart
                }
                s.phase = .failed
                s.brainFailed = true
                return .fail
            }
        }
        switch next {
        case .nothing: return
        case .reportStartup:
            log("the brain process ended unexpectedly")
            emitJSON(["type": "status", "state": "error", "message": "brain process ended unexpectedly"])
        case .restart:
            log("the brain process ended unexpectedly; restarting it once")
            emitJSON(["type": "status", "state": "restarting", "message": "brain process ended unexpectedly; restarting"])
            Task { [weak self] in await self?.restartBrain(dir: dir) }
        case .fail:
            failBrain("brain process ended unexpectedly again")
        }
    }

    private func failBrain(_ message: String) {
        state.withLock { s in s.phase = .failed; s.brainFailed = true }
        log(message + "; stopping")
        emitJSON(["type": "status", "state": "error", "message": message])
        let session = state.withLock { $0.session }
        if let session { Task { await session.stop() } }
    }

    private func restartBrain(dir: URL) async {
        do {
            try spawnBrain(dir: dir)
        } catch {
            failBrain("could not restart the brain: \(error)")
            return
        }
        let r = await startAndWaitReady()
        guard let r, r != "error", r != "credit_exhausted", r != Self.stoppedWhileStarting else {
            // A crash during the restart is reported by brainEnded (second crash); a hang or an error status is not.
            if state.withLock({ $0.phase }) == .restarting { failBrain("the restarted brain did not become ready (\(r ?? "timeout"))") }
            return
        }
        let (resend, b): (OutboundEvent?, BrainProcess?) = state.withLock { s in
            guard s.phase == .restarting else { return (nil, nil) }
            s.phase = .running
            let q = s.pendingQuestion
            s.pendingQuestion = nil
            return (q, s.brain)
        }
        if let resend, let b {
            log("re-sending \(resend.turnID) to the restarted brain")
            b.send(resend.jsonLine())
            state.withLock { s in s.lastQuestion = (resend, Date()); s.lastTurnSent = Date() }
            if options.echoOutbound { echoOutbound(resend) } else { emitSinkOnly(.outbound(outboundObject(resend))) }
        }
    }

    private func waitReady(timeout: TimeInterval, brain: BrainProcess) async -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = state.withLock({ $0.ready }) { return r }
            if state.withLock({ $0.stopRequested }) { return Self.stoppedWhileStarting }
            if !brain.isRunning { return "error" }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// `waitReady`'s answer when Stop came before the brain was ready.
    static let stoppedWhileStarting = "stopped"

    private func drain() async {
        let (stop, turns, failed) = state.withLock { ($0.stopRequested, $0.turnsSent, $0.brainFailed) }
        guard !stop, !failed, turns > 0 else { return }
        let end = Date().addingTimeInterval(options.drainSeconds)
        while Date() < end, !state.withLock({ $0.stopRequested || $0.brainFailed }) {
            let (lastLine, lastTurn, brain, phase) = state.withLock { ($0.lastBrainLine, $0.lastTurnSent ?? .distantPast, $0.brain, $0.phase) }
            if phase != .restarting, !(brain?.isRunning ?? false) { break }
            let quiet = Date().timeIntervalSince(max(lastLine, lastTurn))
            if quiet >= options.quietSeconds, phase != .restarting { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: transcript

    private func openTranscript() {
        guard let url = options.transcriptURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { log("cannot open the transcript file \(url.path)"); return }
        _ = try? h.seekToEnd()
        transcript.withLockUnchecked { $0 = h }
    }

    private func closeTranscript() {
        transcript.withLockUnchecked { h in
            try? h?.synchronize()
            try? h?.close()
            h = nil
        }
    }

    private func appendTranscript(_ ev: OutboundEvent) {
        guard case .turn(let id, let speaker, let text, let addressee, let audioEnd, let kind) = ev else { return }
        let obj: [String: Any] = ["turn_id": id, "speaker": speaker.rawValue, "text": text, "addressee": addressee.rawValue,
                                  "kind": kind.rawValue, "t_audio_end": Text.ms(audioEnd)]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        transcript.withLockUnchecked { h in
            guard let h else { return }
            try? h.write(contentsOf: d + Data("\n".utf8))
            try? h.synchronize()
        }
    }

    // MARK: engine output

    private func isAnswerableQuestion(_ ev: OutboundEvent) -> Bool {
        if case .turn(_, let speaker, _, let who, _, let kind) = ev, speaker != .me, who != .other, kind == .question { return true }
        return false
    }

    private func dispatch(_ timed: [TurnEngine.Timed]) {
        for t in timed {
            let ev = t.event
            if case .turn = ev { appendTranscript(ev) }
            if ev.isForBrain {
                let question = isAnswerableQuestion(ev)
                let target: BrainProcess? = state.withLock { s in
                    switch s.phase {
                    case .running, .starting:
                        if question { s.lastQuestion = (ev, Date()) }
                        return s.brain
                    case .restarting:
                        if question { s.pendingQuestion = ev }
                        return nil
                    case .failed:
                        return nil
                    }
                }
                guard let target else { continue }   // dropped while the brain restarts (the latest question is kept)
                target.send(ev.jsonLine())
                if options.echoOutbound { echoOutbound(ev) } else { emitSinkOnly(.outbound(outboundObject(ev))) }
            } else if case .chip = ev {
                if let d = try? JSONSerialization.jsonObject(with: Data(ev.jsonLine().utf8)) as? [String: Any] { emitJSON(d) }
            }
            if case .turn(let id, let speaker, _, _, let audioEnd, _) = ev, speaker != .me {
                let wall = Date().timeIntervalSince1970
                let wall0 = state.withLock { s -> Double in
                    s.turnsSent += 1
                    s.lastTurnSent = Date()
                    s.turnSentWall[id] = (wall, audioEnd)
                    return s.wall0
                }
                emitJSON(["type": "metric", "turn_id": id, "stage": "turn_sent", "t": Text.ms(wall),
                          "t_audio_end": Text.ms(audioEnd), "t_audio_end_wall": Text.ms(wall0 + audioEnd),
                          "since_audio_end_s": Text.ms(wall - (wall0 + audioEnd)), "source": "verse-run"])
            }
        }
    }

    private func outboundObject(_ ev: OutboundEvent) -> [String: JSONValue] {
        var o = JSONValue.decodeObject(ev.jsonLine()) ?? [:]
        o["dir"] = .string("to_brain")
        return o
    }

    private func echoOutbound(_ ev: OutboundEvent) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(ev.jsonLine().utf8)) as? [String: Any] else { return }
        var o = d
        o["dir"] = "to_brain"
        if options.format == .json || options.sink != nil { emitJSON(o) } else { emit(Self.textLine(o)) }
    }

    // MARK: brain output

    private func handleBrainLine(_ line: String) {
        state.withLock { $0.lastBrainLine = Date() }
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if let obj, obj["type"] as? String == "status", let st = obj["state"] as? String {
            if ["ready", "offline", "error", "credit_exhausted", "rate_limited"].contains(st) { state.withLock { if $0.ready == nil { $0.ready = st } } }
        }
        // The brain's paraphrase hit: the engine has to know, so the turn gets no topic chips.
        if let obj, obj["type"] as? String == "bank_hit", let tid = obj["turn_id"] as? String,
           let engine = state.withLock({ $0.engine }) {
            Task { await engine.noteBrainBankHit(turnID: tid) }
        }
        if options.format == .json || options.sink != nil {
            emit(line, fromBrain: true)
        } else if let obj {
            emit(Self.textLine(obj, lineBuffer: { [state] id, chunk, done in
                state.withLock { s -> String? in
                    let cur = (s.lineBuf[id] ?? "") + chunk
                    if done { s.lineBuf[id] = nil; return cur }
                    s.lineBuf[id] = cur
                    return nil
                }
            }))
        }
        // The headline number: acoustic end of the question -> first S/F text.
        if let obj, obj["type"] as? String == "delta", let tier = obj["tier"] as? String, tier == "S" || tier == "F",
           let tid = obj["turn_id"] as? String {
            let wall = Date().timeIntervalSince1970
            let info: (Double, (wall: Double, audioEnd: Double)?)? = state.withLock { s in
                if s.firstTextDone.contains(tid) { return nil }
                s.firstTextDone.insert(tid)
                return (s.wall0, s.turnSentWall[tid])
            }
            if let (wall0, sent) = info {
                var m: [String: Any] = ["type": "metric", "turn_id": tid, "stage": "first_text", "tier": tier, "t": Text.ms(wall),
                                        "source": "verse-run"]
                if let sent {
                    m["since_audio_end_s"] = Text.ms(wall - (wall0 + sent.audioEnd))
                    m["since_turn_sent_s"] = Text.ms(wall - sent.wall)
                }
                emitJSON(m)
            }
        }
    }
    // MARK: text format

    /// A short human-readable line for an event object; nil buffer callback prints every delta chunk's line on its own.
    static func textLine(_ o: [String: Any], lineBuffer: ((String, String, Bool) -> String?)? = nil) -> String {
        let type = o["type"] as? String ?? "?"
        let tid = o["turn_id"] as? String ?? ""
        func s(_ k: String) -> String { (o[k] as? String) ?? "" }
        func n(_ k: String) -> String { (o[k] as? Double).map { String(format: "%.2f", $0) } ?? "" }
        switch type {
        case "delta":
            let id = s("id")
            let done = (o["line_done"] as? Bool) ?? false
            guard let full = lineBuffer?(id, s("text"), done) else { return "" }
            return "  \(s("tier"))  \(tid)  \(full.trimmingCharacters(in: .whitespaces))"
        case "turn": return "heard \(tid) [\(s("speaker")), for \(s("addressee"))]: \(s("text"))"
        case "partial": return "  ... \(tid): \(s("text"))\((o["cue"] as? Bool) == true ? "  (question cue)" : "")"
        case "bank_hit": return "  bank \(tid): \(s("bank_id")) score \(n("score"))\(s("via").isEmpty ? "" : " (\(s("via")))")"
        case "chip": return "  chip \(tid) [\(s("kind"))]: \(s("text")) (\(s("source_ref")))"
        case "select": return "  select \(tid): \(s("id"))"
        case "opener_status": return "  opener \(tid): \((o["ok"] as? Bool) == true ? "ok" : "WRONG")"
        case "bank_verdict": return "  bank verdict \(tid): \(s("bank_id")) \((o["agree"] as? Bool) == true ? "agreed" : "disagreed")"
        case "status": return "status: \(s("state")) \(s("message"))"
        case "issue": return "ISSUE \(s("code")): \(s("message"))"
        case "metric":
            switch s("stage") {
            case "first_text": return "  >> first \(s("tier")) text \(tid): \(n("since_audio_end_s")) s after the question ended (\(n("since_turn_sent_s")) s after the turn was sent)"
            case "turn_sent": return "  >> turn \(tid) sent \(n("since_audio_end_s")) s after the question ended"
            default: return ""
            }
        default: return ""
        }
    }
}
