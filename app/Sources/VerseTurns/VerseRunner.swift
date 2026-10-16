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
    /// Tests: the permissions, sources and recognizers every listen session of this run is built from (a mid-call route or
    /// language switch builds another one). nil: the real ones.
    public var listenEnvironment: ListenEnvironment?
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
    /// "Follow my answer": the brain gets `follow:true` in `start` and the owner's own partials (speaker `me`). The room route has
    /// no `me` channel, so Swift sends no `me` partials there; the brain tells his words by text (the card's own words) and
    /// feeds them to follow mode itself.
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
    /// `{turn_id, speaker, text, addressee, kind, t_audio_end, lang}` and flushed. Text only, never audio.
    public var transcriptURL: URL?
    /// How long after it was sent a question still counts as "being answered" when the brain crashes (it is re-sent
    /// to the restarted brain).
    public var resendWindowSeconds = 20.0
    /// Interim AUTO language (spec 2.5): `lang` is only where the call starts. A shadow recognizer listens in another language
    /// on the same audio, and when two finals in a row (or 6 s of speech) are judged another language the listen pipeline is
    /// swapped in place to it. Off (the default): the language is the one given, changed only by `switchListening`.
    public var autoLanguage = false
    public var autoConfig = AutoLangConfig()
    /// AUTO runs a shadow recognizer for a candidate language on the same audio. Off (tests): the text of the main recognizer
    /// alone is judged.
    public var autoShadow = true
    /// Seconds a shadow candidate listens before the next one takes over.
    public var shadowSlotSeconds = 12.0
    /// Called after AUTO switched the call to a language (never for a switch asked for with `switchListening`).
    public var onAutoLanguage: (@Sendable (String) -> Void)?

    public static let defaultLiveSeconds = 60.0

    public init(sessionDir: URL) { self.sessionDir = sessionDir }
}

/// The headless end-to-end run: ListenSession -> TurnEngine -> brain child process -> stdout (or `RunOptions.sink`).
///
/// Nothing here writes audio. The brain is killed on every way out: normal end, `requestStop()` (SIGINT/SIGTERM) and errors.
/// Supervision: when the brain exits unexpectedly it is restarted once with the same session; a second crash stops
/// listening and ends the run with `status error`.
public final class VerseRunner: @unchecked Sendable {
    /// What the run loop consumes. Times are the run's own (they continue across a listen swap, see `Leg.offset`); `ended`
    /// names the listen pipeline whose stream finished.
    private enum Input: Sendable {
        case event(TranscriptEvent)
        /// A result of the shadow recognizer (times already moved by the leg's offset).
        case shadow(ShadowResult)
        case tick(TimeInterval, Double?)
        case ended(Int)
    }

    /// One listen pipeline of the run. The first one starts with the run; a route or language switch builds another and the
    /// loop cuts over to it between two events. `offset` is the run time at which the pipeline's own clock started, so audio
    /// and event times (which each session counts from its own `start()`) stay on one timeline for the turn engine and the brain.
    private final class Leg: @unchecked Sendable {
        let gen: Int
        let session: ListenSession
        let offset: TimeInterval
        let route: AudioRoute
        var tasks: [Task<Void, Never>] = []
        init(gen: Int, session: ListenSession, offset: TimeInterval, route: AudioRoute) {
            self.gen = gen
            self.session = session
            self.offset = offset
            self.route = route
        }
        func cancelTasks() { for t in tasks { t.cancel() } }
    }

    /// A switch that is waiting for the old pipeline to finish: the new one is already prepared (models loaded).
    private final class PendingSwap: @unchecked Sendable {
        let next: ListenSession
        let route: AudioRoute
        let lang: String
        let stoppedAtWall: Double
        private let continuation: CheckedContinuation<Bool, Never>
        init(next: ListenSession, route: AudioRoute, lang: String, stoppedAtWall: Double, continuation: CheckedContinuation<Bool, Never>) {
            self.next = next
            self.route = route
            self.lang = lang
            self.stoppedAtWall = stoppedAtWall
            self.continuation = continuation
        }
        func resume(_ ok: Bool) { continuation.resume(returning: ok) }
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
    private let state: OSAllocatedUnfairLock<State>
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
        /// The `lang` each question was sent with, for a re-send to a restarted brain.
        var questionLang: [String: String] = [:]
        var brainFailed = false
        /// The turn engine of the running session, for the brain's paraphrase hits (`noteBrainBankHit`).
        var engine: TurnEngine?
        // listen swap
        /// The route and language the call listens in now (they start as the options and change with `switchListening`).
        var route = AudioRoute.meeting
        var lang = "en"
        /// The first listen pipeline is up and the run loop is consuming (false before and after).
        var listening = false
        var swapping = false
        var pendingSwap: PendingSwap?
        /// `RunOptions.seconds` ran out: the run ends, no switch starts.
        var limitReached = false
        var listenFailed = false
        var swaps = 0
        // interim AUTO language
        var autoLang = false
        /// An automatic switch is under way (the detector already counts the new language as current).
        var autoSwitching = false
        /// How the last automatic switch ended, for the loop to pick up: the language it went to, and whether it was applied.
        var autoOutcome: (lang: String, applied: Bool)?
    }

    private let transcript = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    /// How often a `.level` event is sent to the sink.
    public static let levelPeriodMs = 100

    public init(options: RunOptions, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.options = options
        self.logFn = log
        var initial = State()
        initial.route = options.route
        initial.lang = options.lang
        initial.autoLang = options.autoLanguage
        state = OSAllocatedUnfairLock(initialState: initial)
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
            // The permanent profile's numbers (`me.facts.jsonl`) join the session's own facts for chips and grounding.
            facts = try FactIndex.load(sessionDir: o.sessionDir, meFacts: o.me.map { URL(fileURLWithPath: $0.facts) })
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
        let environment = o.listenEnvironment ?? .system
        let session = ListenSession(config: listenConfig(route: o.route, lang: o.lang, source: source), environment: environment)
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
        let stopEarly = state.withLock { s -> Bool in s.session = session; s.listening = true; return s.stopRequested || s.brainFailed }
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
        var leg = startLeg(Leg(gen: 0, session: session, offset: 0, route: o.route), stream: stream, into: cont)
        var legs: [Leg] = [leg]
        // Interim AUTO language: the detector lives in this loop; the shadow recognizer's results come in as `.shadow` inputs.
        var detector = AutoLanguageDetector(current: o.lang, auto: o.autoLanguage, config: o.autoConfig)
        detector.shadowActive = o.autoLanguage && o.autoShadow
        func shadowConfig(offset: TimeInterval) -> ShadowConfig {
            var c = ShadowConfig(candidates: detector.shadowOrder(), onResult: { r in
                var r = r
                r.start += offset
                r.end += offset
                cont.yield(.shadow(r))
            })
            c.slotSeconds = o.shadowSlotSeconds
            c.log = { [weak self] in self?.log($0) }
            return c
        }
        if o.autoLanguage && o.autoShadow { await session.setShadow(shadowConfig(offset: 0)) }
        let timer = Task { [weak self] in
            var isLive = false
            if case .live = source { isLive = true }
            let limit = o.seconds ?? (isLive ? RunOptions.defaultLiveSeconds : nil)
            guard let limit else { return }
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled else { return }
            self.log("time limit reached")
            let current = self.state.withLock { s -> ListenSession? in s.limitReached = true; return s.session }
            await current?.stop()
        }

        /// The cut-over of a listen swap, run by the loop once the old pipeline's stream has ended (so every result it
        /// still had to deliver has gone through the engine). False: the run is over (stopped, or the new pipeline did not start).
        func cutOver(_ p: PendingSwap) async -> Bool {
            let old = leg
            old.cancelTasks()
            let (route0, lang0) = state.withLock { ($0.route, $0.lang) }
            // 1. What the old pipeline had open is over now: its turns are closed (one final each) before the new recognizer's
            //    first words can be taken for a continuation. Turn numbers go on in the same engine.
            let endOfOld = old.offset + (await old.session.now())
            dispatch(await engine.flush(at: endOfOld))
            // 2. The engine, the run and the brain learn the new route and language. The control lines follow the flushed turns
            //    on the brain's stdin, so the brain sees one continuous stream: old turns, the control, new turns.
            let follow = o.follow && p.route != .room
            await engine.reconfigure(lang: p.lang, roomMode: p.route == .room, roomAuto: p.route == .room ? o.roomAuto : nil,
                                     emitMePartials: follow)
            state.withLock { s in s.route = p.route; s.lang = p.lang }
            if p.route != route0 {
                sendControl(.setRoute(p.route, roomAuto: p.route == .room ? o.roomAuto : nil, follow: o.follow))
            }
            if p.lang != lang0 { sendControl(.setLanguage(p.lang)) }
            // 3. The new pipeline's clock starts now; its times continue where the old one's ended.
            let offset = old.offset + (await old.session.now())
            let next: AsyncStream<TranscriptEvent>
            do {
                next = try await p.next.start()
            } catch {
                log("listen swap failed: \(error)")
                emitSinkOnly(.status(state: "listen_failed", message: "\(error)"))
                state.withLock { $0.listenFailed = true }
                p.resume(false)
                return false
            }
            let startedWall = Date().timeIntervalSince1970
            leg = startLeg(Leg(gen: old.gen + 1, session: p.next, offset: offset, route: p.route), stream: next, into: cont)
            legs.append(leg)
            if detector.auto && o.autoShadow { await p.next.setShadow(shadowConfig(offset: offset)) }
            let ended = state.withLock { s -> Bool in
                s.session = p.next
                s.swaps += 1
                return s.stopRequested || s.limitReached || s.brainFailed
            }
            emitJSON(["type": "metric", "turn_id": "", "stage": "listen_swap", "route": p.route.rawValue, "lang": p.lang,
                      "from_route": route0.rawValue, "from_lang": lang0,
                      "gap_ms": Text.ms((startedWall - p.stoppedAtWall) * 1000), "offset": Text.ms(offset), "source": "verse-run"])
            if ended { await p.next.stop() }
            p.resume(true)
            return true
        }

        var autoPrevSwitch: TimeInterval?
        loop: for await input in inputs {
            switch input {
            case .shadow(let r):
                if r.isFinal {
                    detector.note(LangFinal(channel: r.channel, lang: r.lang, text: r.text, start: r.start, end: r.end,
                                            confidence: r.confidence, shadow: true))
                    if o.trace { log(String(format: "trace shadow %@ t=%.2f-%.2f conf=%@ %@", r.lang, r.start, r.end, r.confidence.map { String(format: "%.2f", $0) } ?? "-", r.text)) }
                }
            case .event(let e):
                if e.isFinal, detector.auto,
                   let hint = detector.note(LangFinal(channel: e.channel, lang: e.lang, text: e.text, start: e.audioStart, end: e.audioEnd,
                                                      confidence: e.confidence)) {
                    await leg.session.preferShadow(hint)
                }
                o.transcriptTap?(e)
                if o.trace { log(String(format: "trace event %@ t=%.2f audio=%.2f-%.2f final=%@ %@", e.channel.rawValue, e.emittedAt, e.audioStart, e.audioEnd, e.isFinal ? "y" : "n", e.text)) }
                dispatch(await engine.ingestTimed(e))
                for d in await engine.takeEchoDrops() {
                    emitJSON(["type": "metric", "turn_id": "", "stage": "echo_guard_dropped", "text": d.text, "is_final": d.isFinal,
                              "audio_start": Text.ms(d.audioStart), "audio_end": Text.ms(d.audioEnd), "similarity": Text.ms(d.similarity),
                              "source": "verse-run"])
                }
            case .tick(let t, let db):
                // Interim AUTO language: follow the pin/auto setting and the language the call is in, then judge what is due.
                let (wantAuto, nowLang, switching, outcome) = state.withLock { s -> (Bool, String, Bool, (lang: String, applied: Bool)?) in
                    let r = (s.autoLang, s.lang, s.autoSwitching, s.autoOutcome)
                    s.autoOutcome = nil
                    return r
                }
                if let outcome, !outcome.applied, detector.current == outcome.lang {
                    detector.revert(to: nowLang, lastSwitchAt: autoPrevSwitch)
                }
                if wantAuto != detector.auto {
                    detector.setAuto(wantAuto)
                    detector.shadowActive = wantAuto && o.autoShadow
                    if o.autoShadow { await leg.session.setShadow(wantAuto ? shadowConfig(offset: leg.offset) : nil) }
                } else if !switching, nowLang != detector.current {
                    detector.setCurrent(nowLang, at: t)           // a chip pinned another language, or a manual switch landed
                    if detector.auto && o.autoShadow { await leg.session.setShadow(shadowConfig(offset: leg.offset)) }
                }
                if detector.auto, !switching {
                    let before = detector.lastSwitchAt
                    if let d = detector.advance(to: t) {
                        autoPrevSwitch = before
                        emitJSON(["type": "metric", "turn_id": "", "stage": "lang_auto", "from": d.from, "to": d.to, "finals": d.finals,
                                  "speech_s": Text.ms(d.seconds), "channel": d.channel.rawValue, "t": Text.ms(t), "source": "verse-run"])
                        state.withLock { $0.autoSwitching = true }
                        Task { [weak self] in
                            guard let self else { return }
                            let ok = await self.switchListening(lang: d.to)
                            self.state.withLock { s in s.autoSwitching = false; s.autoOutcome = (d.to, ok) }
                            if ok { o.onAutoLanguage?(d.to) }
                        }
                    }
                }
                if o.trace, Int(t * 100) % 10 == 0 { log(String(format: "trace level t=%.2f %@", t, db.map { String(format: "%.1f dBFS", $0) } ?? "silent")) }
                dispatch(await engine.noteRemoteLevel(db, at: t))
            case .ended(let gen):
                guard gen == leg.gen else { continue }
                let (swap, over) = state.withLock { s -> (PendingSwap?, Bool) in
                    let p = s.pendingSwap
                    s.pendingSwap = nil
                    return (p, s.stopRequested || s.limitReached || s.brainFailed)
                }
                if let swap {
                    if over { swap.resume(false); break loop }
                    if await cutOver(swap) { continue loop }
                }
                break loop
            }
        }
        state.withLock { $0.listening = false }
        // A switch that was asked for and never happened (the run ended first) gives up; its prepared recognizers are released.
        if let p = state.withLock({ s -> PendingSwap? in let p = s.pendingSwap; s.pendingSwap = nil; return p }) { p.resume(false) }
        timer.cancel()
        for l in legs { l.cancelTasks() }
        let last = leg
        dispatch(await engine.flush(at: last.offset + (await last.session.now())))
        // What the two echo defenses discarded (text and times only), one line each plus a total.
        for l in legs {
            for d in l.session.droppedEchoLog {
                emitJSON(["type": "metric", "turn_id": "", "stage": "echo_gate_dropped", "text": d.text, "is_final": d.isFinal,
                          "audio_start": Text.ms(d.audioStart + l.offset), "audio_end": Text.ms(d.audioEnd + l.offset), "score": Text.ms(d.score), "source": "verse-run"])
            }
        }
        if o.trace {
            for l in legs {
                for d in l.session.gateDecisions {
                    let w = d.features.window
                    var row: [String: Any] = ["type": "metric", "turn_id": "", "stage": "echo_gate_decision", "text": d.text, "is_final": d.isFinal,
                                              "audio_start": Text.ms(d.audioStart + l.offset), "audio_end": Text.ms(d.audioEnd + l.offset), "score": Text.ms(d.features.score),
                                              "lag_ms": Text.ms(d.features.lagMs), "mic_only": Text.ms(w.micOnlyShare), "remote_active": Text.ms(w.remoteActiveShare),
                                              "verdict": d.verdict.rawValue, "source": "verse-run"]
                    if let x = w.ratioDb { row["ratio_db"] = Text.ms(x) }
                    if let x = w.meDb { row["me_db"] = Text.ms(x) }
                    if let x = w.remoteDb { row["remote_db"] = Text.ms(x) }
                    emitJSON(row)
                }
            }
        }
        var summary: [String: Any] = ["type": "metric", "turn_id": "", "stage": "listen_summary",
                                      "echo_gate_dropped": legs.reduce(0) { $0 + $1.session.droppedEchoEvents }, "source": "verse-run"]
        if let r = await last.session.channelOrigin(.remote) { summary["origin_remote"] = Text.ms(r + last.offset) }
        if let m = await last.session.channelOrigin(.me) { summary["origin_me"] = Text.ms(m + last.offset) }
        emitJSON(summary)

        // Let the brain finish what it has started.
        await drain()
        for l in legs { await l.session.stop() }
        await stopBrain()
        return state.withLock { $0.brainFailed || $0.listenFailed } ? 1 : 0
    }

    /// The listen configuration of one pipeline: which route it is (the room route's microphone is the remote channel and has
    /// no `me`; the bleed gate exists only where a second channel does) and which language its recognizers run in.
    private func listenConfig(route: AudioRoute, lang: String, source: ListenConfig.Source) -> ListenConfig {
        let o = options
        let mic: Bool
        switch source {
        case .live: mic = o.micEnabled
        case .file: mic = o.micEnabled && o.micWithFile
        case .memory(let remote, let me): mic = route == .room ? (me ?? remote) != nil : me != nil
        }
        var cfg = ListenConfig(lang: lang, remoteBundleIDs: o.bundleIDs, micEnabled: mic, source: source)
        cfg.micAsRemote = route == .room
        cfg.voiceProcessing = false
        cfg.micWithFile = o.micWithFile
        cfg.bleedGate = o.bleedGate
        return cfg
    }

    /// Starts the tasks that carry one pipeline's output into the run loop: its events (times moved by `offset`), a 10 ms tick
    /// with the remote level, the overlay's level meter and its runtime issues.
    private func startLeg(_ leg: Leg, stream: AsyncStream<TranscriptEvent>, into cont: AsyncStream<Input>.Continuation) -> Leg {
        let session = leg.session, offset = leg.offset, gen = leg.gen
        // The pump ends by itself when the stream does; it is never cancelled, so the last results are delivered.
        Task {
            for await var e in stream {
                e.audioStart += offset
                e.audioEnd += offset
                e.emittedAt += offset
                cont.yield(.event(e))
            }
            cont.yield(.ended(gen))
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let t = await session.now()
                let level = await session.levels(window: 0.1)[.remote]
                cont.yield(.tick(t + offset, level?.rmsDbfs))
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
        leg.tasks = [ticker, issues] + (levelTask.map { [$0] } ?? [])
        return leg
    }

    // MARK: switching the route or the language mid-call

    /// Switches the route and/or the language of the running call without restarting it. Only the audio and recognition side
    /// is rebuilt: the next pipeline is prepared (permissions, sources, recognizers) while the old one keeps listening, then the
    /// old one is stopped and flushed (its pending finals are delivered), the turn engine closes what is open and takes the new
    /// settings, the brain gets `control route` / `control lang`, and the new pipeline starts. The brain process, its transcript,
    /// its cached prefix and its follow state, the turn numbering, the session folder and the end-of-meeting steps are the ones
    /// of the same call. What is missed is the stretch between the old sources stopping and the new ones starting (the
    /// `listen_swap` metric's `gap_ms`).
    ///
    /// Returns false when nothing changed: not listening, a switch in progress, the run stopping, the brain restarting, a file
    /// source (it cannot be resumed), the same route and language, or the new pipeline could not be prepared (the old one then
    /// goes on listening; the failure is an `issue`).
    @discardableResult
    public func switchListening(route newRoute: AudioRoute? = nil, lang newLang: String? = nil) async -> Bool {
        let o = options
        let source: ListenConfig.Source = o.source ?? (o.file.map { .file($0) } ?? .live)
        if case .file = source { return false }
        let plan: (route: AudioRoute, lang: String)? = state.withLock { s in
            guard s.listening, !s.swapping, !s.stopRequested, !s.limitReached, !s.brainFailed, s.phase == .running,
                  s.session != nil else { return nil }
            let route = newRoute ?? s.route, lang = newLang ?? s.lang
            guard route != s.route || lang != s.lang else { return nil }
            s.swapping = true
            return (route, lang)
        }
        guard let plan else { return false }
        defer { state.withLock { $0.swapping = false } }
        log("switch listening to \(plan.route.rawValue) / \(plan.lang)")
        let next = ListenSession(config: listenConfig(route: plan.route, lang: plan.lang, source: source), environment: o.listenEnvironment ?? .system)
        do {
            try await next.prepare()
        } catch {
            log("listen swap not possible: \(error)")
            emitJSON(["type": "issue", "code": "swap_failed", "message": "\(error)"])
            return false
        }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let old: ListenSession? = state.withLock { s in
                guard s.listening, !s.stopRequested, !s.limitReached, !s.brainFailed, let cur = s.session else { return nil }
                s.pendingSwap = PendingSwap(next: next, route: plan.route, lang: plan.lang,
                                            stoppedAtWall: Date().timeIntervalSince1970, continuation: c)
                return cur
            }
            guard let old else { c.resume(returning: false); return }
            // Stopping the old pipeline ends its stream after the last results; the loop sees that and cuts over.
            Task { await old.stop() }
        }
        if !ok { await next.discardPrepared() }
        return ok
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
    ///
    /// The route and language are the call's current ones, not the options': a brain restarted after a crash in a call that was
    /// switched must start in the route the call is in now.
    func startCommand() -> BrainCommand {
        let (route, lang) = state.withLock { ($0.route, $0.lang) }
        let room = route == .room
        return .start(sessionDir: options.sessionDir.path, lang: lang, follow: options.follow,
                      mode: options.mode == .prepared ? nil : options.mode, route: route == .meeting ? nil : route,
                      me: options.me, roomAuto: room ? options.roomAuto : nil)
    }

    /// ⌥⌘↩: the brain answers the latest remote/room turn now (the open partial, else the last final). Nothing happens
    /// when no brain is running.
    public func cardNow() { sendControl(.cardNow) }

    /// Turns the interim AUTO language mode on or off while the call runs. Off pins the current language (the controller pins
    /// the one a chip names with `switchListening` right after).
    public func setAutoLanguage(_ on: Bool) { state.withLock { $0.autoLang = on } }

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
            let lang = state.withLock { $0.questionLang[resend.turnID] }
            b.send(resend.jsonLine(lang: lang))
            state.withLock { s in s.lastQuestion = (resend, Date()); s.lastTurnSent = Date() }
            if options.echoOutbound { echoOutbound(resend, lang: lang) } else { emitSinkOnly(.outbound(outboundObject(resend, lang: lang))) }
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

    private func appendTranscript(_ ev: OutboundEvent, lang: String? = nil) {
        guard case .turn(let id, let speaker, let text, let addressee, let audioEnd, let kind) = ev else { return }
        var obj: [String: Any] = ["turn_id": id, "speaker": speaker.rawValue, "text": text, "addressee": addressee.rawValue,
                                  "kind": kind.rawValue, "t_audio_end": Text.ms(audioEnd)]
        if let lang { obj["lang"] = lang }
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
            if case .turn = ev { appendTranscript(ev, lang: t.lang) }
            if ev.isForBrain {
                let question = isAnswerableQuestion(ev)
                let target: BrainProcess? = state.withLock { s in
                    switch s.phase {
                    case .running, .starting:
                        if question { s.lastQuestion = (ev, Date()); s.questionLang[ev.turnID] = t.lang }
                        return s.brain
                    case .restarting:
                        if question { s.pendingQuestion = ev; s.questionLang[ev.turnID] = t.lang }
                        return nil
                    case .failed:
                        return nil
                    }
                }
                guard let target else { continue }   // dropped while the brain restarts (the latest question is kept)
                target.send(ev.jsonLine(lang: t.lang, cue: t.cue))
                if options.echoOutbound { echoOutbound(ev, lang: t.lang, cue: t.cue) } else { emitSinkOnly(.outbound(outboundObject(ev, lang: t.lang, cue: t.cue))) }
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

    private func outboundObject(_ ev: OutboundEvent, lang: String? = nil, cue: CueMatch? = nil) -> [String: JSONValue] {
        var o = JSONValue.decodeObject(ev.jsonLine(lang: lang, cue: cue)) ?? [:]
        o["dir"] = .string("to_brain")
        return o
    }

    private func echoOutbound(_ ev: OutboundEvent, lang: String? = nil, cue: CueMatch? = nil) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(ev.jsonLine(lang: lang, cue: cue).utf8)) as? [String: Any] else { return }
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
