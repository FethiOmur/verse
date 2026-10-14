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

public struct RunOptions: Sendable {
    public var sessionDir: URL
    public var lang = "en"
    /// Stop listening after this long. nil: a file plays to its end; live listens for `defaultLiveSeconds`.
    public var seconds: Double?
    public var file: URL?
    public var micEnabled = true
    public var bundleIDs = defaultRemoteBundleIDs
    public var brainDir: URL?
    /// Brain with canned replies (`--fake`): no network, no key. For tests of the plumbing.
    public var fakeBrain = false
    public var budgetUSD: Double?
    public var turn = TurnConfig()
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

    public static let defaultLiveSeconds = 60.0

    public init(sessionDir: URL) { self.sessionDir = sessionDir }
}

/// The headless end-to-end run: ListenSession -> TurnEngine -> brain child process -> stdout.
///
/// Nothing here writes audio. The brain is killed on every way out: normal end, `requestStop()` (SIGINT/SIGTERM) and errors.
public final class VerseRunner: @unchecked Sendable {
    private enum Input: Sendable {
        case event(TranscriptEvent)
        case tick(TimeInterval, Double?)
        case ended
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
    }

    public init(options: RunOptions, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.options = options
        self.logFn = log
    }

    /// Ends listening early (SIGINT). The run still shuts the brain down.
    public func requestStop() {
        let session = state.withLock { s -> ListenSession? in s.stopRequested = true; return s.session }
        if let session { Task { await session.stop() } }
    }

    // MARK: output

    private func emit(_ line: String) {
        if line.isEmpty { return }
        outLock.withLockUnchecked {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    private func emitJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let s = String(decoding: d, as: UTF8.self)
        if options.format == .json { emit(s) } else { emit(Self.textLine(obj)) }
    }

    private func log(_ s: String) { logFn(s) }

    // MARK: run

    /// Runs to the end. Exit code: 0 ok, 1 failure, 3 permission denied.
    public func run() async -> Int32 {
        let o = options
        guard FileManager.default.fileExists(atPath: o.sessionDir.appendingPathComponent("pack.md").path) else {
            log("session folder has no pack.md: \(o.sessionDir.path)")
            return 2
        }
        var turnCfg = o.turn
        turnCfg.lang = o.lang
        let bank: Bank, facts: FactIndex
        do {
            bank = try Bank.load(sessionDir: o.sessionDir)
            facts = try FactIndex.load(sessionDir: o.sessionDir)
        } catch {
            log("cannot read the session folder: \(error)")
            return 2
        }
        let engine = TurnEngine(config: turnCfg, bank: bank, facts: facts)

        // The brain first: its pre-warm must be done before the first question is heard.
        let brain: BrainProcess
        do {
            let dir = try BrainProcess.locateBrainDir(explicit: o.brainDir)
            var args: [String] = []
            if o.fakeBrain { args.append("--fake") }
            if let b = o.budgetUSD { args += ["--budget-usd", String(b)] }
            brain = try BrainProcess(brainDir: dir, extraArgs: args, onStderr: { [logFn] l in logFn("[brain] " + l) })
            try brain.start()
        } catch {
            log("\(error)")
            return 1
        }
        let reader = Task { [weak self] in
            for await line in brain.lines { self?.handleBrainLine(line) }
            if let self, !self.state.withLock({ $0.shuttingDown }) {
                self.log("the brain process ended unexpectedly")
                self.emitJSON(["type": "status", "state": "error", "message": "brain process ended unexpectedly"])
            }
        }
        defer { reader.cancel() }
        func stopBrain() async {
            state.withLock { $0.shuttingDown = true }
            await brain.shutdown()
            await reader.value
        }

        brain.send(BrainCommand.start(sessionDir: o.sessionDir.path, lang: o.lang).jsonLine())
        let readyState = await waitReady(timeout: o.readyTimeout, brain: brain)
        if readyState == nil || readyState == "error" || readyState == "credit_exhausted" {
            log("brain did not become ready (\(readyState ?? "timeout")); stopping")
            await stopBrain()
            return 1
        }

        // Listening.
        var cfg = ListenConfig(lang: o.lang, remoteBundleIDs: o.bundleIDs, micEnabled: o.file == nil ? o.micEnabled : false,
                               source: o.file.map { .file($0) } ?? .live)
        cfg.voiceProcessing = false
        let session = ListenSession(config: cfg)
        let stream: AsyncStream<TranscriptEvent>
        do {
            stream = try await session.start()
        } catch let e as ListenError {
            log("listen failed: \(e.description)")
            await stopBrain()
            return e.code == "permission_denied" ? 3 : 1
        } catch {
            log("listen failed: \(error)")
            await stopBrain()
            return 1
        }
        let stopEarly = state.withLock { s -> Bool in s.session = session; return s.stopRequested }
        let now0 = await session.now()
        let origin = await session.channelOrigin(.remote) ?? 0
        let wall0 = Date().timeIntervalSince1970 - now0
        state.withLock { $0.wall0 = wall0 }
        emitJSON(["type": "metric", "turn_id": "", "stage": "session_t0", "t": Text.ms(wall0), "origin_remote": Text.ms(origin),
                  "source": "verse-run", "lang": o.lang, "fake_brain": o.fakeBrain, "brain_pid": Int(brain.pid)])
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
        let issues = Task { [weak self] in
            for await issue in session.issues {
                self?.emitJSON(["type": "issue", "code": issue.code, "message": issue.description])
            }
        }
        let timer = Task { [weak self] in
            let limit = o.seconds ?? (o.file == nil ? RunOptions.defaultLiveSeconds : nil)
            guard let limit else { return }
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { self?.log("time limit reached"); await session.stop() }
        }

        loop: for await input in inputs {
            switch input {
            case .event(let e):
                if o.trace { log(String(format: "trace event %@ t=%.2f audio=%.2f-%.2f final=%@ %@", e.channel.rawValue, e.emittedAt, e.audioStart, e.audioEnd, e.isFinal ? "y" : "n", e.text)) }
                dispatch(await engine.ingestTimed(e), brain: brain)
            case .tick(let t, let db):
                if o.trace, Int(t * 100) % 10 == 0 { log(String(format: "trace level t=%.2f %@", t, db.map { String(format: "%.1f dBFS", $0) } ?? "silent")) }
                dispatch(await engine.noteRemoteLevel(db, at: t), brain: brain)
            case .ended:
                break loop
            }
        }
        ticker.cancel()
        timer.cancel()
        pump.cancel()
        dispatch(await engine.flush(at: await session.now()), brain: brain)

        // Let the brain finish what it has started.
        await drain(brain: brain)
        await session.stop()
        issues.cancel()
        await stopBrain()
        return 0
    }

    private func waitReady(timeout: TimeInterval, brain: BrainProcess) async -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = state.withLock({ $0.ready }) { return r }
            if !brain.isRunning { return "error" }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func drain(brain: BrainProcess) async {
        let (stop, turns) = state.withLock { ($0.stopRequested, $0.turnsSent) }
        guard !stop, turns > 0 else { return }
        let end = Date().addingTimeInterval(options.drainSeconds)
        while Date() < end, brain.isRunning, !state.withLock({ $0.stopRequested }) {
            let (lastLine, lastTurn) = state.withLock { ($0.lastBrainLine, $0.lastTurnSent ?? .distantPast) }
            let quiet = Date().timeIntervalSince(max(lastLine, lastTurn))
            if quiet >= options.quietSeconds { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: engine output

    private func dispatch(_ timed: [TurnEngine.Timed], brain: BrainProcess) {
        for t in timed {
            let ev = t.event
            if ev.isForBrain {
                brain.send(ev.jsonLine())
                if options.echoOutbound { echoOutbound(ev) }
            } else if case .chip = ev {
                if let d = try? JSONSerialization.jsonObject(with: Data(ev.jsonLine().utf8)) as? [String: Any] { emitJSON(d) }
            }
            if case .turn(let id, let speaker, _, _, let audioEnd, _) = ev, speaker == .remote {
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

    private func echoOutbound(_ ev: OutboundEvent) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(ev.jsonLine().utf8)) as? [String: Any] else { return }
        var o = d
        o["dir"] = "to_brain"
        if options.format == .json { emitJSON(o) } else { emit(Self.textLine(o)) }
    }

    // MARK: brain output

    private func handleBrainLine(_ line: String) {
        state.withLock { $0.lastBrainLine = Date() }
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if let obj, obj["type"] as? String == "status", let st = obj["state"] as? String {
            if ["ready", "offline", "error", "credit_exhausted", "rate_limited"].contains(st) { state.withLock { $0.ready = st } }
        }
        if options.format == .json {
            emit(line)
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
        case "bank_hit": return "  bank \(tid): \(s("bank_id")) score \(n("score"))"
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
