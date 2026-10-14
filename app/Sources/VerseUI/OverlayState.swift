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
    /// Which tier the SAY line came from: "P", "S", "F" or "D" (corrected).
    public var sayTier: String?
    /// D said the shown opener was wrong; `say` is D's first line now.
    public var sayCorrected = false
    /// Up to 3 points under the SAY line.
    public var bullets: [String] = []
    public var chips: [OverlayChip] = []
    /// Sonnet's detail points, under the divider.
    public var deepPoints: [String] = []

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

    /// The short text in the capsule chip.
    public var title: String {
        switch self {
        case .offline: return "Offline"
        case .rateLimited: return "Rate limited"
        case .creditExhausted: return "Max API credit used up"
        case .restarting: return "Restarting"
        case .error: return "Error"
        case .permission(let k): return k == "microphone" ? "Microphone access needed" : "Audio recording access needed"
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
        default: return nil
        }
    }

    /// Statuses that need a bigger message than the capsule chip.
    public var needsPanel: Bool {
        switch self {
        case .permission, .creditExhausted, .error: return true
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

    public init() {}

    /// `en · for you`
    public var capsuleTag: String {
        [lang, addresseeTag].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Settings the reducer needs.
public struct OverlayConfig: Equatable, Sendable {
    /// Seconds without new content after which the card collapses to the capsule.
    public var cardTimeout: TimeInterval = 45
    /// Other participants, to name them in the capsule tag (`for Marco`).
    public var otherNames: [String] = []
    public var maxBullets = 3
    public var maxDeepPoints = 4

    public init(cardTimeout: TimeInterval = 45, otherNames: [String] = []) {
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
        var bankHit: String?
        var bankRejected = false
        var chips: [OverlayChip] = []
        var selectedS: String?
        var fID: String?
        var dID: String?
        var openerOK: Bool?
    }

    private var lines: [String: Lines] = [:]
    private var turns: [String: TurnInfo] = [:]
    private var lastContent: TimeInterval = 0
    /// When each topic chip (by text) was last seen.
    private var topicSeen: [String: TimeInterval] = [:]

    public init(config: OverlayConfig = OverlayConfig(), bank: [String: BankOpener] = [:]) {
        self.config = config
        self.bank = bank
    }

    public mutating func reset(lang: String) {
        state = OverlayState()
        state.lang = lang
        lines = [:]
        turns = [:]
        topicSeen = [:]
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
        case .metric(let o):
            if o[string: "stage"] == "session_t0" {
                state.running = true
                if state.activity == .idle || state.activity == .warming { state.activity = .listening }
            }
        case .ended(let code):
            state.running = false
            state.activity = .idle
            state.card = nil
            state.topics = []
            state.addresseeTag = nil
            state.tagDimmed = false
            if code != 0, state.status == nil { state.status = .error("The session ended with an error.") }
            if code == 0, state.status == .restarting || state.status == .offline || state.status == .rateLimited { state.status = nil }
        }
    }

    /// Collapses a card that has had no new content for `cardTimeout`.
    public mutating func tick(now: TimeInterval) {
        if state.card != nil, now - lastContent >= config.cardTimeout {
            state.card = nil
            if state.activity == .thinking { state.activity = .listening }
        }
        if !state.topics.isEmpty {
            state.topics.removeAll { now - (topicSeen[$0.text] ?? now) >= config.cardTimeout }
            topicSeen = topicSeen.filter { now - $0.value < config.cardTimeout }
        }
    }

    /// Marks the start of a session (Start pressed): the capsule shows warming until the brain is ready.
    public mutating func sessionStarting(lang: String) {
        reset(lang: lang)
        state.running = true
        state.activity = .warming
    }

    private mutating func touch(_ now: TimeInterval) { lastContent = now }

    mutating func setStatus(_ s: OverlayStatus?) { state.status = s }

    private mutating func applyStatus(_ st: String, message: String) {
        switch st {
        case "warming": state.activity = .warming
        case "ready":
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

    private mutating func applyOutbound(_ o: [String: JSONValue], now: TimeInterval) {
        guard let tid = o[string: "turn_id"] else { return }
        switch o.type {
        case "bank_hit":
            guard let bid = o[string: "bank_id"] else { return }
            turns[tid, default: TurnInfo()].bankHit = bid
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "turn":
            guard o[string: "speaker"] == "remote" else { return }
            let who = o[string: "addressee"] ?? "unknown"
            let kind = o[string: "kind"] ?? "question"
            let text = o[string: "text"] ?? ""
            if who == "other" {
                state.addresseeTag = "for " + (otherName(in: text) ?? "someone else")
                state.tagDimmed = true
                return
            }
            guard kind == "question" else { return }   // fragments and statements never open a card
            state.addresseeTag = who == "me" ? "for you" : nil
            state.tagDimmed = false
            state.card = OverlayCard(turnID: tid, question: text)
            state.topics = []
            topicSeen = [:]
            state.activity = .thinking
            touch(now)
            refreshCard(now: now)
        default:
            break
        }
    }

    private func otherName(in text: String) -> String? {
        let words = Set(text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        return config.otherNames.first { name in
            let parts = name.lowercased().split(separator: " ").map(String.init)
            return !parts.isEmpty && parts.allSatisfy { words.contains($0) }
        }
    }

    private mutating func applyChip(_ o: [String: JSONValue], now: TimeInterval) {
        guard let tid = o[string: "turn_id"], let text = o[string: "text"], !text.isEmpty else { return }
        let kind = o[string: "kind"] ?? ""
        let chip = OverlayChip(text: text, source: OverlayChip.sourceLabel(kind: kind, ref: o[string: "source_ref"] ?? ""), kind: kind)
        if kind == "topic", state.card == nil || state.card?.turnID != tid {
            // A topic can come up with no question card open: it goes to the slim row under the capsule.
            topicSeen[text] = now
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
        case "delta":
            guard let id = o[string: "id"], let tid = o[string: "turn_id"], let tier = o[string: "tier"] else { return }
            var l = lines[id] ?? Lines(tier: tier, turnID: tid)
            l.current += o[string: "text"] ?? ""
            if o[bool: "line_done"] == true {
                let s = l.current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { l.done.append(s) }
                l.current = ""
            }
            lines[id] = l
            var info = turns[tid, default: TurnInfo()]
            if tier == "F", info.fID == nil { info.fID = id }
            if tier == "D", info.dID == nil { info.dID = id }
            turns[tid] = info
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
            turns[tid, default: TurnInfo()].bankRejected = true
            if state.card?.turnID == tid { refreshCard(now: now) }
        case "status":
            applyStatus(o[string: "state"] ?? "", message: o[string: "message"] ?? "")
        default:
            break
        }
    }

    // MARK: card assembly

    /// One display line: SAY or a point. Streaming lines that are still only "SAY" / "-" show nothing yet.
    private enum Line { case say(String), point(String) }

    private static func parse(_ raw: String) -> Line? {
        let s = raw.trimmingCharacters(in: .whitespaces)
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

    /// Rebuilds the card from what is known about its turn. Text is replaced in place (never animated).
    private mutating func refreshCard(now: TimeInterval) {
        guard var card = state.card, let info = turns[card.turnID] else { return }
        let before = card

        // Fast tier: the selected S; F only when no S was selected.
        var say: String?, sayTier: String?, bullets: [String] = []
        let fastID = info.selectedS ?? info.fID
        if let fid = fastID, let l = lines[fid] {
            for raw in l.all {
                switch Self.parse(raw) {
                case .say(let s)?: if say == nil { say = s; sayTier = l.tier } else { bullets.append(s) }
                case .point(let p)?: bullets.append(p)
                case nil: break
                }
            }
        }
        // P: the bank opener until the fast tier has a SAY line of its own (and only while the brain has not rejected it).
        if say == nil, let bid = info.bankHit, !info.bankRejected, let p = bank[bid] {
            say = p.opener
            sayTier = "P"
            if bullets.isEmpty { bullets = p.points }
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
        card.say = say
        card.sayTier = sayTier
        card.sayCorrected = corrected
        card.bullets = Array(bullets.prefix(config.maxBullets))
        card.chips = info.chips
        card.deepPoints = Array(deep.prefix(config.maxDeepPoints))
        if card != before {
            touch(now)
            if card.say != nil || !card.bullets.isEmpty, state.activity == .thinking { state.activity = .listening }
        }
        state.card = card
    }
}
