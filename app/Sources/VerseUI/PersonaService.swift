import Combine
import Foundation
import VerseAudio
import VerseTurns

// The master persona, app side (owner decisions 1 and 4, 24 Nov 2026). After a call stops and the memory sync after it has
// finished, the brain learns from what he said in that call (`persona_start`, brain/verse_brain/persona/runtime.py): one child
// process per session, one at a time, never while a call runs or stops. A call that starts kills the child; the brain holds a
// stop back while it writes, so nothing is left half-written, and the session is learned after the next call instead.
// This file decides *when* and *what*, moves the one start line and the one answer, and keeps the last result and the open
// contradictions for the Me page. Nothing here reads or logs transcript text: names, counts, kinds and timings only.

// MARK: - Gate

/// Whether a session may be learned from now (pure; the table tests drive it).
enum PersonaGate {
    enum Trigger: Sendable, Equatable {
        /// After a call: needs the "Learn from my calls" toggle, and never a test run.
        case automatic
        /// "Learn from this call" on a session: works with the toggle off.
        case manual
    }

    enum Skip: String, Sendable, Equatable {
        /// "Learn from my calls" is off (automatic runs only).
        case toggleOff
        /// No `persona_dir` in the owner profile.
        case notConfigured
        /// A practice run (`sim-*`).
        case practice
        /// `general-core` or `persona-core`.
        case standingPrep
        /// A run with the canned brain or a test audio file (automatic runs only).
        case testRun
        /// The folder has no transcript.
        case noTranscript
        /// No row of his: nothing he said to learn from.
        case noOwnerSpeech
    }

    enum Decision: Sendable, Equatable {
        case run
        /// A call is running or stopping: later.
        case wait
        case skip(Skip)
    }

    struct Facts: Sendable, Equatable {
        var session: String
        var toggleOn = true
        var configured = true
        /// `controller.running || controller.stopping`.
        var callActive = false
        var isTestRun = false
        var hasTranscript = true
        var hasOwnerSpeech = true
    }

    static func decide(_ f: Facts, trigger: Trigger) -> Decision {
        if !f.configured { return .skip(.notConfigured) }
        if trigger == .automatic && !f.toggleOn { return .skip(.toggleOff) }
        if GeneralPrep.isGeneral(f.session) { return .skip(.standingPrep) }
        if f.session.hasPrefix("sim-") { return .skip(.practice) }
        if trigger == .automatic && f.isTestRun { return .skip(.testRun) }
        if f.callActive { return .wait }
        if !f.hasTranscript { return .skip(.noTranscript) }
        if !f.hasOwnerSpeech { return .skip(.noOwnerSpeech) }
        return .run
    }

    /// True when the session holds something he said: a `me` row in `transcript.jsonl`, or a room text the brain gave to him
    /// (`room_text` with label `me` or `split` in `events.jsonl`). Reads only the speaker and label fields.
    static func hasOwnerSpeech(sessionDir: URL) -> Bool {
        func lines(_ f: String) -> [Substring] {
            ((try? String(contentsOf: sessionDir.appendingPathComponent(f), encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
        }
        func object(_ l: Substring) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] }
        for l in lines("transcript.jsonl") where l.contains("\"me\"") {
            if let o = object(l), o["speaker"] as? String == "me", !((o["text"] as? String) ?? "").isEmpty { return true }
        }
        for l in lines("events.jsonl") where l.contains("room_text") {
            if let o = object(l), o["ev"] as? String == "room_text", ["me", "split"].contains(o["label"] as? String ?? "") { return true }
        }
        return false
    }
}

// MARK: - Records

/// One side of an open contradiction: what was said, verbatim, and where.
struct PersonaSide: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var quote: String
    var date: String
    /// `<skey> <m:ss>` of the call, or the origin of a seed entry.
    var ref: String
}

/// An open contradiction of the persona (both claims kept; neither reaches a call until he settles it).
struct PersonaContradiction: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var topic: String
    var first: PersonaSide
    var second: PersonaSide
}

/// The last update's outcome, as the Me page and the session detail show it.
struct PersonaRunRecord: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case updated
        case nothingNew = "nothing_new"
        case failed
    }

    var session: String
    var at: Date
    var state: State
    var added = 0
    var repeats = 0
    var contradictions = 0
    var costUSD = 0.0
    /// The brain's error kind (`offline`, `credit_exhausted`, ...) for a failure.
    var kind: String?

    /// "Updated from <session> · 3 new" / "Nothing new in <session>" / "Could not learn from <session>: <reason>".
    func text(title: String) -> String {
        switch state {
        case .updated:
            var s = L10n.tr("Updated from \(title)")
            if added > 0 { s += " · " + L10n.tr("\(added) new") }
            if repeats > 0 { s += " · " + L10n.tr("\(repeats) said again") }
            if contradictions > 0 { s += " · " + L10n.tr("\(contradictions) contradictions") }
            return s
        case .nothingNew:
            return L10n.tr("Nothing new in \(title)")
        case .failed:
            return L10n.tr("Could not learn from \(title): \(PersonaRunRecord.reason(kind ?? "error"))")
        }
    }

    /// A short reason for a failure kind (runtime/protocol.py PERSONA_ERROR_KINDS).
    static func reason(_ kind: String) -> String {
        switch kind {
        case "credit_exhausted": L10n.tr("your Anthropic credit has run out.")
        case "offline": L10n.tr("no internet connection.")
        case "rate_limited", "overloaded": L10n.tr("the model was busy.")
        case "auth": L10n.tr("the API key is missing or was rejected.")
        case "busy": L10n.tr("another persona update was running.")
        case "guard", "off": L10n.tr("the persona folder is not one Verse can write.")
        case "budget": L10n.tr("the call is too long for the budget.")
        default: L10n.tr("the answer could not be used; nothing was changed.")
        }
    }
}

/// What the brain says (persona/runtime.py). Unknown types and lines that are not JSON are ignored.
enum PersonaEvent: Equatable, Sendable {
    struct Done: Equatable, Sendable {
        var action: String
        var skipped: String?
        var kept = 0
        var added = 0
        var repeats = 0
        var contradictions = 0
        var costUSD = 0.0
        var compiled = false
        var open: [PersonaContradiction] = []
    }

    case status(state: String)
    case done(Done)
    case error(kind: String)

    static func parse(_ line: String) -> PersonaEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = o["type"] as? String else { return nil }
        func str(_ d: [String: Any]?, _ k: String) -> String { (d?[k] as? String) ?? "" }
        func int(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        func count(_ k: String) -> Int { (o[k] as? [Any])?.count ?? 0 }
        func side(_ d: [String: Any]?) -> PersonaSide {
            PersonaSide(id: str(d, "id"), text: str(d, "text"), quote: str(d, "quote"), date: str(d, "date"), ref: str(d, "ref"))
        }
        switch type {
        case "status":
            return .status(state: str(o, "state"))
        case "persona_done":
            let open = ((o["open"] as? [[String: Any]]) ?? []).map {
                PersonaContradiction(id: str($0, "id"), topic: str($0, "topic"), first: side($0["a"] as? [String: Any]),
                                     second: side($0["b"] as? [String: Any]))
            }
            return .done(Done(action: str(o, "action"), skipped: o["skipped"] as? String, kept: int("kept"), added: count("new"),
                              repeats: int("repeats"), contradictions: count("contradictions"),
                              costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue ?? 0, compiled: o["compiled"] is [String: Any], open: open))
        case "persona_error":
            let kind = str(o, "kind")
            return .error(kind: kind.isEmpty ? "error" : kind)
        default:
            return nil
        }
    }
}

// MARK: - Paths

/// Where the persona's app-side files live. `profile` is `~/Library/Application Support/Verse/profile`; tests pass a scratch one.
struct PersonaPaths: Sendable, Equatable {
    var profile: URL
    var sessionsRoot: URL

    static var live: PersonaPaths { PersonaPaths(profile: MeProfilePaths.defaultDirectory, sessionsRoot: SessionCatalog.root) }

    /// The brain's machine state (it writes it; the app only names it).
    var state: URL { profile.appendingPathComponent("persona.meta.json") }
    /// The app's own record: the last result, the open contradictions, the sessions still to learn from.
    var appState: URL { profile.appendingPathComponent("persona.app.json") }
    var meCore: URL { profile.appendingPathComponent("me.md") }
    var meNotes: URL { profile.appendingPathComponent("me.notes.md") }
}

// MARK: - Service

/// Runs the persona's updates and keeps their result. One per app; `HomeContext` builds it.
@MainActor
final class PersonaService: ObservableObject {
    /// A session waiting to be learned from.
    struct Pending: Codable, Sendable, Equatable {
        var session: String
        var manual = false
        var isTest = false
    }

    struct AppState: Codable, Sendable, Equatable {
        var last: PersonaRunRecord?
        var open: [PersonaContradiction] = []
        var pending: [Pending] = []
    }

    /// The session being learned from now, or nil.
    @Published private(set) var active: String?
    @Published private(set) var last: PersonaRunRecord?
    @Published private(set) var open: [PersonaContradiction] = []
    @Published private(set) var pending: [Pending] = []
    /// A contradiction being settled, or nil.
    @Published private(set) var resolving: String?
    /// Why the last settle failed (an error kind), cleared by the next one.
    @Published private(set) var resolveError: String?

    let paths: PersonaPaths
    /// A service that is not enabled never starts a process (tests and renders that build a `HomeContext`).
    let enabled: Bool

    // What the app tells it; injectable for tests.
    var toggleOn: () -> Bool = { true }
    var configured: () -> Bool = { OwnerProfile.current.personaURL != nil }
    var callActive: () -> Bool = { false }
    var ownerName: () -> String = { "" }
    /// How long the brain may stay silent (the model request is the long part).
    var stall: Duration = .seconds(900)

    /// `local` is true for the actions that never call the model (status, resolve): the real brain starts them with `--no-api`.
    private let makeBrain: (_ local: Bool) throws -> any SimBrainTransport
    private var brain: (any SimBrainTransport)?
    /// An action was scheduled and has not ended (set before its process starts, so a call start in between still stops it).
    private var inFlight = false
    private var killed = false
    private var runningWatch: AnyCancellable?
    /// How many update processes were started (tests).
    private(set) var startCount = 0

    init(paths: PersonaPaths = .live, enabled: Bool = true, makeBrain: @escaping (_ local: Bool) throws -> any SimBrainTransport) {
        self.paths = paths
        self.enabled = enabled
        self.makeBrain = makeBrain
        let saved = Self.load(paths.appState)
        last = saved.last
        open = saved.open
        pending = saved.pending
    }

    nonisolated static func brainArguments(fake: Bool, local: Bool) -> [String] { (fake ? ["--fake"] : []) + (local ? ["--no-api"] : []) }

    /// The real brain: `python -u -m verse_brain.runtime`, logs to `verse.log`.
    static func makeBrainProcess(fake: Bool, local: Bool) throws -> any SimBrainTransport {
        guard let dir = VerseController.brainDir() else { throw BrainError.brainDirNotFound("set VERSE_BRAIN_DIR") }
        let b = try BrainProcess(brainDir: dir, extraArgs: brainArguments(fake: fake, local: local),
                                 onStderr: { FileLog.shared.write("[persona brain] " + $0) })
        try b.start()
        return b
    }

    // MARK: triggers

    /// Watches the call: a start kills a running update; a run that ended queues its session. The memory service calls
    /// `syncFinished` when its sync after the call is done.
    func attach(controller: VerseController, memory: MemoryService) {
        guard enabled else { return }
        callActive = { [weak controller] in (controller?.running ?? false) || (controller?.stopping ?? false) }
        runningWatch = controller.$running.removeDuplicates().sink { [weak self] now in
            if now { MainActor.assumeIsolated { self?.callStarted() } }
        }
        controller.onRunFinished = { [weak self] run in self?.runEnded(run) }
        memory.onSyncFinished = { [weak self] afterCall in self?.syncFinished(afterCall: afterCall) }
    }

    /// A run ended: its session waits for the memory sync after it.
    func runEnded(_ run: FinishedRun) {
        guard enabled else { return }
        let f = facts(run.sessionName, isTest: run.isTest)
        if case .skip(let why) = PersonaGate.decide(f, trigger: .automatic) {
            FileLog.shared.write("persona: \(run.sessionName) not queued (\(why.rawValue))")
            return
        }
        enqueue(Pending(session: run.sessionName, isTest: run.isTest), front: false)
    }

    /// The memory sync finished. After a call (or at launch) the queued sessions start, one at a time.
    func syncFinished(afterCall: Bool) {
        guard enabled, afterCall else { return }
        drain()
    }

    /// A call started: an update in flight is killed and its session goes back to the front of the queue.
    func callStarted() {
        guard inFlight else { return }
        killed = true
        if let name = active {
            FileLog.shared.write("persona: \(name) stopped for a call; it runs after the call")
            enqueue(Pending(session: name), front: true)
        } else {
            FileLog.shared.write("persona: a settle or status read stopped for a call")
        }
        // A process not started yet sees `killed` and closes at once (perform).
        if let b = brain { Task { await b.close() } }
    }

    /// "Learn from this call": starts at once when nothing else runs (the toggle does not apply). Returns why it cannot run,
    /// or nil when it started or was queued behind a running update or call.
    @discardableResult
    func learn(session: String) -> PersonaGate.Skip? {
        guard enabled else { return .notConfigured }
        if case .skip(let why) = PersonaGate.decide(facts(session, isTest: false), trigger: .manual) { return why }
        pending.removeAll { $0.session == session }
        enqueue(Pending(session: session, manual: true), front: true)
        drain()
        return nil
    }

    /// Whether "Learn from this call" can be offered for a session now.
    func canLearn(session: String) -> Bool {
        guard enabled, !inFlight, !callActive() else { return false }
        return PersonaGate.decide(facts(session, isTest: false), trigger: .manual) == .run
    }

    func facts(_ session: String, isTest: Bool) -> PersonaGate.Facts {
        let dir = SessionCatalog.url(session, root: paths.sessionsRoot)
        let hasTranscript = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.jsonl").path)
        return PersonaGate.Facts(session: session, toggleOn: toggleOn(), configured: configured(), callActive: callActive(),
                                 isTestRun: isTest, hasTranscript: hasTranscript,
                                 hasOwnerSpeech: hasTranscript && PersonaGate.hasOwnerSpeech(sessionDir: dir))
    }

    private func enqueue(_ p: Pending, front: Bool) {
        pending.removeAll { $0.session == p.session }
        if front { pending.insert(p, at: 0) } else { pending.append(p) }
        save()
    }

    /// Starts the next queued session that may run now. Re-checks the gate: the toggle may have changed since it was queued.
    func drain() {
        guard enabled, !inFlight else { return }
        while let next = pending.first {
            let decision = PersonaGate.decide(facts(next.session, isTest: next.isTest), trigger: next.manual ? .manual : .automatic)
            switch decision {
            case .wait:
                return
            case .skip(let why):
                FileLog.shared.write("persona: \(next.session) skipped (\(why.rawValue))")
                pending.removeFirst()
                save()
            case .run:
                pending.removeFirst()
                save()
                active = next.session          // at once: nothing else may start before the update's process does
                inFlight = true
                killed = false
                Task { @MainActor [weak self] in await self?.update(next.session) }
                return
            }
        }
    }

    // MARK: processes

    func startLine(action: String, session: String?, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = [
            "type": "persona_start", "action": action, "sessions_root": paths.sessionsRoot.path, "state": paths.state.path,
            "me": ["core": paths.meCore.path, "notes": paths.meNotes.path], "seed_from_general": true,
        ]
        if let session { o["session_dir"] = SessionCatalog.url(session, root: paths.sessionsRoot).path }
        let owner = ownerName().trimmingCharacters(in: .whitespaces)
        if !owner.isEmpty { o["owner_name"] = owner }
        for (k, v) in extra { o[k] = v }
        return AskWire.line(o)
    }

    /// One process, one action: returns its answer, or nil when it ended without one (killed, stalled, crashed).
    private func perform(_ line: String, local: Bool) async -> PersonaEvent? {
        let b: any SimBrainTransport
        do { b = try makeBrain(local) } catch {
            FileLog.shared.write("persona: could not start the brain")
            return .error(kind: "error")
        }
        brain = b
        defer { brain = nil }
        if killed {                      // a call started while the process was starting
            await b.close()
            return nil
        }
        b.send(line)
        let dog = StallWatchdog(limit: stall) { await b.close() }
        var result: PersonaEvent?
        for await l in b.lines {
            dog.poke()
            guard let event = PersonaEvent.parse(l) else { continue }
            if case .status = event { continue }
            result = event
            break
        }
        dog.stop()
        await b.close()
        if result == nil && dog.fired { return .error(kind: "error") }
        return result
    }

    private func update(_ session: String) async {
        active = session
        startCount += 1
        let started = Date()
        let clock = ContinuousClock.now
        let result = await perform(startLine(action: "update", session: session), local: false)
        active = nil
        inFlight = false
        let ms = Int((ContinuousClock.now - clock) / .milliseconds(1))
        if killed {
            // Stopped for a call: already back in the queue. Not a failure.
            killed = false
            return
        }
        // Whole seconds: what the saved file keeps (ISO 8601), so a reload compares equal.
        var record = PersonaRunRecord(session: session, at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), state: .failed)
        switch result {
        case .done(let d)?:
            record.state = d.added + d.repeats + d.contradictions > 0 ? .updated : .nothingNew
            record.added = d.added
            record.repeats = d.repeats
            record.contradictions = d.contradictions
            record.costUSD = d.costUSD
            open = d.open
            if d.costUSD > 0 { recordSpend(session: session, startedAt: started, cost: d.costUSD) }
            FileLog.shared.write("persona: \(session) \(record.state.rawValue) new=\(d.added) repeats=\(d.repeats) contradictions=\(d.contradictions) skipped=\(d.skipped ?? "-") ms=\(ms)")
        case .error(let kind)?:
            if kind == "excluded" || kind == "no_session" {
                record.state = .nothingNew
            } else {
                record.kind = kind
            }
            FileLog.shared.write("persona: \(session) failed kind=\(kind) ms=\(ms)")
        default:
            record.kind = "error"
            FileLog.shared.write("persona: \(session) ended without an answer ms=\(ms)")
        }
        last = record
        save()
        drain()
    }

    /// Reads the open contradictions again (the owner may have settled one in the note). Never during a call or an update.
    func refreshStatus() {
        guard enabled, configured(), !inFlight, !callActive() else { return }
        inFlight = true
        killed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.killed = false; self.inFlight = false; self.drain() }
            if case .done(let d)? = await self.perform(self.startLine(action: "status", session: nil, extra: ["seed_from_general": false]), local: true) {
                self.open = d.open
                self.save()
            }
        }
    }

    /// Settles an open contradiction: `keep` 1 keeps the first claim, 2 the second. The other one stays as history.
    func resolve(_ id: String, keep: Int) {
        guard enabled, configured(), !inFlight, !callActive(), keep == 1 || keep == 2 else { return }
        resolving = id
        resolveError = nil
        inFlight = true
        killed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await self.perform(self.startLine(action: "resolve", session: nil, extra: ["id": id, "keep": String(keep)]), local: true)
            self.killed = false
            switch r {
            case .done(let d)?:
                self.open = d.open
                FileLog.shared.write("persona: settled \(id) open=\(d.open.count)")
            case .error(let kind)?:
                self.resolveError = kind
                FileLog.shared.write("persona: settle \(id) failed kind=\(kind)")
            default:
                self.resolveError = self.killed ? nil : "error"     // stopped for a call: not a failure, still open
            }
            self.killed = false
            self.resolving = nil
            self.inFlight = false
            self.save()
            self.drain()
        }
    }

    // MARK: files

    /// The update is a run of kind `persona` in the session's `spend.json`, so the month's spend counts it.
    private func recordSpend(session: String, startedAt: Date, cost: Double) {
        let dir = SessionCatalog.url(session, root: paths.sessionsRoot)
        var start = startedAt
        let taken = Set(SpendLedger.runs(sessionDir: dir).filter { $0.kind == "persona" }.map { $0.startedAt.timeIntervalSince1970.rounded(.down) })
        while taken.contains(start.timeIntervalSince1970.rounded(.down)) { start = start.addingTimeInterval(1) }
        SpendLedger.record(sessionDir: dir, startedAt: start, costUSD: cost, kind: "persona")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(_ url: URL) -> AppState {
        guard let d = try? Data(contentsOf: url), let s = try? decoder.decode(AppState.self, from: d) else { return AppState() }
        return s
    }

    private func save() {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: paths.profile, withIntermediateDirectories: true)
        if let d = try? Self.encoder.encode(AppState(last: last, open: open, pending: pending)) {
            try? d.write(to: paths.appState, options: .atomic)
        }
    }
}
