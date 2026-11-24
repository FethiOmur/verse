import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

// The master persona, app side: when an update runs (after Stop and the memory sync, never during a call, killed when a call
// starts, skipped kinds, the toggle), what it records, and which standing prep an unprepared call is seeded from. Fictional
// sessions in temp folders; the brain is an in-process stand-in. Nothing here reads the owner's profile or sessions.

/// Stand-in for the persona process: answers `persona_start` with a canned line, or holds until closed.
final class ScriptedPersonaBrain: SimBrainTransport, @unchecked Sendable {
    enum Mode: Sendable {
        case done(String)
        case error(String)
        case hold
    }

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private let mode: Mode

    init(_ mode: Mode) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.mode = mode
    }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    func close() async { lock.withLock { _closed = true }; continuation.finish() }

    func send(_ line: String) {
        lock.withLock { _sent.append(line) }
        guard MemoryFixtures.object(line)["type"] as? String == "persona_start" else { return }
        continuation.yield(#"{"type":"status","state":"warming","message":"reading the persona"}"#)
        switch mode {
        case .done(let l): continuation.yield(l); continuation.finish()
        case .error(let kind): continuation.yield(#"{"type":"persona_error","kind":"\#(kind)","message":"fixture"}"#); continuation.finish()
        case .hold: break
        }
    }
}

@MainActor
final class PersonaTests: XCTestCase {
    static let done = #"""
    {"type":"persona_done","action":"update","session":"x","skipped":null,"kept":3,"dropped":{},"new":["p001","p002"],"repeats":1,
     "contradictions":["c001"],"open_contradictions":1,"cost_usd":0.12,"usage":{},"compiled":{"out":"/x/persona-core","bank":2},
     "compile_error":null,"imported":null,"ms_total":900,
     "open":[{"id":"c001","topic":"salary expectation","a":{"id":"p001","text":"Around 95,000.","quote":"around 95,000 euros","date":"2026-10-01","ref":"k1a2 0:47"},
              "b":{"id":"p004","text":"Around 110,000.","quote":"around 110,000 euros","date":"2026-10-08","ref":"k3b4 0:15"}}]}
    """#.replacingOccurrences(of: "\n", with: "")
    static let nothing = #"{"type":"persona_done","action":"update","skipped":"unchanged","kept":0,"new":[],"repeats":0,"contradictions":[],"cost_usd":0,"open":[]}"#

    private var top: URL!
    private var sessions: URL { top.appendingPathComponent("sessions", isDirectory: true) }
    private var paths: PersonaPaths { PersonaPaths(profile: top.appendingPathComponent("profile", isDirectory: true), sessionsRoot: sessions) }
    private var brains: [ScriptedPersonaBrain] = []
    private var locals: [Bool] = []
    private var modes: [ScriptedPersonaBrain.Mode] = []

    override func setUp() async throws {
        top = FileManager.default.temporaryDirectory.appendingPathComponent("verse-persona-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        brains = []
        locals = []
        modes = []
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: top) }

    /// A fictional finished call. `owner`: a row of his; `room`: only a relabelled room text of his.
    private func makeSession(_ name: String, owner: Bool = true, room: Bool = false, transcript: Bool = true) throws {
        let d = sessions.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "".write(to: d.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        guard transcript else { return }
        var rows = [#"{"turn_id":"r1","speaker":"remote","text":"Tell me about your last role.","kind":"question","t_audio_end":5.2}"#]
        if owner { rows.append(#"{"turn_id":"m1","speaker":"me","text":"I led a team of twelve at Northwind.","kind":"statement","t_audio_end":14.8}"#) }
        if room { rows.append(#"{"turn_id":"q2","speaker":"room","text":"I expect around a hundred.","kind":"statement","t_audio_end":20.0}"#) }
        try (rows.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        if room {
            try #"{"t":1795600015.2,"ev":"room_text","turn":"q2","final":true,"label":"me","reason":"strict","words":5}"#
                .appending("\n").write(to: d.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
    }

    private func service(_ modes: ScriptedPersonaBrain.Mode...) -> PersonaService {
        self.modes = modes
        let s = PersonaService(paths: paths, enabled: true, makeBrain: { [unowned self] local in
            let mode = self.modes.isEmpty ? .done(Self.done) : self.modes.removeFirst()
            let b = ScriptedPersonaBrain(mode)
            self.brains.append(b)
            self.locals.append(local)
            return b
        })
        s.configured = { true }
        return s
    }

    private func finished(_ name: String, isTest: Bool = false) -> FinishedRun {
        FinishedRun(code: 0, sessionName: name, sessionDir: sessions.appendingPathComponent(name), startedAt: Date(), isTest: isTest)
    }

    // MARK: the gate

    func testGateTable() {
        typealias F = PersonaGate.Facts
        let rows: [(String, F, PersonaGate.Trigger, PersonaGate.Decision)] = [
            ("a call that ended", F(session: "meeting-1"), .automatic, .run),
            ("while a call runs or stops", F(session: "meeting-1", callActive: true), .automatic, .wait),
            ("toggle off", F(session: "meeting-1", toggleOn: false), .automatic, .skip(.toggleOff)),
            ("toggle off, by hand", F(session: "meeting-1", toggleOn: false), .manual, .run),
            ("no persona_dir", F(session: "meeting-1", configured: false), .automatic, .skip(.notConfigured)),
            ("no persona_dir, by hand", F(session: "meeting-1", configured: false), .manual, .skip(.notConfigured)),
            ("practice", F(session: "sim-20261020-1000"), .automatic, .skip(.practice)),
            ("practice, by hand", F(session: "sim-20261020-1000"), .manual, .skip(.practice)),
            ("general prep", F(session: "general-core"), .automatic, .skip(.standingPrep)),
            ("compiled persona", F(session: "persona-core"), .manual, .skip(.standingPrep)),
            ("canned brain or test file", F(session: "meeting-1", isTestRun: true), .automatic, .skip(.testRun)),
            ("test run, by hand", F(session: "meeting-1", isTestRun: true), .manual, .run),
            ("no transcript", F(session: "meeting-1", hasTranscript: false, hasOwnerSpeech: false), .automatic, .skip(.noTranscript)),
            ("no owner speech", F(session: "meeting-1", hasOwnerSpeech: false), .automatic, .skip(.noOwnerSpeech)),
            ("practice while a call runs", F(session: "sim-x", callActive: true), .automatic, .skip(.practice)),
        ]
        for (label, facts, trigger, want) in rows {
            XCTAssertEqual(PersonaGate.decide(facts, trigger: trigger), want, label)
        }
    }

    func testOwnerSpeechFromRowsAndRoomRelabels() throws {
        try makeSession("own")
        try makeSession("silent", owner: false)
        try makeSession("room", owner: false, room: true)
        XCTAssertTrue(PersonaGate.hasOwnerSpeech(sessionDir: sessions.appendingPathComponent("own")))
        XCTAssertFalse(PersonaGate.hasOwnerSpeech(sessionDir: sessions.appendingPathComponent("silent")))
        XCTAssertTrue(PersonaGate.hasOwnerSpeech(sessionDir: sessions.appendingPathComponent("room")))
    }

    // MARK: when it runs

    func testRunsOnlyAfterStopAndTheMemorySyncAfterIt() async throws {
        try makeSession("meeting-1")
        let s = service()
        s.runEnded(finished("meeting-1"))
        XCTAssertEqual(s.pending.map(\.session), ["meeting-1"])
        XCTAssertEqual(s.startCount, 0, "nothing before the memory sync")
        s.syncFinished(afterCall: false)
        XCTAssertEqual(s.startCount, 0, "a sync that did not follow a call does not start it")
        s.syncFinished(afterCall: true)
        let ended = await eventually { s.last != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(s.startCount, 1)
        XCTAssertEqual(locals, [false], "an update needs the model")
        let start = MemoryFixtures.object(brains[0].sent[0])
        XCTAssertEqual(start["action"] as? String, "update")
        XCTAssertEqual(start["session_dir"] as? String, sessions.appendingPathComponent("meeting-1").path)
        XCTAssertEqual(start["seed_from_general"] as? Bool, true)
        XCTAssertNil(start["persona_dir"], "the brain reads persona_dir from the owner profile itself")
        XCTAssertEqual(s.last?.state, .updated)
        XCTAssertEqual(s.last?.added, 2)
        XCTAssertEqual(s.last?.contradictions, 1)
        XCTAssertEqual(s.open.map(\.id), ["c001"])
        XCTAssertEqual(s.open.first?.first.quote, "around 95,000 euros")
        XCTAssertEqual(s.open.first?.second.ref, "k3b4 0:15")
        XCTAssertTrue(s.pending.isEmpty)
        let spend = SpendLedger.runs(sessionDir: sessions.appendingPathComponent("meeting-1"))
        XCTAssertEqual(spend.map(\.kind), ["persona"])
        XCTAssertEqual(spend.first?.costUSD ?? 0, 0.12, accuracy: 1e-9)
        // What the Me page shows survives a relaunch.
        let again = PersonaService(paths: paths, enabled: true, makeBrain: { _ in ScriptedPersonaBrain(.hold) })
        XCTAssertEqual(again.last, s.last)
        XCTAssertEqual(again.open, s.open)
    }

    func testNeverStartsWhileACallRunsOrStops() async throws {
        try makeSession("meeting-1")
        let s = service()
        var active = true
        s.callActive = { active }
        s.runEnded(finished("meeting-1"))
        s.syncFinished(afterCall: true)
        XCTAssertEqual(s.startCount, 0)
        XCTAssertEqual(s.pending.map(\.session), ["meeting-1"], "kept for later")
        XCTAssertFalse(s.canLearn(session: "meeting-1"))
        active = false
        s.syncFinished(afterCall: true)
        let ended = await eventually { s.last != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(s.startCount, 1)
    }

    func testACallStartKillsTheChildAndTheSessionRunsAfterTheNextCall() async throws {
        try await callStartKills(waitForProcess: true)
    }

    func testACallStartBeforeTheProcessIsUpStillStopsIt() async throws {
        try await callStartKills(waitForProcess: false)
    }

    private func callStartKills(waitForProcess: Bool) async throws {
        try makeSession("meeting-1")
        let s = service(.hold, .done(Self.done))
        var active = false
        s.callActive = { active }
        s.runEnded(finished("meeting-1"))
        s.syncFinished(afterCall: true)
        XCTAssertEqual(s.active, "meeting-1", "claimed at once")
        if waitForProcess {
            let up = await eventually { self.brains.count == 1 && !self.brains[0].sent.isEmpty }
            XCTAssertTrue(up)
        }
        active = true
        s.callStarted()
        let gone = await eventually { s.active == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(brains.count, 1)
        XCTAssertTrue(brains[0].closed, "the child is killed")
        XCTAssertNil(s.last, "a stop for a call is not a failure")
        XCTAssertEqual(s.pending.map(\.session), ["meeting-1"], "back in the queue")
        XCTAssertEqual(PersonaService.load(paths.appState).pending.map(\.session), ["meeting-1"], "and on disk")
        s.syncFinished(afterCall: true)
        XCTAssertEqual(brains.count, 1, "not while the new call runs")
        active = false
        s.syncFinished(afterCall: true)
        let ended = await eventually { s.last != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(brains.count, 2)
        XCTAssertEqual(s.last?.state, .updated)
    }

    func testSkippedKindsStartNothing() async throws {
        try makeSession("sim-20261020-1000")
        try makeSession("general-core")
        try makeSession("persona-core")
        try makeSession("silent", owner: false)
        try makeSession("no-transcript", transcript: false)
        try makeSession("fake-run")
        try makeSession("meeting-1")
        let s = service()
        for name in ["sim-20261020-1000", "general-core", "persona-core", "silent", "no-transcript"] { s.runEnded(finished(name)) }
        s.runEnded(finished("fake-run", isTest: true))
        XCTAssertTrue(s.pending.isEmpty)
        s.syncFinished(afterCall: true)
        XCTAssertEqual(s.startCount, 0)

        var on = false
        s.toggleOn = { on }
        s.runEnded(finished("meeting-1"))
        XCTAssertTrue(s.pending.isEmpty, "toggle off: not queued")
        on = true
        s.runEnded(finished("meeting-1"))
        on = false
        s.syncFinished(afterCall: true)
        XCTAssertEqual(s.startCount, 0, "turned off after it was queued: dropped at start")
        XCTAssertTrue(s.pending.isEmpty)

        let off = service()
        off.configured = { false }
        off.runEnded(finished("meeting-1"))
        off.syncFinished(afterCall: true)
        XCTAssertEqual(off.startCount, 0, "no persona_dir: nothing runs")
    }

    func testLearnFromThisCallIgnoresTheToggleButNotTheKinds() async throws {
        try makeSession("meeting-1")
        try makeSession("sim-20261020-1000")
        try makeSession("silent", owner: false)
        let s = service(.done(Self.nothing))
        s.toggleOn = { false }
        XCTAssertEqual(s.learn(session: "sim-20261020-1000"), .practice)
        XCTAssertEqual(s.learn(session: "silent"), .noOwnerSpeech)
        XCTAssertFalse(s.canLearn(session: "silent"))
        XCTAssertTrue(s.canLearn(session: "meeting-1"))
        XCTAssertNil(s.learn(session: "meeting-1"))
        let ended = await eventually { s.last != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(s.last?.state, .nothingNew)
        XCTAssertTrue(SpendLedger.runs(sessionDir: sessions.appendingPathComponent("meeting-1")).isEmpty, "no spend, no record")
    }

    func testAFailureIsRecordedWithItsKind() async throws {
        try makeSession("meeting-1")
        let s = service(.error("offline"))
        s.learn(session: "meeting-1")
        let ended = await eventually { s.last != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(s.last?.state, .failed)
        XCTAssertEqual(s.last?.kind, "offline")
        XCTAssertEqual(PersonaRunRecord.reason("offline"), PersonaRunRecord.reason("offline"))
        XCTAssertNotEqual(PersonaRunRecord.reason("offline"), PersonaRunRecord.reason("bad_output"))
    }

    func testSettlingAContradictionUsesALocalProcess() async throws {
        let s = service(.done(#"{"type":"persona_done","action":"resolve","open":[]}"#))
        s.resolve("c001", keep: 2)
        let ended = await eventually { s.resolving == nil && !self.brains.isEmpty }
        XCTAssertTrue(ended)
        XCTAssertEqual(locals, [true], "no model, no Keychain")
        let start = MemoryFixtures.object(brains[0].sent[0])
        XCTAssertEqual(start["action"] as? String, "resolve")
        XCTAssertEqual(start["id"] as? String, "c001")
        XCTAssertEqual(start["keep"] as? String, "2")
        XCTAssertTrue(s.open.isEmpty)
        XCTAssertNil(s.resolveError)
    }

    func testTheMemorySyncSaysWhetherItFollowedACall() async throws {
        let scratch = try MemoryFixtures.scratch()
        defer { scratch.remove() }
        let m = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { MemoryFixtures.owner },
                              makeBrain: { ScriptedIndexBrain() }, enabled: true)
        m.embeds = false
        var calls: [Bool] = []
        m.onSyncFinished = { calls.append($0) }
        m.requestSync(.labelsChanged)
        let first = await eventually { calls.count == 1 }
        XCTAssertTrue(first)
        m.requestSync(.callEnded)
        let second = await eventually { calls.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(calls, [false, true])
    }

    // MARK: seeding unprepared calls

    private func makeStanding(_ name: String, pack: String, compiled: Bool) throws {
        let d = sessions.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try pack.write(to: d.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        try "{\"id\":\"b001\",\"question\":\"\(name)?\"}\n".write(to: d.appendingPathComponent("bank.jsonl"), atomically: true, encoding: .utf8)
        if compiled { try "{}\n".write(to: d.appendingPathComponent(".verse-compiled"), atomically: true, encoding: .utf8) }
    }

    func testSeedingTable() throws {
        let utc = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-16T14:32:10Z")!
        enum Persona { case present, absent, emptyPack, unmarked }
        let rows: [(String, Persona, Bool, Bool, Bool, String?)] = [
            // label, persona folder, general-core built, persona on, use general prep, base (nil: empty pack)
            ("persona compiled", .present, true, true, true, "persona-core"),
            ("persona compiled, no general prep", .present, false, true, true, "persona-core"),
            ("persona compiled but persona_dir unset", .present, true, false, true, "general-core"),
            ("no persona yet", .absent, true, true, true, "general-core"),
            ("persona with an empty pack", .emptyPack, true, true, true, "general-core"),
            ("persona folder Verse did not compile", .unmarked, true, true, true, "general-core"),
            ("neither", .absent, false, true, true, nil),
            ("use general prep off", .present, true, true, false, nil),
        ]
        for (label, persona, general, personaOn, use, want) in rows {
            try? FileManager.default.removeItem(at: sessions)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            if general { try makeStanding("general-core", pack: "# General\n", compiled: false) }
            switch persona {
            case .present: try makeStanding("persona-core", pack: "# Persona\n", compiled: true)
            case .emptyPack: try makeStanding("persona-core", pack: "", compiled: true)
            case .unmarked: try makeStanding("persona-core", pack: "# Persona\n", compiled: false)
            case .absent: break
            }
            let n = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: sessions, timeZone: utc,
                                                   useGeneralPrep: use, personaOn: personaOn)
            let dir = SessionCatalog.url(n, root: sessions)
            XCTAssertEqual(AdhocMeta.read(sessionDir: dir)?.base, want, label)
            let pack = try String(contentsOf: dir.appendingPathComponent("pack.md"), encoding: .utf8)
            switch want {
            case "persona-core": XCTAssertEqual(pack, "# Persona\n", label)
            case "general-core": XCTAssertEqual(pack, "# General\n", label)
            default: XCTAssertEqual(pack, "", label)
            }
            let status = GeneralPrep.status(root: sessions, personaOn: personaOn)
            XCTAssertEqual(status?.source.folder, persona == .present && personaOn ? "persona-core" : (general ? "general-core" : nil), label)
        }
    }

    func testTheCompiledPersonaIsNoSession() throws {
        try makeStanding("persona-core", pack: "# Persona\n", compiled: true)
        XCTAssertTrue(GeneralPrep.isGeneral("persona-core"))
        let m = MemoryManifest.build(root: sessions, ownerName: "Dana", recording: nil, labels: { _ in [] })
        XCTAssertFalse(m.entries.contains { $0.name == "persona-core" })
    }
}
