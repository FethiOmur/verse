import Combine
import Foundation
import VerseTurns

// Ask this meeting, app side (spec 2.2, 3.2): one brain child process per open panel, `python -u -m verse_brain.runtime` whose first
// line is `ask_start`. In the memory scopes (memory spec 2.3, 3.4: one person or company, or every meeting) the first line is
// `memory_ask_start`, the chat file and the spend record live in the memory folder, and the citations come back as objects. The key is read by that process from the Keychain; nothing here handles it. The process ends when the panel
// closes, another session is selected, the window closes, or after 10 minutes without a question; the next question starts it
// again and the brain rebuilds its history from `chat.jsonl`.

// MARK: - Models

/// The panel's model picker. Names are product names and are not translated.
public enum AskModel: String, CaseIterable, Sendable, Identifiable {
    case haiku, sonnet, opus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        }
    }

    /// "Sonnet" for `claude-sonnet-5-5`; the id itself when it is none of the three.
    static func displayName(forModelID id: String) -> String {
        for m in allCases where id.contains(m.rawValue) { return m.title }
        return id
    }
}

/// One transcript row as the brain receives it (`TranscriptDocument.askRows`): stamp, speaker name, text.
struct AskRow: Equatable, Sendable {
    var stamp: String
    var speaker: String
    var text: String
}

/// What `ask_start` carries: the session, the owner, the rows from `TranscriptDocument`, the me layer when the profile toggle is on.
struct AskContext: Equatable, Sendable {
    var sessionDir: URL
    var ownerName: String
    var title: String
    var date: Date
    /// `profile/me.md`, or nil when "Use my profile in every session" is off or the file is missing.
    var meCore: URL?
    var rows: [AskRow]

    /// The first line the brain reads (its mode switch). Keys are sorted so the line is deterministic.
    func startLine(model: AskModel, timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        var obj: [String: Any] = [
            "type": "ask_start", "session_dir": sessionDir.path, "owner_name": ownerName, "title": title,
            "date": iso.string(from: date), "model": model.rawValue,
            "transcript": rows.map { ["stamp": $0.stamp, "speaker": $0.speaker, "text": $0.text] },
        ]
        if let meCore { obj["me"] = ["core": meCore.path] } else { obj["me"] = NSNull() }
        return AskWire.line(obj)
    }
}

/// What `memory_ask_start` carries (memory spec 3.4): the index, the chat file of the scope, the owner, the me layer when the profile
/// toggle is on, and the scope. Attendee emails are never part of it.
struct MemoryAskContext: Equatable, Sendable {
    /// `.all` or `.entity(id)`.
    var scope: AskScope
    /// The entity's name; "" for every meeting.
    var scopeName: String
    var ownerName: String
    var db: URL
    var chat: URL
    /// The folder whose `spend.json` takes the cost of this opening (`memory/`).
    var spendDir: URL
    var meCore: URL?
    /// The entity's sessions (the resolver's, newest first); empty and unused for `.all`.
    var sessions: [String] = []

    /// The first line the brain reads (its mode switch). Keys are sorted so the line is deterministic.
    func startLine(model: AskModel) -> String {
        var scopeObj: [String: Any] = ["kind": "all", "id": NSNull(), "name": NSNull(), "sessions": NSNull()]
        if case .entity(let id) = scope {
            scopeObj = ["kind": "entity", "id": id, "name": scopeName, "sessions": sessions]
        }
        var obj: [String: Any] = [
            "type": "memory_ask_start", "db": db.path, "chat": chat.path, "owner_name": ownerName, "scope": scopeObj, "model": model.rawValue,
        ]
        if let meCore { obj["me"] = ["core": meCore.path] } else { obj["me"] = NSNull() }
        return AskWire.line(obj)
    }
}

/// What an open panel is about: one session (today's Ask this meeting) or a memory scope.
enum AskTarget: Equatable, Sendable {
    case session(AskContext)
    case memory(MemoryAskContext)

    var chatURL: URL {
        switch self {
        case .session(let c): ChatLog.url(sessionDir: c.sessionDir)
        case .memory(let c): c.chat
        }
    }

    /// Where the cost of this opening is recorded: the session folder, or `memory/`.
    var spendDir: URL {
        switch self {
        case .session(let c): c.sessionDir
        case .memory(let c): c.spendDir
        }
    }

    func startLine(model: AskModel) -> String {
        switch self {
        case .session(let c): c.startLine(model: model)
        case .memory(let c): c.startLine(model: model)
        }
    }
}

/// One cited source of a memory answer (memory spec 3.4): the session, where in it, and what it says, so the hover card needs no file
/// read. `kind` is `turn` (then `stamp` is set), `summary`, `prep` or `chat`.
struct AskSource: Equatable, Sendable {
    var key: String
    var session: String
    var title: String
    var date: Date?
    var kind: String
    var stamp: String?
    var speaker: String?
    var text: String?

    init(key: String, session: String, title: String, date: Date? = nil, kind: String, stamp: String? = nil, speaker: String? = nil, text: String? = nil) {
        self.key = key
        self.session = session
        self.title = title
        self.date = date
        self.kind = kind
        self.stamp = stamp
        self.speaker = speaker
        self.text = text
    }

    /// nil unless the object has a key, a session and a kind.
    init?(_ o: [String: Any]) {
        guard let key = o["key"] as? String, let session = o["session"] as? String, let kind = o["kind"] as? String else { return nil }
        self.init(key: key, session: session, title: (o["title"] as? String) ?? session, date: (o["date"] as? String).flatMap(BriefLayout.date(from:)),
                  kind: kind, stamp: o["stamp"] as? String, speaker: o["speaker"] as? String, text: o["text"] as? String)
    }

    /// The `[key form]` form that cites it (memory spec 2.2): a stamp for a transcript line, else the kind.
    var form: String { kind == "turn" ? (stamp ?? "") : kind }
}

enum AskWire {
    static func line(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    static func askLine(id: String, text: String, model: AskModel) -> String {
        line(["type": "ask", "id": id, "text": text, "model": model.rawValue])
    }

    static func control(_ action: String) -> String { line(["type": "control", "action": action]) }
}

// MARK: - Events from the brain

struct AskDone: Equatable, Sendable {
    var answerID: String
    var question: String
    var model: String
    var usage: ChatUsage
    var costUSD: Double
    var costEstimated: Bool
    var msFirstToken: Int?
    var msTotal: Int?
    var citations: [String]
    var stopReason: String?
    /// Object citations of a memory answer (`citations` is empty then); empty for Ask this meeting.
    var sources: [AskSource] = []
    var excerptTokens: Int?
}

enum AskEvent: Equatable, Sendable {
    case status(state: String, message: String, tokens: Int?, mode: String?)
    case delta(question: String, text: String)
    case done(AskDone)
    case error(question: String, ChatFailure)

    /// nil for unknown types and for lines that are not JSON: both sides ignore what they do not know.
    static func parse(_ line: String) -> AskEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = o["type"] as? String else { return nil }
        func str(_ k: String) -> String { (o[k] as? String) ?? "" }
        func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
        switch type {
        case "status":
            let ctx = o["context"] as? [String: Any]
            return .status(state: str("state"), message: str("message"), tokens: (ctx?["tokens"] as? NSNumber)?.intValue, mode: ctx?["mode"] as? String)
        case "ask_delta":
            return .delta(question: str("q"), text: str("text"))
        case "ask_done":
            // Ask this meeting cites with strings, the memory scopes with objects; the element type tells them apart.
            let cites = (o["citations"] as? [Any]) ?? []
            return .done(AskDone(answerID: str("id"), question: str("q"), model: str("model"), usage: ChatUsage(o["usage"] as? [String: Any]),
                                 costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue ?? 0, costEstimated: (o["cost_estimated"] as? Bool) ?? false,
                                 msFirstToken: int("ms_first_token"), msTotal: int("ms_total"), citations: cites.compactMap { $0 as? String },
                                 stopReason: o["stop_reason"] as? String,
                                 sources: cites.compactMap { ($0 as? [String: Any]).flatMap(AskSource.init) }, excerptTokens: int("excerpt_tokens")))
        case "ask_error":
            return .error(question: str("q"), ChatFailure(kind: str("kind").isEmpty ? "error" : str("kind"), message: str("message"),
                                                         retryAfter: (o["retry_after"] as? NSNumber)?.doubleValue))
        default:
            return nil
        }
    }
}

// MARK: - Availability

/// Whether the detail offers Ask for a session (spec 2.2 "When available").
enum AskAvailability: Equatable, Sendable {
    /// Practice runs and prepared-but-unused sessions: no button.
    case hidden
    case available
    /// The session being recorded right now: "Available when the call ends".
    case recording
    /// A meeting or call whose transcript is missing or empty.
    case noTranscript

    var isAvailable: Bool { self == .available }

    /// `rows` is the number of transcript rows, nil while they are not read yet (the file's presence decides until then).
    static func of(_ session: HomeSession, recordingSession: String?, rows: Int?) -> AskAvailability {
        guard session.kind == .meeting || session.kind == .call else { return .hidden }
        if let recordingSession, recordingSession == session.name { return .recording }
        if session.transcriptURL == nil { return .noTranscript }
        if let rows, rows == 0 { return .noTranscript }
        return .available
    }
}

// MARK: - The session

/// The state of one open Ask panel: the conversation, the brain process behind it, and the cost of this opening.
@MainActor
final class AskSession: ObservableObject {
    /// The turns on screen: the history after the last reset, then this opening's questions.
    @Published private(set) var turns: [ChatTurn] = []
    /// A question is out and its answer (or error) has not come back.
    @Published private(set) var isBusy = false
    /// A problem that belongs to the panel rather than to one question (the brain would not start).
    @Published private(set) var notice: ChatFailure?
    /// Tokens of the grounding block as the brain counted them, once it reported ready.
    @Published private(set) var contextTokens: Int?
    @Published var model: AskModel

    /// Starts the brain process (already running, with its stdin open). Throwing means "could not start".
    var makeBrain: () throws -> any SimBrainTransport
    /// How long the process may sit without a question before it is stopped.
    var idleInterval: Duration
    /// False in renders: the panel shows what is on disk and never starts a process.
    var launchesBrain = true
    /// Writes the cost of this opening into the `spend.json` of the session folder, or of `memory/` in the memory scopes (a run of kind `ask`).
    var recordSpend: (URL, Date, Double) -> Void = { dir, startedAt, cost in
        SpendLedger.record(sessionDir: dir, startedAt: startedAt, costUSD: cost, kind: "ask")
    }
    var now: () -> Date = { Date() }

    /// What the panel is open on; nil when it is closed.
    private(set) var target: AskTarget?
    /// The session's context when the panel is open on one meeting.
    var context: AskContext? { if case .session(let c) = target { c } else { nil } }
    /// The memory scope's context when the panel is open on a person, a company or every meeting.
    var memoryContext: MemoryAskContext? { if case .memory(let c) = target { c } else { nil } }
    private var brain: (any SimBrainTransport)?
    private var reader: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var openedAt: Date?
    private var openCost = 0.0
    private var nextIndex = 1
    private var lastStatusError: String?
    /// How many times a brain process was started by this session (tests).
    private(set) var startCount = 0

    init(model: AskModel = .sonnet, idleInterval: Duration = .seconds(600), makeBrain: @escaping () throws -> any SimBrainTransport) {
        self.model = model
        self.idleInterval = idleInterval
        self.makeBrain = makeBrain
    }

    var isOpen: Bool { target != nil }
    var isRunning: Bool { brain != nil }

    /// "This chat": what the answers on screen cost.
    var chatCost: Double { turns.reduce(0) { $0 + $1.cost } }

    // MARK: open and close

    /// Shows the history and starts the brain (spec: started when the panel opens).
    func open(_ ctx: AskContext) { open(.session(ctx)) }

    /// A memory scope: the same, with the chat file and the spend record of the memory folder. `launch: false` shows the history and
    /// waits (the caller syncs the index first and then calls `launchIfOpen()`).
    func open(_ ctx: MemoryAskContext, launch: Bool = true) { open(.memory(ctx), launch: launch) }

    func open(_ t: AskTarget, launch: Bool = true) {
        if target != nil { close() }
        target = t
        let loaded = ChatLog.load(url: t.chatURL)
        turns = loaded.turns
        nextIndex = loaded.nextIndex
        isBusy = false
        notice = nil
        contextTokens = nil
        lastStatusError = nil
        openedAt = now()
        openCost = 0
        if launchesBrain, launch { _ = ensureRunning() }
        touch()
    }

    /// Starts the brain of an open panel that waited for the index to sync.
    func launchIfOpen() {
        guard target != nil, launchesBrain else { return }
        _ = ensureRunning()
        touch()
    }

    /// Ends the process and forgets the context. The chat file stays.
    func close() {
        stopBrain()
        idleTask?.cancel()
        idleTask = nil
        target = nil
        isBusy = false
    }

    private func stopBrain() {
        reader?.cancel()
        reader = nil
        if let b = brain {
            brain = nil
            Task { await b.close() }
        }
    }

    // MARK: asking

    /// Sends a question. Ignored while an answer is out, for an empty text, and when the panel is not open.
    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, target != nil else { return }
        ask(text, replacing: nil)
    }

    /// Asks the question of a failed turn again; the failed one leaves the screen.
    func retry(_ turnID: String) {
        guard !isBusy, target != nil, let t = turns.first(where: { $0.id == turnID && $0.phase == .failed }) else { return }
        ask(t.question, replacing: turnID)
    }

    private func ask(_ text: String, replacing old: String?) {
        if let old { turns.removeAll { $0.id == old } }
        let id = "q\(nextIndex)"
        nextIndex += 1
        turns.append(ChatTurn(id: id, question: text, model: model.rawValue, phase: .waiting))
        isBusy = true
        notice = nil
        guard launchesBrain else { return }
        guard ensureRunning() else {
            fail(question: id, ChatFailure(kind: "error", message: notice?.message ?? ""))
            return
        }
        brain?.send(AskWire.askLine(id: id, text: text, model: model))
        touch()
    }

    /// Stops the answer that is streaming; the brain finishes it with `stop_reason: cancelled` and the cost so far.
    func cancel() {
        guard isBusy else { return }
        brain?.send(AskWire.control("cancel"))
    }

    /// "Clear chat": the brain appends a `reset` line to `chat.jsonl`, the screen empties. Nothing is deleted.
    func clearChat() {
        guard target != nil else { return }
        turns = []
        isBusy = false
        notice = nil
        guard launchesBrain, ensureRunning() else { return }
        brain?.send(AskWire.control("reset"))
        touch()
    }

    // MARK: process

    @discardableResult
    private func ensureRunning() -> Bool {
        if brain != nil { return true }
        guard let t = target else { return false }
        do {
            let b = try makeBrain()
            brain = b
            startCount += 1
            lastStatusError = nil
            startReader(b)
            b.send(t.startLine(model: model))
            return true
        } catch {
            notice = ChatFailure(kind: "start_failed", message: "\(error)")
            return false
        }
    }

    private func startReader(_ b: any SimBrainTransport) {
        reader?.cancel()
        reader = Task { @MainActor [weak self] in
            for await line in b.lines {
                guard let self, !Task.isCancelled else { return }
                if let e = AskEvent.parse(line) { self.handle(e) }
            }
            self?.brainEnded(b)
        }
    }

    private func brainEnded(_ b: any SimBrainTransport) {
        guard let current = brain, current === b else { return }
        brain = nil
        reader = nil
        // The process left while a question was out (or never became ready): say so on that question.
        if isBusy, let last = turns.last(where: { $0.phase == .waiting || $0.phase == .streaming }) {
            let keyMissing = lastStatusError?.localizedCaseInsensitiveContains("keychain") ?? false
            fail(question: last.id, ChatFailure(kind: keyMissing ? "key_missing" : "error", message: lastStatusError ?? ""))
        } else if let e = lastStatusError {
            notice = ChatFailure(kind: e.localizedCaseInsensitiveContains("keychain") ? "key_missing" : "error", message: e)
        }
    }

    // MARK: events

    func handle(_ e: AskEvent) {
        switch e {
        case .status(let state, let message, let tokens, _):
            if state == "ready" { contextTokens = tokens ?? contextTokens; lastStatusError = nil }
            if state == "error" || state == "credit_exhausted" || state == "offline" { lastStatusError = message }
        case .delta(let q, let text):
            guard let i = turns.firstIndex(where: { $0.id == q }) else { return }
            turns[i].partial += text
            turns[i].phase = .streaming
            touch()
        case .done(let d):
            isBusy = false
            openCost += d.costUSD
            if let t = target, let at = openedAt, d.costUSD > 0 { recordSpend(t.spendDir, at, openCost) }
            if let i = turns.firstIndex(where: { $0.id == d.question }) {
                turns[i].answer = ChatAnswer(id: d.answerID, text: turns[i].partial, model: d.model, usage: d.usage, costUSD: d.costUSD,
                                             costEstimated: d.costEstimated, msFirstToken: d.msFirstToken, msTotal: d.msTotal,
                                             citations: d.citations, stopReason: d.stopReason, sources: d.sources, excerptTokens: d.excerptTokens)
                turns[i].phase = .answered
                turns[i].failure = nil
            }
            touch()
        case .error(let q, let failure):
            fail(question: q, failure)
        }
    }

    private func fail(question q: String, _ failure: ChatFailure) {
        isBusy = false
        if let i = turns.firstIndex(where: { $0.id == q }) {
            turns[i].failure = failure
            turns[i].phase = .failed
        }
        touch()
    }

    // MARK: idle

    /// Re-arms the idle timer; the process stops after `idleInterval` without activity and starts again on the next question.
    private func touch() {
        idleTask?.cancel()
        guard target != nil, brain != nil else { return }
        let interval = idleInterval
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.idleStop()
        }
    }

    private func idleStop() {
        if isBusy { touch(); return }
        stopBrain()
    }
}
