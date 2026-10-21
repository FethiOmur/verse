import Combine
import CryptoKit
import Darwin
import Foundation
import VerseTurns

// Verse's memory, app side (memory spec 2.1, 3.1, 3.3, 3.5): keeps the brain's index of past sessions in sync with the sessions folder
// and runs the pre-meeting brief. The index belongs to the brain; this file only decides *when* to sync (coalesced), *what* to send
// (a manifest of fingerprints, then the transcript rows of the sessions the brain asks for) and moves the brief's one request and
// answer. Nothing here reads audio, and nothing logs meeting text, questions, answers or e-mail addresses: names, counts and timings.

// Result<BriefFile, ChatFailure> needs the failure to be an Error; the type itself lives in ChatLog.swift.
extension ChatFailure: Error {}

// MARK: - Paths

/// `~/Library/Application Support/Verse/memory/` and what lives in it (spec 3.1). `base` is that folder; tests pass a scratch one.
struct MemoryPaths: Sendable, Equatable {
    let base: URL

    init(base: URL) { self.base = base }

    static var live: MemoryPaths {
        MemoryPaths(base: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verse/memory", isDirectory: true))
    }

    var dir: URL { base }
    var db: URL { base.appendingPathComponent("index.sqlite") }
    var people: URL { base.appendingPathComponent("people.json") }
    var briefs: URL { base.appendingPathComponent("briefs", isDirectory: true) }
    var chats: URL { base.appendingPathComponent("chats", isDirectory: true) }
    /// The folder whose `spend.json` holds the briefs that belong to no session (`SpendLedger` treats it like a session folder).
    var spendDir: URL { base }

    func brief(entity id: String) -> URL { briefs.appendingPathComponent("\(id).json") }
    func chat(named name: String) -> URL { chats.appendingPathComponent("\(name).jsonl") }

    /// Creates the folders on first use; the app never creates them just by looking.
    func ensureDirectories() {
        let fm = FileManager.default
        for d in [base, briefs, chats] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

// MARK: - Manifest

/// Bumping it makes every session re-index (spec 2.1 "Incremental").
enum MemoryIndexFormat {
    static let version = 1
}

/// What the index should hold: one entry per indexable session, each with the fingerprint that tells the brain whether its copy is
/// current. Meetings and calls (a transcript and/or summary) and prepared sessions (pack only); not practice runs (`sim-*`), not
/// `general-core`, not the session being recorded (it joins after Stop).
struct MemoryManifest: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var name: String
        var fp: String
        var labels: [String]
        var title: String
        /// ISO 8601 with the local offset (`2026-10-19T17:00:00+02:00`).
        var date: String
        /// `meeting`, `call` or `prepared`.
        var kind: String
        /// `meta.json languages[0]`, or "".
        var lang: String
    }

    var entries: [Entry]

    /// The files whose size and mtime make the fingerprint (spec 2.1).
    static let fingerprintFiles = ["transcript.jsonl", "events.jsonl", "summary.md", "pack.md", "chat.jsonl", "meta.json"]

    static func build(root: URL, ownerName: String, recording: String?, labels: (String) -> [String],
                      timeZone: TimeZone = .current) -> MemoryManifest {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        var entries: [Entry] = []
        for name in SessionCatalog.list(root: root) {
            if GeneralPrep.isGeneral(name) || name.hasPrefix("sim-") || name == recording { continue }
            let session = HomeSession.load(name: name, root: root)
            let kind: String
            switch session.kind {
            case .meeting: kind = "meeting"
            case .call: kind = "call"
            case .prepared: kind = "prepared"
            case .practice: continue
            }
            entries.append(Entry(name: name, fp: fingerprint(dir: session.dir, ownerName: ownerName), labels: labels(name), title: session.title,
                                 date: iso.string(from: session.date), kind: kind, lang: language(of: session.dir)))
        }
        return MemoryManifest(entries: entries.sorted { $0.name < $1.name })
    }

    /// SHA-256 over the format version, the owner name (speaker labels depend on it) and `name:size:mtime_ns` of the six files
    /// (`name:-` for a missing one). A file outside the six (`review.md`, `spend.json`) does not change it.
    static func fingerprint(dir: URL, ownerName: String) -> String {
        var parts = ["\(MemoryIndexFormat.version)", ownerName]
        for f in fingerprintFiles {
            var st = stat()
            if stat(dir.appendingPathComponent(f).path, &st) == 0 {
                let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
                parts.append("\(f):\(st.st_size):\(ns)")
            } else {
                parts.append("\(f):-")
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func language(of dir: URL) -> String {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let langs = o["languages"] as? [Any], let first = langs.first as? String else { return "" }
        return first
    }

    /// The `sync` line (spec 3.3): the complete manifest, keys sorted.
    func syncLine() -> String {
        AskWire.line(["type": "sync", "sessions": entries.map { ["name": $0.name, "fp": $0.fp, "labels": $0.labels] as [String: Any] }])
    }
}

// MARK: - Index wire

/// What the indexer process says (spec 3.3). Unknown types and lines that are not JSON are ignored.
enum MemoryIndexEvent: Equatable, Sendable {
    case status(state: String, message: String, sessions: Int?, chunks: Int?, vectors: Int?, embed: String?)
    case syncPlan(need: [String], dropped: [String], relabelled: Int)
    case putDone(name: String, key: String, chunks: Int)
    case embedProgress(done: Int, total: Int)
    case indexError(name: String, kind: String, message: String)

    static func parse(_ line: String) -> MemoryIndexEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = o["type"] as? String else { return nil }
        func str(_ k: String) -> String { (o[k] as? String) ?? "" }
        func int(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
        switch type {
        case "status":
            let c = o["context"] as? [String: Any]
            return .status(state: str("state"), message: str("message"), sessions: int(c, "sessions"), chunks: int(c, "chunks"),
                           vectors: int(c, "vectors"), embed: c?["embed"] as? String)
        case "sync_plan":
            return .syncPlan(need: (o["need"] as? [String]) ?? [], dropped: (o["dropped"] as? [String]) ?? [], relabelled: int(o, "relabelled") ?? 0)
        case "put_done":
            return .putDone(name: str("name"), key: str("key"), chunks: int(o, "chunks") ?? 0)
        case "embed_progress":
            return .embedProgress(done: int(o, "done") ?? 0, total: int(o, "total") ?? 0)
        case "index_error":
            return .indexError(name: str("name"), kind: str("kind"), message: str("message"))
        default:
            return nil
        }
    }
}

/// Ends a process that has gone quiet: it calls `onStall` once when nothing arrived for `limit`.
@MainActor
final class StallWatchdog {
    private var last = ContinuousClock.now
    private var task: Task<Void, Never>?
    private(set) var fired = false

    init(limit: Duration, onStall: @escaping @MainActor () async -> Void) {
        let step = Swift.max(limit / 4, .milliseconds(10))
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - self.last >= limit {
                    self.fired = true
                    await onStall()
                    return
                }
            }
        }
    }

    func poke() { last = ContinuousClock.now }
    func stop() { task?.cancel(); task = nil }
}

// MARK: - Indexer

/// One pass of the brain's index process: `memory_index_start`, `sync`, a `put` for each session the brain asks for, `end`.
@MainActor
final class MemoryIndexer {
    struct Summary: Equatable, Sendable {
        var sessions = 0
        var chunks = 0
        var vectors = 0
        var embed = ""
        /// Sessions the brain could not index (it said `index_error` with a name).
        var failedPuts = 0
    }

    enum Outcome: Equatable, Sendable {
        case done(Summary)
        /// Another indexer holds the lock (`status busy`).
        case busy
        case failed(String)
    }

    let paths: MemoryPaths
    let ownerName: String
    var embed = true
    var stall: Duration = .seconds(180)

    init(paths: MemoryPaths, ownerName: String) {
        self.paths = paths
        self.ownerName = ownerName
    }

    func startLine() -> String {
        AskWire.line(["type": "memory_index_start", "db": paths.db.path, "embed": embed])
    }

    /// The `put` line for one session (spec 3.3).
    nonisolated static func putLine(_ e: MemoryManifest.Entry, dir: URL, rows: [AskRow]) -> String {
        AskWire.line([
            "type": "put", "name": e.name, "dir": dir.path, "fp": e.fp, "title": e.title, "date": e.date, "kind": e.kind, "lang": e.lang,
            "labels": e.labels, "rows": rows.map { ["stamp": $0.stamp, "speaker": $0.speaker, "text": $0.text] },
        ])
    }

    /// The rows Ask this meeting sends, from the one implementation of runs and stamps (`TranscriptDocument.askRows`).
    nonisolated static func rows(sessionDir: URL, ownerName: String) -> [AskRow] {
        TranscriptDocument.load(sessionDir: sessionDir, ownerName: ownerName).askRows.map { AskRow(stamp: $0.stamp, speaker: $0.speaker, text: $0.text) }
    }

    /// `drop`: sessions that left the folder since the last run (Move to Trash). The brain's `sync` drops absentees too; the explicit
    /// `drop{names}` first makes the secure delete not depend on the manifest being complete.
    func run(manifest: MemoryManifest, drop: [String] = [], sessionsRoot: URL, makeBrain: () throws -> any SimBrainTransport,
             report: (MemoryService.Phase) -> Void) async -> Outcome {
        let brain: any SimBrainTransport
        do { brain = try makeBrain() } catch { return .failed("\(error)") }
        let started = ContinuousClock.now
        brain.send(startLine())
        if !drop.isEmpty { brain.send(AskWire.line(["type": "drop", "names": drop])) }
        brain.send(manifest.syncLine())

        let dog = StallWatchdog(limit: stall) { await brain.close() }
        let byName = Dictionary(manifest.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let owner = ownerName
        var queue: [String] = []
        var total = 0
        var completed = 0
        var summary = Summary()
        var outcome: Outcome?

        /// Sends the next `put`, or `end` when nothing is left. Rows are read off the main thread, one session at a time.
        func sendNext() async {
            while let name = queue.first {
                queue.removeFirst()
                guard let e = byName[name] else { completed += 1; continue }
                let dir = sessionsRoot.appendingPathComponent(name, isDirectory: true)
                let rows = await Task.detached { Self.rows(sessionDir: dir, ownerName: owner) }.value
                brain.send(Self.putLine(e, dir: dir, rows: rows))
                return
            }
            brain.send(AskWire.line(["type": "end"]))
        }

        for await line in brain.lines {
            dog.poke()
            guard let event = MemoryIndexEvent.parse(line) else { continue }
            switch event {
            case .status(let state, let message, let sessions, let chunks, let vectors, let embed):
                switch state {
                case "busy":
                    outcome = .busy
                case "error":
                    outcome = .failed(message.isEmpty ? "the memory indexer reported an error" : message)
                case "done":
                    summary.sessions = sessions ?? summary.sessions
                    summary.chunks = chunks ?? summary.chunks
                    summary.vectors = vectors ?? summary.vectors
                    summary.embed = embed ?? summary.embed
                    outcome = .done(summary)
                default:
                    break
                }
            case .syncPlan(let need, let dropped, let relabelled):
                FileLog.shared.write("memory: sync plan need=\(need.count) dropped=\(dropped.count) relabelled=\(relabelled)")
                queue = need
                total = need.count
                if total > 0 { report(.indexing(done: 0, total: total)) }
                await sendNext()
            case .putDone(let name, _, let chunks):
                FileLog.shared.write("memory: indexed \(name) chunks=\(chunks)")
                completed += 1
                report(.indexing(done: completed, total: total))
                await sendNext()
            case .indexError(let name, let kind, _):
                FileLog.shared.write("memory: index error kind=\(kind) session=\(name.isEmpty ? "-" : name)")
                if name.isEmpty {
                    outcome = .failed(kind)
                } else {
                    summary.failedPuts += 1
                    completed += 1
                    report(.indexing(done: completed, total: total))
                    await sendNext()
                }
            case .embedProgress(let done, let total):
                report(.embedding(done: done, total: total))
            }
            if outcome != nil { break }
        }
        dog.stop()
        await brain.close()
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        if let outcome {
            FileLog.shared.write("memory: index run ended in \(ms) ms")
            return outcome
        }
        return .failed(dog.fired ? "the memory indexer stopped answering" : "the memory indexer ended before it finished")
    }
}

// MARK: - Service

/// Owns the sync of the index and the brief runner. One per app; `HomeContext` builds it.
@MainActor
final class MemoryService: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case indexing(done: Int, total: Int)
        case embedding(done: Int, total: Int)
        case failed(String)
    }

    enum SyncReason: Sendable {
        case launch, callEnded, sessionsChanged, labelsChanged, askOpened
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var indexedSessions = 0
    @Published private(set) var briefsInFlight: Set<String> = []

    let paths: MemoryPaths
    /// Session name -> entity names; `EntityStore` supplies it (P4).
    var labels: (String) -> [String] = { _ in [] }
    /// The session being recorded right now, if any: it joins the index after Stop.
    var recordingSession: () -> String? = { nil }

    // Timing and limits, injectable for tests.
    var launchDelay: Duration = .seconds(15)
    var callEndDelay: Duration = .seconds(20)
    var busyRetryDelay: Duration = .seconds(30)
    var maxBusyRetries = 10
    var indexStall: Duration = .seconds(180)
    var briefStall: Duration = .seconds(150)
    var cancelGrace: Duration = .seconds(2)
    /// False in renders: the brain gets no `embed` phase.
    var embeds = true

    private let sessionsRoot: URL
    private let ownerName: () -> String
    private let makeBrain: () throws -> any SimBrainTransport
    /// The index writer needs no API client: the real one starts with `--no-api` (no Keychain read). Nil uses `makeBrain`.
    private let makeIndexBrain: (() throws -> any SimBrainTransport)?
    /// Names in the last manifest the brain accepted: what `drop` is computed against.
    private var knownNames: Set<String> = []
    /// A service that is not enabled never starts a process (tests and renders that build a `HomeContext`).
    let enabled: Bool

    private var syncing = false
    /// A run is open or queued (tests).
    var isSyncing: Bool { syncing }
    private var rerun = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var lastRunFailed = false
    private var launchTask: Task<Void, Never>?
    private var callEndTask: Task<Void, Never>?
    private var runningWatch: AnyCancellable?
    private var briefTasks: [String: Task<Result<BriefFile, ChatFailure>, Never>] = [:]
    private var briefBrains: [String: any SimBrainTransport] = [:]
    private var briefCancelled: Set<String> = []
    /// How many index processes were started (tests).
    private(set) var runCount = 0

    init(paths: MemoryPaths = .live, sessionsRoot: URL = SessionCatalog.root, ownerName: @escaping () -> String,
         makeBrain: @escaping () throws -> any SimBrainTransport, makeIndexBrain: (() throws -> any SimBrainTransport)? = nil,
         enabled: Bool = true) {
        self.paths = paths
        self.sessionsRoot = sessionsRoot
        self.ownerName = ownerName
        self.makeBrain = makeBrain
        self.makeIndexBrain = makeIndexBrain
        self.enabled = enabled
    }

    nonisolated static func brainArguments(fake: Bool, indexOnly: Bool) -> [String] { (fake ? ["--fake"] : []) + (indexOnly ? ["--no-api"] : []) }

    /// The real brain: `python -u -m verse_brain.runtime` (`--fake` for the fake brain), logs to `verse.log`. `indexOnly` adds
    /// `--no-api`: the memory index writer serves only `memory_index_start` and never reads the Keychain.
    static func makeBrainProcess(fake: Bool, indexOnly: Bool = false) throws -> any SimBrainTransport {
        guard let dir = VerseController.brainDir() else { throw BrainError.brainDirNotFound("set VERSE_BRAIN_DIR") }
        let b = try BrainProcess(brainDir: dir, extraArgs: brainArguments(fake: fake, indexOnly: indexOnly), onStderr: { FileLog.shared.write("[memory brain] " + $0) })
        try b.start()
        return b
    }

    // MARK: triggers

    /// Schedules the launch sync (15 s) and watches the call: when `controller.running` goes true → false the summary is written
    /// a moment later and a sync follows (20 s).
    func attach(controller: VerseController) {
        guard enabled else { return }
        launchTask?.cancel()
        let delay = launchDelay
        launchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestSync(.launch)
        }
        var was = controller.running
        runningWatch = controller.$running.removeDuplicates().sink { [weak self] now in
            let ended = was && !now
            was = now
            if ended { MainActor.assumeIsolated { self?.callEnded() } }
        }
    }

    /// A call stopped: sync after `callEndDelay`.
    func callEnded() {
        guard enabled else { return }
        callEndTask?.cancel()
        let delay = callEndDelay
        callEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestSync(.callEnded)
        }
    }

    // MARK: sync

    /// Coalesced: one run at a time; a request during a run schedules exactly one more.
    func requestSync(_ reason: SyncReason) {
        guard enabled else { return }
        if syncing { rerun = true; return }
        syncing = true
        Task { @MainActor [weak self] in await self?.runLoop() }
    }

    /// Requests a sync and waits for it (and the one queued behind it) to end. True when that happened within `timeout` and the
    /// index is as current as the brain could make it; false on timeout, a failed run, or a disabled service.
    func syncNow(timeout: Duration?) async -> Bool {
        guard enabled else { return false }
        requestSync(.askOpened)
        let id = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiters[id] = c
            if let timeout {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.waiters.removeValue(forKey: id)?.resume(returning: false)
                }
            }
        }
    }

    private func runLoop() async {
        var busyRetries = 0
        repeat {
            rerun = false
            runCount += 1
            switch await performRun() {
            case .done:
                lastRunFailed = false
                busyRetries = 0
            case .busy:
                busyRetries += 1
                if busyRetries > maxBusyRetries {
                    phase = .failed("the memory index is locked by another process")
                    lastRunFailed = true
                } else {
                    try? await Task.sleep(for: busyRetryDelay)
                    rerun = true
                }
            case .failed:
                // Not retried at once: the next request tries again.
                lastRunFailed = true
                rerun = false
            }
        } while rerun
        syncing = false
        let ok = !lastRunFailed
        let all = waiters
        waiters = [:]
        for (_, c) in all { c.resume(returning: ok) }
    }

    private func performRun() async -> MemoryIndexer.Outcome {
        paths.ensureDirectories()
        let root = sessionsRoot, owner = ownerName(), recording = recordingSession()
        let base = await Task.detached { MemoryManifest.build(root: root, ownerName: owner, recording: recording, labels: { _ in [] }) }.value
        var manifest = base
        manifest.entries = base.entries.map { var e = $0; e.labels = labels(e.name); return e }

        let indexer = MemoryIndexer(paths: paths, ownerName: owner)
        indexer.embed = embeds
        indexer.stall = indexStall
        let names = Set(manifest.entries.map(\.name))
        let removed = knownNames.subtracting(names).sorted()
        let outcome = await indexer.run(manifest: manifest, drop: removed, sessionsRoot: root, makeBrain: makeIndexBrain ?? makeBrain,
                                        report: { [weak self] in self?.phase = $0 })
        switch outcome {
        case .done(let s):
            knownNames = names
            indexedSessions = s.sessions
            phase = .idle
        case .busy:
            phase = .idle
        case .failed(let m):
            FileLog.shared.write("memory: index run failed")
            phase = .failed(m)
        }
        return outcome
    }

    // MARK: brief

    /// Writes the brief of `request.entity` and returns it (spec 2.4, 3.5). One process per entity at a time: a second request for the
    /// same entity waits for the first one's result.
    func makeBrief(_ request: BriefRequest) async -> Result<BriefFile, ChatFailure> {
        let id = request.entity.id
        if let running = briefTasks[id] { return await running.value }
        let task = Task { @MainActor [weak self] () -> Result<BriefFile, ChatFailure> in
            guard let self else { return .failure(ChatFailure(kind: "error", message: "")) }
            return await self.runBrief(request)
        }
        briefTasks[id] = task
        briefsInFlight.insert(id)
        let result = await task.value
        briefTasks.removeValue(forKey: id)
        briefsInFlight.remove(id)
        return result
    }

    /// Asks the brief process to stop; it is killed when it has not ended after `cancelGrace`. Nothing is recorded unless the brain
    /// reported what the interrupted call cost.
    func cancelBrief(entity id: String) {
        guard let brain = briefBrains[id] else { return }
        briefCancelled.insert(id)
        brain.send(AskWire.control("stop"))
        let grace = cancelGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            if let self, self.briefBrains[id] === brain { await brain.close() }
        }
    }

    private func runBrief(_ request: BriefRequest) async -> Result<BriefFile, ChatFailure> {
        let id = request.entity.id
        paths.ensureDirectories()
        let startedAt = Date()
        let out = paths.brief(entity: id)
        let brain: any SimBrainTransport
        do { brain = try makeBrain() } catch {
            return .failure(ChatFailure(kind: "start_failed", message: "\(error)"))
        }
        briefBrains[id] = brain
        defer { briefBrains.removeValue(forKey: id); briefCancelled.remove(id) }
        brain.send(request.startLine(db: paths.db, out: out, ownerName: ownerName()))

        let dog = StallWatchdog(limit: briefStall) { await brain.close() }
        var statusError: String?
        var result: Result<BriefFile, ChatFailure>?
        var cost = 0.0
        for await line in brain.lines {
            dog.poke()
            switch BriefEvent.parse(line) {
            case .status(let state, let message)?:
                if state == "error" { statusError = message }
            case .done(let path, let costUSD, let points, let dropped, let ms)?:
                cost = costUSD
                let file = path.map { URL(fileURLWithPath: $0) } ?? out
                if let brief = BriefStore.load(url: file) {
                    FileLog.shared.write("memory: brief for \(request.entity.name) points=\(points) dropped_uncited=\(dropped) ms=\(ms)")
                    result = .success(brief)
                } else {
                    result = .failure(ChatFailure(kind: "error", message: "the brief file could not be read"))
                }
            case .error(let failure, let costUSD)?:
                cost = costUSD ?? 0
                FileLog.shared.write("memory: brief for \(request.entity.name) failed kind=\(failure.kind)")
                result = .failure(failure)
            case nil:
                break
            }
            if result != nil { break }
        }
        dog.stop()
        await brain.close()
        if cost > 0 { recordBriefSpend(request, startedAt: startedAt, cost: cost) }
        if let result { return result }
        if briefCancelled.contains(id) { return .failure(ChatFailure(kind: "cancelled", message: "")) }
        if dog.fired { return .failure(ChatFailure(kind: "error", message: "the brief timed out")) }
        let keyMissing = statusError?.localizedCaseInsensitiveContains("keychain") ?? false
        return .failure(ChatFailure(kind: keyMissing ? "key_missing" : "error", message: statusError ?? ""))
    }

    /// A brief for a prepared session is a run of kind `brief` in that session's `spend.json`; any other goes into `memory/spend.json`.
    private func recordBriefSpend(_ request: BriefRequest, startedAt: Date, cost: Double) {
        let dir = request.sessionOut ?? paths.spendDir
        // The ledger keys a run by its start second and kind: two briefs started in one second must stay two records.
        var start = startedAt
        let taken = Set(SpendLedger.runs(sessionDir: dir).filter { $0.kind == "brief" }.map { $0.startedAt.timeIntervalSince1970.rounded(.down) })
        while taken.contains(start.timeIntervalSince1970.rounded(.down)) { start = start.addingTimeInterval(1) }
        SpendLedger.record(sessionDir: dir, startedAt: start, costUSD: cost, kind: "brief")
    }
}

// MARK: - Brief wire

/// What the brief process says (spec 3.5).
enum BriefEvent: Equatable, Sendable {
    case status(state: String, message: String)
    case done(path: String?, costUSD: Double, points: Int, droppedUncited: Int, ms: Int)
    case error(ChatFailure, costUSD: Double?)

    static func parse(_ line: String) -> BriefEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = o["type"] as? String else { return nil }
        func str(_ k: String) -> String { (o[k] as? String) ?? "" }
        func int(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        switch type {
        case "status":
            return .status(state: str("state"), message: str("message"))
        case "brief_done":
            return .done(path: o["path"] as? String, costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue ?? 0, points: int("points"),
                         droppedUncited: int("dropped_uncited"), ms: int("ms_total"))
        case "brief_error":
            let kind = str("kind")
            return .error(ChatFailure(kind: kind.isEmpty ? "error" : kind, message: str("message"),
                                      retryAfter: (o["retry_after"] as? NSNumber)?.doubleValue),
                          costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue)
        default:
            return nil
        }
    }
}
