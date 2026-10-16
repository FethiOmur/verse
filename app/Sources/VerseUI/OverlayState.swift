import Foundation
import VerseTurns

/// A fact chip on the card: `€42K budget · prep note`.
public struct OverlayChip: Equatable, Sendable, Identifiable {
    public var id: String { text }
    public var text: String
    /// Where it comes from, for the second half of the chip ("prep note", "glossary", "vault", "commit").
    public var source: String
    public var kind: String

    public init(text: String, source: String, kind: String) {
        self.text = text
        self.source = source
        self.kind = kind
    }

    /// `prep:L13` -> "prep note", a glossary term -> "glossary".
    static func sourceLabel(kind: String, ref: String) -> String {
        if kind == "term" { return "glossary" }
        let prefix = ref.split(separator: ":").first.map(String.init) ?? ref
        switch prefix {
        case "prep": return "prep note"
        case "vault": return "vault"
        case "commit": return "commit"
        case "me": return "my profile"
        case "": return "notes"
        default: return prefix
        }
    }
}

/// The question card under the notch.
public struct OverlayCard: Equatable, Sendable {
    public var turnID: String
    public var question: String
    /// The line to say first (P opener, then the selected S or the F answer). nil until something arrives.
    public var say: String?
    /// Which tier the SAY line came from: "P", "S", "F", "D" (corrected) or "C" (follow card).
    public var sayTier: String?
    /// D said the shown opener was wrong; `say` is D's first line now.
    public var sayCorrected = false
    /// Up to 3 points under the SAY line.
    public var bullets: [String] = []
    public var chips: [OverlayChip] = []
    /// Sonnet's detail points, under the divider.
    public var deepPoints: [String] = []
    /// "Follow my answer": Alex went his own way and `say`/`bullets` are the C tier's continuation of his line, not the
    /// answer to the question. The view marks the card "following you".
    public var following = false
    /// Indices into `bullets` that Alex has already said (the brain's `covered`); the view strikes them through.
    public var struck: Set<Int> = []

    public init(turnID: String, question: String) {
        self.turnID = turnID
        self.question = question
    }

    public var isEmpty: Bool { say == nil && bullets.isEmpty && chips.isEmpty && deepPoints.isEmpty }
}

/// The status chip in the capsule.
public enum OverlayStatus: Equatable, Sendable {
    case offline
    case rateLimited
    case creditExhausted(String)
    case restarting
    case error(String)
    /// Audio recording ("audioCapture") or microphone permission is missing; the overlay offers System Settings.
    case permission(String)
    /// ⌥⌘V was pressed once while a session runs: "Press ⌥⌘V again to stop" for `StopConfirm.window` seconds.
    case stopConfirm
    /// The brain could not find the "me" profile files: the session runs without them (`notice{kind:"me_missing"}`).
    case meMissing

    /// The short text in the capsule chip.
    public var title: String {
        switch self {
        case .offline: return "Offline"
        case .rateLimited: return "Rate limited"
        case .creditExhausted: return "Max API credit used up"
        case .restarting: return "Restarting"
        case .error: return "Error"
        case .permission(let k): return k == "microphone" ? "Microphone access needed" : "Audio recording access needed"
        case .stopConfirm: return "Press ⌥⌘V again to stop"
        case .meMissing: return "Your profile was not found"
        }
    }

    /// The few words that fit the capsule's wing.
    public var shortTitle: String {
        switch self {
        case .offline: return "Offline"
        case .rateLimited: return "Rate limited"
        case .creditExhausted: return "No credit"
        case .restarting: return "Restarting"
        case .error: return "Error"
        case .permission: return "Needs access"
        case .stopConfirm: return "Stop?"
        case .meMissing: return "No profile"
        }
    }

    /// The longer explanation, when there is one.
    public var detail: String? {
        switch self {
        case .creditExhausted(let m), .error(let m): return m.isEmpty ? nil : m
        case .permission(let k):
            return k == "microphone"
                ? "Verse needs the microphone to hear your side of the call. Allow it in System Settings, then press Start again."
                : "Verse needs System Audio Recording to hear the meeting app. Allow it in System Settings, then press Start again."
        case .restarting: return "The brain stopped; restarting it once."
        case .stopConfirm: return "Verse keeps listening if you don't."
        case .meMissing: return "Verse answers without it. Build it on the Me page."
        default: return nil
        }
    }

    /// Statuses that need a bigger message than the capsule chip.
    public var needsPanel: Bool {
        switch self {
        case .permission, .creditExhausted, .error, .stopConfirm, .meMissing: return true
        default: return false
        }
    }
}

/// What the capsule dot says.
public enum OverlayActivity: String, Equatable, Sendable {
    /// No session running.
    case idle
    case warming
    case listening
    /// A question for the owner is being answered and nothing is visible yet.
    case thinking
    case offline
}

/// Everything the overlay draws. Pure value; `OverlayReducer` changes it.
public struct OverlayState: Equatable, Sendable {
    public var running = false
    public var lang = "en"
    public var activity = OverlayActivity.idle
    /// `for you`, `for Marco`; nil when the last question was for nobody in particular.
    public var addresseeTag: String?
    /// The tag names someone else (shown dimmed, no SAY line).
    public var tagDimmed = false
    public var status: OverlayStatus?
    public var card: OverlayCard?
    /// Topic chips (F4, `chip` with `kind:"topic"`) while no card is open: a slim row under the capsule.
    public var topics: [OverlayChip] = []
    /// The start-up panel under the capsule (Starting… → Ready → Listening). nil once the first card opened or the
    /// user collapsed it.
    public var startup: StartupPanel?
    /// A practice interview is running (S4): the capsule shows its progress and the panel under it its line,
    /// controls and coach notes. nil in meetings.
    public var sim: SimOverlay?
    /// The last run was a practice interview: its error message offers no Retry (that would start a meeting).
    public var practiceEnded = false
    /// A question under the notch with two buttons: "Meeting detected · Start Verse?" before a session, "Save summary to
    /// the vault?" after one. Set by `MeetingCoordinator`, never by runner events.
    public var meetingPrompt: MeetingPrompt?
    /// Level bars on the island (UI redesign spec 3.2): the last three levels, 0...1, newest last, of the meeting's audio
    /// (`remoteBars`) and of my microphone (`meBars`). About ten samples a second, so three bars are the last 300 ms.
    public var remoteBars: [Double] = [0, 0, 0]
    public var meBars: [Double] = [0, 0, 0]
    /// The meeting's audio was audible within `audibleHold` seconds: the idle capsule widens to the listening one.
    public var remoteSpeaking = false
    /// Anytime calls: where the running session listens (nil for a session started the old way, from a meeting prompt).
    public var route: AudioRoute?
    /// An adhoc session: no meeting pack. The island's right wing says "Unprepared".
    public var unprepared = false

    public init() {}

    /// `en · for you`, or `practice · Q3/8` during a practice interview.
    public var capsuleTag: String {
        if let sim { return sim.capsuleTag }
        return [lang, addresseeTag].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The persistent panel after Start: what Verse is doing before the first question.
public struct StartupPanel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Brain warming / models loading; `step` says which.
        case starting(step: String)
        /// Brain ready and the listen session is up.
        case ready
        /// The meeting app's audio is being transcribed.
        case listening
    }
    public var phase: Phase
    public var session: String
    /// The meeting app being listened to ("Comet"); nil when none of the known apps is running.
    public var app: String?
    /// The recognizer has produced text from the meeting's audio (separate from `.listening`, which follows the sound).
    public var transcribing = false
    /// Anytime calls: the route this session listens on. Non-nil makes the panel the start card, with the route and
    /// language chips (spec 2.1).
    public var route: AudioRoute?
    /// The session language, for the start card's language chips.
    public var lang = "en"

    public init(phase: Phase, session: String, app: String?, transcribing: Bool = false, route: AudioRoute? = nil, lang: String = "en") {
        self.phase = phase
        self.session = session
        self.app = app
        self.transcribing = transcribing
        self.route = route
        self.lang = lang
    }

    /// The start card of an anytime session (route and language chips) rather than the plain start-up panel.
    public var isStartCard: Bool { route != nil }

    public var title: String {
        if isStartCard {
            switch phase {
            case .starting: return "Starting…"
            case .ready: return "Ready"
            case .listening: return "Listening"
            }
        }
        switch phase {
        case .starting: return "Starting…"
        case .ready: return "Ready · \(session)"
        case .listening: return "Listening · \(session)"
        }
    }

    public var subtitle: String {
        switch phase {
        case .starting(let step): return step
        case .ready:
            switch route {
            case .room?: return "listening through the microphone"
            case .phone?: return "listening to the phone call"
            default: return app.map { "listening to \($0)" } ?? "waiting for the meeting app's audio"
            }
        case .listening:
            let hearing: String
            switch route {
            case .room?: hearing = "hearing the room"
            case .phone?: hearing = "hearing the call"
            default: hearing = app.map { "hearing \($0)" } ?? "hearing the meeting"
            }
            return transcribing ? hearing + " · transcribing" : hearing
        }
    }
}

/// Settings the reducer needs.
public struct OverlayConfig: Equatable, Sendable {
    /// Seconds without new content after which the card collapses to the capsule. `.infinity` (the default): never;
    /// the card stays until the next card replaces it or the user dismisses it.
    public var cardTimeout: TimeInterval = .infinity
    /// Other participants, to name them in the capsule tag (`for Marco`).
    public var otherNames: [String] = []
    public var maxBullets = 3
    public var maxDeepPoints = 4
    /// Topic chips (no question card open) fade after this many seconds. They are hints, not answers, so they never
    /// follow `cardTimeout` (whose default is "never").
    public var topicTimeout: TimeInterval = 15
    /// The meeting's audio counts as sound above this level (dBFS over the last 200 ms; speech through the tap sits far
    /// above, digital silence reads as nil). The "Listening" label follows it.
    public var audibleDbfs: Double = -50
    /// The label goes back to "Ready" after this many seconds without sound.
    public var audibleHold: TimeInterval = 2.5

    public init(cardTimeout: TimeInterval = .infinity, otherNames: [String] = []) {
        self.cardTimeout = cardTimeout
        self.otherNames = otherNames
    }
}

/// The bank entries the overlay can show at once on a hit (P tier).
public struct BankOpener: Equatable, Sendable {
    public var opener: String
    public var points: [String]

    public init(opener: String, points: [String]) {
        self.opener = opener
        self.points = points
    }

    /// Reads `<session>/bank.jsonl` for the overlay: id -> opener + points.
    public static func load(sessionDir: URL) -> [String: BankOpener] {
        let url = sessionDir.appendingPathComponent("bank.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: BankOpener] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let o = JSONValue.decodeObject(String(line)), let id = o[string: "id"], let opener = o[string: "opener"] else { continue }
            out[id] = BankOpener(opener: opener, points: o["points"]?.array?.compactMap(\.string) ?? [])
        }
        return out
    }
}

/// The overlay state machine (plan P1-5): runner events in, `OverlayState` out. No clock of its own: `now` comes
/// with every call, so tests drive time.
public struct OverlayReducer: Sendable {
    public private(set) var state = OverlayState()
    public var config: OverlayConfig
    public var bank: [String: BankOpener]

    /// Streamed text per call id: finished lines and the line being written.
    private struct Lines: Sendable {
        var tier: String
        var turnID: String
        var done: [String] = []
        var current = ""
        var all: [String] { current.isEmpty ? done : done + [current] }
    }

    /// What is known about a turn before (and after) its card exists.
    private struct TurnInfo: Sendable {
        /// The bank entry to show as the P opener: Swift's n-gram hit (outbound) or the brain's paraphrase hit
        /// (`bank_hit` with `via:"embed"`), whichever came last.
        var bankHit: String?
        /// Entries Haiku's `BANK:` check disagreed with (`bank_verdict agree:false`): never shown for this turn.
        var rejectedBankIDs: Set<String> = []
        var chips: [OverlayChip] = []
        var selectedS: String?
        var fID: String?
        var dID: String?
        var openerOK: Bool?
        /// Follow my answer: the newest follow card the brain announced for this turn (`follow.card_id`) ...
        var followCardID: String?
        /// ... the newest one that already has a SAY line (the card keeps showing the previous follow card, or the
        /// original, until the new one has something to show) ...
        var shownFollowID: String?
        /// ... every follow card id announced for the turn (the rest of `covered` belongs to the original card) ...
        var followIDs: Set<String> = []
        /// ... and the points Alex covered, by card id (`covered.card_id` -> point indices).
        var covered: [String: Set<Int>] = [:]

        /// A new remote question: nothing of the follow state carries over.
        mutating func endFollow() {
            followCardID = nil
            shownFollowID = nil
            followIDs = []
            covered = [:]
        }
    }

    private var lines: [String: Lines] = [:]
    private var turns: [String: TurnInfo] = [:]
    /// Remote `statement` turns not addressed to someone else, by turn id: (text, addressee). The brain may still
    /// answer one as a question; its first S/F SAY line then opens the card.
    private var statements: [String: (text: String, addressee: String)] = [:]
    /// The newest remote turn: only that one may open a card late.
    private var lastRemoteTurnID: String?
    /// What the other side said last (the open partial, else the last final): the question a card-now answer is for.
    private var lastHeard = ""
    private var lastContent: TimeInterval = 0
    /// When each topic chip (by text) was last seen.
    private var topicSeen: [String: TimeInterval] = [:]
    /// The turn each topic chip (by text) came from, so a bank hit in that turn can take it down again.
    private var topicTurn: [String: String] = [:]
    /// When the meeting's audio was last above `config.audibleDbfs` (or text from it arrived).
    private var lastAudible: TimeInterval = -.infinity

    public init(config: OverlayConfig = OverlayConfig(), bank: [String: BankOpener] = [:]) {
        self.config = config
        self.bank = bank
    }

    public mutating func reset(lang: String) {
        state = OverlayState()
        state.lang = lang
        lines = [:]
        turns = [:]
        statements = [:]
        lastRemoteTurnID = nil
        lastHeard = ""
        topicSeen = [:]
        topicTurn = [:]
        lastAudible = -.infinity
    }

    // MARK: events

    public mutating func apply(_ e: RunnerEvent, now: TimeInterval) {
        switch e {
        case .brain(let o): applyBrain(o, now: now)
        case .chip(let o): applyChip(o, now: now)
        case .outbound(let o): applyOutbound(o, now: now)
        case .status(let st, let m): applyStatus(st, message: m)
        case .issue(let code, let m):
            if code == "permission_denied" { state.status = .permission(m.contains("microphone") ? "microphone" : "audioCapture") }
        case .level(let remote, let me): applyLevel(remoteDbfs: remote, meDbfs: me, now: now)
        case .metric(let o):
            if o[string: "stage"] == "session_t0" {
                state.running = true
                if state.activity == .idle || state.activity == .warming { state.activity = .listening }
                if state.startup != nil { state.startup?.phase = .ready }
            }
        case .ended(let code):
            state.running = false
            state.activity = .idle
            state.card = nil
            state.topics = []
            state.startup = nil
            state.addresseeTag = nil
            state.tagDimmed = false
            state.remoteSpeaking = false
            state.remoteBars = [0, 0, 0]
            state.meBars = [0, 0, 0]
            if code != 0, state.status == nil { state.status = .error("The session ended with an error.") }
            if code == 0, state.status == .restarting || state.status == .offline || state.status == .rateLimited { state.status = nil }
        }
    }

    /// Collapses a card that has had no new content for `cardTimeout`.
    public mutating func tick(now: TimeInterval) {
        if state.remoteSpeaking, now - lastAudible >= config.audibleHold {
            state.remoteSpeaking = false
            state.remoteBars = [0, 0, 0]
        }
        if state.card != nil, now - lastContent >= config.cardTimeout {
            state.card = nil
            if state.activity == .thinking { state.activity = .listening }
        }
        if !state.topics.isEmpty {
            state.topics.removeAll { now - (topicSeen[$0.text] ?? now) >= config.topicTimeout }
            topicSeen = topicSeen.filter { now - $0.value < config.topicTimeout }
        }
    }

    /// Marks the start of a session (Start pressed): the capsule shows warming until the brain is ready, and the
    /// start-up panel stays open until the first card or until the user collapses it.
    public mutating func sessionStarting(lang: String, session: String = "", app: String? = nil, route: AudioRoute? = nil,
                                         unprepared: Bool = false) {
        reset(lang: lang)
        state.running = true
        state.activity = .warming
        state.route = route
        state.unprepared = unprepared
        state.startup = StartupPanel(phase: .starting(step: "Starting the brain and loading models"), session: session, app: app,
                                     route: route, lang: lang)
    }

    /// A mid-call route or language switch: the labels follow, nothing else moves. The open card, the topic chips and what the
    /// reducer remembers of the turns belong to the call, which goes on.
    public mutating func listeningChanged(route: AudioRoute, lang: String, app: String?) {
        state.route = route
        state.lang = lang
        guard state.startup != nil else { return }
        state.startup?.route = route
        state.startup?.lang = lang
        state.startup?.app = app
    }

    /// The user collapsed the open panel or card (click on the capsule).
    public mutating func collapse() {
        if state.card != nil {
            state.card = nil
            if state.activity == .thinking { state.activity = .listening }
        } else if !state.topics.isEmpty {
            state.topics = []
            topicSeen = [:]
        } else {
            state.startup = nil
        }
    }

    private mutating func touch(_ now: TimeInterval) { lastContent = now }

    mutating func setStatus(_ s: OverlayStatus?) { state.status = s }

    mutating func setPrompt(_ p: MeetingPrompt?) { state.meetingPrompt = p }

    private mutating func applyStatus(_ st: String, message: String) {
        switch st {
        case "warming": state.activity = .warming
        case "ready":
            if case .starting? = state.startup?.phase { state.startup?.phase = .starting(step: "Brain ready · starting speech recognition") }
            if state.activity == .warming || state.activity == .offline || state.activity == .idle { state.activity = .listening }
            if state.status == .offline || state.status == .rateLimited || state.status == .restarting { state.status = nil }
        case "offline":
            state.status = .offline
            state.activity = .offline
        case "rate_limited": state.status = .rateLimited
        case "credit_exhausted": state.status = .creditExhausted(message)
        case "refusal": break   // the fast tiers show nothing; D still answers
        case "restarting": state.status = .restarting
        case "error": state.status = .error(message)
        case "permission_denied": state.status = .permission(message)
        case "listen_failed": state.status = .error(message)
        default: break
        }
    }

    /// Raw level of the meeting's audio (about ten a second): the start-up panel says "Listening" while there is sound,
    /// within a poll or two of it starting, and "Ready" again after `audibleHold` without. The text signal
    /// (`transcribing`) is separate and arrives later.
    private mutating func applyLevel(remoteDbfs: Double?, meDbfs: Double?, now: TimeInterval) {
        state.remoteBars = Array((state.remoteBars + [Self.barLevel(remoteDbfs)]).suffix(3))
        state.meBars = Array((state.meBars + [Self.barLevel(meDbfs)]).suffix(3))
        if let db = remoteDbfs, db > config.audibleDbfs { lastAudible = now }
        let speaking = now - lastAudible < config.audibleHold
        if state.remoteSpeaking != speaking {
            state.remoteSpeaking = speaking
            if !speaking { state.remoteBars = [0, 0, 0] }
        }
        guard case .some(let panel) = state.startup else { return }
        if case .starting = panel.phase { return }
        if let db = remoteDbfs, db > config.audibleDbfs {
            lastAudible = now
            if panel.phase == .ready { state.startup?.phase = .listening }
        } else if panel.phase == .listening, lastAudible.isFinite, now - lastAudible >= config.audibleHold {
            state.startup?.phase = .ready
            state.startup?.transcribing = false
        }
    }

    /// -60 dBFS (and nil: no signal) is an empty bar, -20 dBFS and above a full one.
    static func barLevel(_ dbfs: Double?) -> Double {
        guard let db = dbfs else { return 0 }
        return min(1, max(0, (db + 60) / 40))
    }

    /// The other side of the call: `remote` in a meeting, `room` on the room route (the one microphone, nobody told apart).
    private static func isOtherSide(_ speaker: String?) -> Bool { speaker == "remote" || speaker == "room" }

    /// Card-now answers (⌥⌘↩) come as plain deltas on a turn id `now-<n>` for which no `turn` was ever sent.
    private static func isNowTurn(_ id: String) -> Bool { id.hasPrefix("now-") }

    private mutating func applyOutbound(_ o: [String: JSONValue], now: TimeInterval) {
        if (o.type == "partial" || o.type == "turn"), Self.isOtherSide(o[string: "speaker"]), let text = o[string: "text"], !text.isEmpty {
            lastHeard = text
        }
        if (o.type == "partial" || o.type == "turn"), Self.isOtherSide(o[string: "speaker"]), state.startup != nil {
            // The meeting app's audio is being transcribed (text implies sound: the label stays on for the hold time).
            if state.startup?.phase == .ready { state.startup?.phase = .listening }
            if state.startup?.phase == .listening { state.startup?.transcribing = true }
            lastAudible = now
        }
        guard let tid = o[string: "turn_id"] else { return }
        switch o.type {
        case "bank_hit":
            guard let bid = o[string: "bank_id"] else { return }
            turns[tid, default: TurnInfo()].bankHit = bid
            bankHitLanded(turnID: tid, now: now)
        case "turn":
            guard Self.isOtherSide(o[string: "speaker"]) else { return }
            let who = o[string: "addressee"] ?? "unknown"
            let kind = o[string: "kind"] ?? "question"
            let text = o[string: "text"] ?? ""
            lastRemoteTurnID = tid
            if who == "other" {
                state.addresseeTag = "for " + (otherName(in: text) ?? "someone else")
                state.tagDimmed = true
                return
            }
            guard kind == "question" else {
                // A statement or a fragment waits: the brain answers it when a prepared question matched it (its bank
                // hit), or when it takes a statement as a question. Nothing else opens a card for it.
                statements[tid] = (text, who)
                if turns[tid]?.bankHit != nil { openCard(turnID: tid, question: text, addressee: who, now: now) }
                return
            }
            openCard(turnID: tid, question: text, addressee: who, now: now)
        default:
            break
        }
    }

    private mutating func openCard(turnID tid: String, question: String, addressee who: String, now: TimeInterval) {
        statements[tid] = nil
        // A new remote question ends follow mode for the card it replaces.
        if let previous = state.card?.turnID, previous != tid { turns[previous]?.endFollow() }
        state.addresseeTag = who == "me" ? "for you" : nil
        state.tagDimmed = false
        state.card = OverlayCard(turnID: tid, question: question)
        if state.status == .meMissing { state.status = nil }
        state.startup = nil
        state.topics = []
        topicSeen = [:]
        state.activity = .thinking
        touch(now)
        refreshCard(now: now)
    }

    /// A statement the brain answers anyway: an S or F stream with a complete `SAY:` prefix means it took the turn
    /// as a question. Only the newest remote turn qualifies, so a late answer never takes over a newer card.
    private mutating func openReclassifiedStatement(turnID tid: String, tier: String, lines l: Lines, now: TimeInterval) {
        guard state.card?.turnID != tid, tid == lastRemoteTurnID, let st = statements[tid],
              tier == "S" || tier == "F",
              l.all.contains(where: { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("SAY:") && !ModelLine.isSentinel(t) }) else { return }
        openCard(turnID: tid, question: st.text, addressee: st.addressee, now: now)
    }

    private func otherName(in text: String) -> String? {
        let words = Set(text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        return config.otherNames.first { name in
            let parts = name.lowercased().split(separator: " ").map(String.init)
            return !parts.isEmpty && parts.allSatisfy { words.contains($0) }
        }
    }

    /// A bank entry matched the turn (the engine's n-gram hit or the brain's paraphrase hit). The brain answers a turn
    /// with a hit whatever Swift called it, so a statement or fragment that is still waiting (the hit came after the turn
    /// closed) opens its card now, the newest turn only. The turn's topic chips go: it has an answer of its own.
    private mutating func bankHitLanded(turnID tid: String, now: TimeInterval) {
        let gone = state.topics.filter { topicTurn[$0.text] == tid }.map(\.text)
        if !gone.isEmpty {
            state.topics.removeAll { gone.contains($0.text) }
            for t in gone { topicSeen[t] = nil; topicTurn[t] = nil }
        }
        if state.card?.turnID != tid, tid == lastRemoteTurnID, let st = statements[tid] {
            openCard(turnID: tid, question: st.text, addressee: st.addressee, now: now)
        } else if state.card?.turnID == tid {
            refreshCard(now: now)
        }
    }

    private mutating func applyChip(_ o: [String: JSONValue], now: TimeInterval) {
        guard let tid = o[string: "turn_id"], let text = o[string: "text"], !text.isEmpty else { return }
        let kind = o[string: "kind"] ?? ""
        // A turn with a bank hit has its answer: a topic chip that was already on its way is dropped.
        if kind == "topic", turns[tid]?.bankHit != nil { return }
        let chip = OverlayChip(text: text, source: OverlayChip.sourceLabel(kind: kind, ref: o[string: "source_ref"] ?? ""), kind: kind)
        if kind == "topic", state.card == nil || state.card?.turnID != tid {
            // A topic can come up with no question card open: it goes to the slim row under the capsule.
            topicSeen[text] = now
            topicTurn[text] = tid
            if !state.topics.contains(where: { $0.text == text }) { state.topics.append(chip) }
            return
        }
        var info = turns[tid, default: TurnInfo()]
        if !info.chips.contains(where: { $0.text == chip.text }) { info.chips.append(chip) }
        turns[tid] = info
        if state.card?.turnID == tid { refreshCard(now: now) }
    }

    private mutating func applyBrain(_ o: [String: JSONValue], now: TimeInterval) {
        switch o.type {
        case "bank_hit":
            // The brain's paraphrase matcher (F3): shown exactly like Swift's n-gram hit.
            guard let tid = o[string: "turn_id"], let bid = o[string: "bank_id"] else { return }
            turns[tid, default: TurnInfo()].bankHit = bid
            bankHitLanded(turnID: tid, now: now)
        case "delta":
            guard let id = o[string: "id"], let tid = o[string: "turn_id"], let tier = o[string: "tier"] else { return }
            // A C line belongs to a follow card: it is kept by that card's id, apart from the original card's lines.
            let key = tier == "C" ? Self.followKey(o[string: "card_id"] ?? id) : id
            var l = lines[key] ?? Lines(tier: tier, turnID: tid)
            l.current += o[string: "text"] ?? ""
            if o[bool: "line_done"] == true {
                let s = l.current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { l.done.append(s) }
                l.current = ""
            }
            lines[key] = l
            // The first delta of a card-now turn opens its card, for what the other side said last. A card the user closed
            // stays closed: later deltas of that turn find the turn known.
            let opensNowCard = Self.isNowTurn(tid) && turns[tid] == nil && state.card?.turnID != tid
            var info = turns[tid, default: TurnInfo()]
            if tier == "F", info.fID == nil { info.fID = id }
            if tier == "D", info.dID == nil { info.dID = id }
            turns[tid] = info
            if opensNowCard {
                lastRemoteTurnID = tid
                openCard(turnID: tid, question: lastHeard, addressee: "me", now: now)
            }
            openReclassifiedStatement(turnID: tid, tier: tier, lines: l, now: now)
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "select":
            guard let tid = o[string: "turn_id"], let id = o[string: "id"] else { return }
            turns[tid, default: TurnInfo()].selectedS = id
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "opener_status":
            guard let tid = o[string: "turn_id"] else { return }
            turns[tid, default: TurnInfo()].openerOK = o[bool: "ok"]
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "bank_verdict":
            guard let tid = o[string: "turn_id"], o[bool: "agree"] == false else { return }
            var info = turns[tid, default: TurnInfo()]
            if let bid = o[string: "bank_id"] ?? info.bankHit { info.rejectedBankIDs.insert(bid) }
            turns[tid] = info
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "follow":
            // Alex left the card: a new card version (the C deltas of `card_id`) replaces the visible text. Only the open
            // card's turn counts; a late message for an earlier question changes nothing.
            guard let tid = o[string: "turn_id"], let cid = o[string: "card_id"], !cid.isEmpty, state.card?.turnID == tid else { return }
            var info = turns[tid, default: TurnInfo()]
            info.followCardID = cid
            info.followIDs.insert(cid)
            turns[tid] = info
            refreshCard(now: now)
        case "covered":
            guard let tid = o[string: "turn_id"], let cid = o[string: "card_id"], let p = o[double: "point"], p >= 0, p < 1000,
                  state.card?.turnID == tid else { return }
            turns[tid, default: TurnInfo()].covered[cid, default: []].insert(Int(p))
            refreshCard(now: now)
        case "status":
            applyStatus(o[string: "state"] ?? "", message: o[string: "message"] ?? "")
        case "notice":
            // `me_missing`: the profile files named in `start` do not exist. A status that never covers a card (openCard
            // takes it down). The other notice (`me_conflicts`) is for the Me page, not the island.
            if o[string: "kind"] == "me_missing", state.status == nil { state.status = .meMissing }
        default:
            break   // unknown message types (and unknown fields) are ignored
        }
    }

    private static func followKey(_ cardID: String) -> String { "C|" + cardID }

    // MARK: card assembly

    /// One display line: SAY or a point. Streaming lines that are still only "SAY" / "-" show nothing yet.
    private enum Line { case say(String), point(String) }

    private static func parse(_ raw: String) -> Line? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if ModelLine.isSentinel(s) { return nil }      // "NONE", "SAY: NONE", "- none": never on a card
        if s.hasPrefix("SAY:") {
            let body = s.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : .say(body)
        }
        if "SAY:".hasPrefix(s) { return nil }
        if s.hasPrefix("-") || s.hasPrefix("•") {
            let body = s.dropFirst().trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : .point(body)
        }
        return s.isEmpty ? nil : .point(s)
    }

    /// A displayed point and its number for `covered`. The brain numbers the lines that start with `- ` (dash and space), 0-based,
    /// in arrival order on one card; a second SAY line, a line with no dash or a `•` line may still be shown (the display is
    /// tolerant) but has no number, so a `covered` index can never land on it.
    private struct Item { var text: String; var point: Int? }

    private static func isNumbered(_ raw: String) -> Bool { raw.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }

    /// SAY line and displayed points of one streamed call: the first SAY line, then every other line, each point with the
    /// brain's number when it has one.
    private static func parseLines(_ l: Lines?) -> (say: String?, items: [Item]) {
        var say: String?, items: [Item] = [], n = 0
        for raw in l?.all ?? [] {
            switch parse(raw) {
            case .say(let s)?:
                if say == nil { say = s } else { items.append(Item(text: s, point: nil)) }
            case .point(let p)?:
                if isNumbered(raw) { items.append(Item(text: p, point: n)); n += 1 } else { items.append(Item(text: p, point: nil)) }
            case nil: break
            }
        }
        return (say, items)
    }

    /// Rebuilds the card from what is known about its turn. Text is replaced in place (never animated).
    private mutating func refreshCard(now: TimeInterval) {
        guard var card = state.card, let info = turns[card.turnID] else { return }
        let before = card

        // Fast tier: the selected S; F only when no S was selected.
        var say: String?, sayTier: String?, bullets: [Item] = []
        let fastID = info.selectedS ?? info.fID
        if let fid = fastID, let l = lines[fid] {
            let parsed = Self.parseLines(l)
            say = parsed.say
            if say != nil { sayTier = l.tier }
            bullets = parsed.items
        }
        // P: the bank opener until the fast tier has a SAY line of its own (and only while the brain has not rejected it).
        if say == nil, let bid = info.bankHit, !info.rejectedBankIDs.contains(bid), let p = bank[bid] {
            say = p.opener
            sayTier = "P"
            if bullets.isEmpty { bullets = p.points.enumerated().map { Item(text: $1, point: $0) } }
        }
        // D: points under the divider; on OPENER_WRONG its first line replaces the SAY line.
        var deep: [String] = []
        var corrected = false
        if let did = info.dID, let l = lines[did] {
            var points: [String] = []
            for raw in l.all {
                switch Self.parse(raw) {
                case .say(let s)?: points.append(s)
                case .point(let p)?: points.append(p)
                case nil: break
                }
            }
            if info.openerOK == false, let first = points.first {
                say = first
                sayTier = "D"
                corrected = true
                points.removeFirst()
            }
            deep = points
        }
        // Follow my answer: once the newest follow card has a SAY line, its text replaces the question's answer (SAY and
        // points; the D points belong to the original answer and go). Until then the card keeps what it shows.
        var fi = info
        var following = false
        var coveredNow: Set<Int>
        if let cid = fi.followCardID, Self.parseLines(lines[Self.followKey(cid)]).say != nil { fi.shownFollowID = cid }
        if let shown = fi.shownFollowID {
            let c = Self.parseLines(lines[Self.followKey(shown)])
            if let csay = c.say {
                say = csay
                sayTier = "C"
                bullets = c.items
                deep = []
                corrected = false
                following = true
            }
        }
        if following, let shown = fi.shownFollowID {
            coveredNow = fi.covered[shown] ?? []
        } else {
            // The original card: whatever was reported for a card that is not a follow card.
            coveredNow = fi.covered.filter { !fi.followIDs.contains($0.key) }.reduce(into: Set<Int>()) { $0.formUnion($1.value) }
        }
        turns[card.turnID] = fi
        card.say = say
        card.sayTier = sayTier
        card.sayCorrected = corrected
        let shownItems = Array(bullets.prefix(config.maxBullets))
        card.bullets = shownItems.map(\.text)
        card.chips = info.chips
        card.deepPoints = Array(deep.prefix(config.maxDeepPoints))
        card.following = following
        // `covered` counts the brain's numbered points; the card strikes the displayed line that has that number.
        card.struck = Set(shownItems.enumerated().compactMap { i, item in item.point.flatMap { coveredNow.contains($0) ? i : nil } })
        if card != before {
            touch(now)
            if card.say != nil || !card.bullets.isEmpty, state.activity == .thinking { state.activity = .listening }
        }
        state.card = card
    }
}

// MARK: practice interview (S4)

/// What the overlay shows during a practice interview. Pure value; `OverlayReducer.simApply` changes it.
public struct SimOverlay: Equatable, Sendable {
    /// `sim_progress` (1-based); 0 before the first question.
    public var qIndex = 0
    public var qTotal = 0
    /// When the interview started, for the elapsed timer.
    public var startedAt: Date
    /// The interviewer voice (`VoiceKind` raw value): `text` shows every line as a card.
    public var voice: String
    /// The interviewer's current line (sentences joined as they arrive) and its id from the brain.
    public var lineID: String?
    public var line = ""
    /// The one-line caption in voice modes (toggle).
    public var showCaption: Bool
    /// A line is playing.
    public var speaking = false
    /// The mic is open for an answer.
    public var listening = false
    /// The answer as heard so far.
    public var answer = ""
    /// The latest coach note (coach mode), citations stripped; cleared at the next question.
    public var coach: [String] = []
    /// A cloud voice failed at least once and the Apple voice spoke instead (shown as a chip).
    public var voiceFellBack = false
    /// The interview is over and the report is being written.
    public var closing = false

    public init(startedAt: Date, voice: String, showCaption: Bool) {
        self.startedAt = startedAt
        self.voice = voice
        self.showCaption = showCaption
    }

    public var capsuleTag: String { qTotal > 0 ? "practice · Q\(qIndex)/\(qTotal)" : "practice" }

    public var textMode: Bool { voice == "text" }

    /// The interviewer's line is on screen: always in text mode, as a caption when the toggle is on.
    public var showsLine: Bool { !line.isEmpty && (textMode || showCaption) }

    /// The "AI-generated voice" note: whenever a cloud voice (ElevenLabs, OpenAI) is speaking.
    public var showsAIDisclosure: Bool { speaking && (voice == "elevenlabs" || voice == "openai") }

    /// `12:05` since the start.
    public static func elapsed(from start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension OverlayReducer {
    /// A practice interview starts: the capsule shows `practice`, the panel the sim controls.
    public mutating func simStarting(voice: String, showCaption: Bool, now: Date = Date()) {
        reset(lang: "en")
        state.running = true
        state.activity = .warming
        state.sim = SimOverlay(startedAt: now, voice: voice, showCaption: showCaption)
    }

    public mutating func simToggleCaption() {
        state.sim?.showCaption.toggle()
    }

    public mutating func simApply(_ e: SimEvent) {
        if case .ended(let code) = e {
            state.sim = nil
            state.practiceEnded = true
            state.running = false
            state.activity = .idle
            state.card = nil
            state.addresseeTag = nil
            if code != 0, state.status == nil { state.status = .error("The practice interview ended with an error.") }
            return
        }
        guard var sim = state.sim else { return }
        switch e {
        case .status(let st, let m):
            if st == "voice_error" { sim.voiceFellBack = true } else { applyStatus(st, message: m) }
        case .progress(let i, let n):
            sim.qIndex = i
            sim.qTotal = n
            sim.coach = []
            if state.activity == .warming { state.activity = .thinking }
        case .say(let id, let text, _):
            if sim.lineID != id {
                sim.lineID = id
                sim.line = text
            } else {
                sim.line = [sim.line, text].filter { !$0.isEmpty }.joined(separator: " ")
            }
            sim.listening = false
            if state.activity == .warming { state.activity = .thinking }
        case .speaking(let id):
            sim.speaking = id != nil
        case .spoken:
            break
        case .listening:
            sim.listening = true
            sim.answer = ""
            state.activity = .listening
        case .answerText(let t):
            sim.answer = t
        case .answerSent:
            sim.listening = false
            state.activity = .thinking
        case .coach(_, let lines):
            sim.coach = lines
        case .voiceFallback:
            sim.voiceFellBack = true
        case .report:
            sim.closing = true
        case .ended:
            break
        }
        state.sim = sim
    }
}
