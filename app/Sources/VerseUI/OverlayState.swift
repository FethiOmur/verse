import Foundation
import VerseAudio
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
        if kind == "term" { return L10n.tr("glossary") }
        let prefix = ref.split(separator: ":").first.map(String.init) ?? ref
        switch prefix {
        case "prep": return L10n.tr("prep note")
        case "vault": return "vault"
        case "commit": return "commit"
        case "me": return L10n.tr("my profile")
        case "": return L10n.tr("notes")
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
    /// "Follow my answer": The owner went his own way and `say`/`bullets` are the C tier's continuation of his line, not the
    /// answer to the question. The view marks the card "following you".
    public var following = false
    /// While `following`: the follow card on screen (the brain's `card_id`). Each one is an answer of its own for the answer
    /// history (`AnswerHistory.key(for:)`). nil otherwise.
    public var followCardID: String?
    /// Indices into `bullets` that the owner has already said (the brain's `covered`); the view strikes them through.
    public var struck: Set<Int> = []
    /// AUTO language: the language this card's answer is written in (the brain's `answer_lang` for its turn); nil when the brain
    /// did not say (AUTO off, or before its first call for the turn). Compare with `OverlayState.dominantLang`.
    public var answerLang: String?
    /// The id of the brain call whose SAY line the card shows: the follow card's call while `following`, D's when its correction
    /// replaced the opener (OPENER_WRONG), else the selected S or the F, else D. nil while the SAY line is the bank's opener (even
    /// with F's points under it). The id a BAD mark names (`CardMarks.cardID`): the after-call review banks that call's text.
    public var cardID: String?

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
    /// A capture or a recognizer stopped mid-call and came back by itself (`capture_recovered`, `speech_recovered`): a few
    /// seconds of transcript may be missing. Shown for `OverlayConfig.noticeDuration`, gives way to a card, no buttons.
    case reconnected(Set<Recovered>)

    /// What came back, for `reconnected`.
    public enum Recovered: String, Sendable, Hashable {
        case microphone
        case meetingAudio
        /// A capture whose issue text named no channel.
        case audio
        /// A recognizer (either channel) restarted.
        case transcription
    }

    private static func reconnectedTitle(_ parts: Set<Recovered>) -> String {
        let audio = parts.subtracting([.transcription])
        if audio.isEmpty { return L10n.tr("Transcription restarted") }
        if audio == [.microphone] { return L10n.tr("Microphone reconnected") }
        if audio == [.meetingAudio] { return L10n.tr("Meeting audio reconnected") }
        return L10n.tr("Audio reconnected")
    }

    /// The short text in the capsule chip.
    public var title: String {
        switch self {
        case .offline: return L10n.tr("No connection")
        case .rateLimited: return L10n.tr("Rate limited")
        case .creditExhausted: return L10n.tr("Max API credit used up")
        case .restarting: return L10n.tr("Restarting")
        case .error: return L10n.tr("Error")
        case .permission(let k): return k == "microphone" ? L10n.tr("Microphone access needed") : L10n.tr("Audio recording access needed")
        case .stopConfirm: return L10n.tr("Press ⌥⌘V again to stop")
        case .meMissing: return L10n.tr("Your profile was not found")
        case .reconnected(let parts): return Self.reconnectedTitle(parts)
        }
    }

    /// The few words that fit the capsule's wing.
    public var shortTitle: String {
        switch self {
        case .offline: return L10n.tr("No connection")
        case .rateLimited: return L10n.tr("Rate limited")
        case .creditExhausted: return L10n.tr("No credit")
        case .restarting: return L10n.tr("Restarting")
        case .error: return L10n.tr("Error")
        case .permission: return L10n.tr("Needs access")
        case .stopConfirm: return L10n.tr("Stop?")
        case .meMissing: return L10n.tr("No profile")
        case .reconnected(let parts): return parts.subtracting([.transcription]).isEmpty ? L10n.tr("Restarted") : L10n.tr("Reconnected")
        }
    }

    /// The longer explanation, when there is one.
    public var detail: String? {
        switch self {
        case .creditExhausted(let m), .error(let m): return m.isEmpty ? nil : m
        case .permission(let k):
            return k == "microphone"
                ? L10n.tr("Verse needs the microphone to hear your side of the call. Allow it in System Settings, then press Start again.")
                : L10n.tr("Verse needs System Audio Recording to hear the meeting app. Allow it in System Settings, then press Start again.")
        case .restarting: return L10n.tr("The brain stopped; restarting it.")
        case .stopConfirm: return L10n.tr("Verse keeps listening if you don't.")
        case .meMissing: return L10n.tr("Verse answers without it. Build it on the Me page.")
        case .reconnected: return L10n.tr("A few seconds may be missing from the transcript.")
        default: return nil
        }
    }

    /// Statuses that need a bigger message than the capsule chip.
    public var needsPanel: Bool {
        switch self {
        case .permission, .creditExhausted, .error, .stopConfirm, .meMissing, .reconnected: return true
        default: return false
        }
    }

    /// While a session runs, an answer card is shown over this status instead of behind it (review H6): one failed call must
    /// not hide every later card until Dismiss. The status stays in the state (the capsule's chip) and its panel comes back
    /// when no card is open.
    public var yieldsToCard: Bool {
        switch self {
        case .error, .reconnected: return true
        default: return false
        }
    }

    /// A short notice that goes by itself (no buttons, nothing to answer).
    public var isTransientNotice: Bool {
        if case .reconnected = self { return true }
        return false
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
    /// The call's time cue (`call.json`, `CallCue`): "1 min left" in the last minute, "wrap up" at the end. nil otherwise.
    public var timeCue: TimeCue?
    /// AUTO language: the call's dominant language as the brain last reported it (`lang_dominant`), the language new answers are
    /// written in. nil when AUTO is off or before the brain said.
    public var dominantLang: String?
    /// AUTO language: the language of most of the other side's speech so far (`lang_majority`, and `majority` on `lang_dominant`).
    /// It differs from `dominantLang` after a short run in another language flipped the cards; Regenerate targets it. nil when AUTO
    /// is off or before the brain said.
    public var majorityLang: String?
    /// A regenerate (the island's button, ⌥⌘R) is on its way and its answer has not finished: another press is ignored.
    public var regenerating = false

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
    /// Anytime calls: the route this session listens on. Non-nil makes the panel the start card, with the route
    /// chip (spec 2.1).
    public var route: AudioRoute?
    /// The session language (no longer drawn on the start card: language has no chip).
    public var lang = "en"
    /// The interim AUTO language mode is on: `lang` is then the language it picked.
    public var autoLang = false
    /// Listening runs but the brain is still warming up (the runner's `status warming`): no answers yet. Cleared by `ready`.
    public var answersWarming = false

    public init(phase: Phase, session: String, app: String?, transcribing: Bool = false, route: AudioRoute? = nil, lang: String = "en",
                autoLang: Bool = false) {
        self.phase = phase
        self.session = session
        self.app = app
        self.transcribing = transcribing
        self.route = route
        self.lang = lang
        self.autoLang = autoLang
    }

    /// The start card of an anytime session (route chip) rather than the plain start-up panel.
    public var isStartCard: Bool { route != nil }

    private var isStarting: Bool { if case .starting = phase { return true } else { return false } }

    public var title: String {
        // Listening already runs while the brain warms up: say so instead of "Ready", until the brain is ready.
        if answersWarming, !isStarting { return L10n.tr("Listening · answers warming up") }
        if isStartCard {
            switch phase {
            case .starting: return L10n.tr("Starting…")
            case .ready: return L10n.tr("Ready")
            case .listening: return L10n.tr("Listening")
            }
        }
        switch phase {
        case .starting: return L10n.tr("Starting…")
        case .ready: return L10n.tr("Ready · \(session)")
        case .listening: return L10n.tr("Listening · \(session)")
        }
    }

    public var subtitle: String {
        switch phase {
        case .starting(let step): return step
        case .ready:
            switch route {
            case .room?: return L10n.tr("listening through the microphone")
            case .phone?: return L10n.tr("listening to the phone call")
            default: return app.map { L10n.tr("listening to \($0)") } ?? L10n.tr("waiting for the meeting app's audio")
            }
        case .listening:
            let hearing: String
            switch route {
            case .room?: hearing = L10n.tr("hearing the room")
            case .phone?: hearing = L10n.tr("hearing the call")
            default: hearing = app.map { L10n.tr("hearing \($0)") } ?? L10n.tr("hearing the meeting")
            }
            return transcribing ? L10n.tr("\(hearing) · transcribing") : hearing
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
    /// How long a "reconnected" notice stays (`OverlayStatus.reconnected`).
    public var noticeDuration: TimeInterval = 4

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
    /// The `.error` on screen came from the brain in a running call and is about one call: the next card with content
    /// clears it (`clearPerCallStatus`).
    private var clearableError = false
    /// What failed for good, per channel: a capture (`capture_failed`) and a recognizer (`speech_failed`) are tracked apart, so
    /// one channel's recovery never takes down another channel's (or the other kind's) failure, and a second failure never
    /// replaces the first. The panel shows every entry still here.
    private var failures: [ChannelFailure: String] = [:]
    /// The `.error` message the failures last put up, so a recovery only takes down (or rewrites) its own panel.
    private var failurePanel: String?
    /// When the "reconnected" notice on screen goes.
    private var noticeUntil: TimeInterval?

    /// One channel's permanent failure. `channel` nil: the issue text named no channel.
    private struct ChannelFailure: Hashable, Sendable {
        enum Kind: Int, Sendable { case capture, speech }
        var kind: Kind
        var channel: Channel?

        /// Panel order: the meeting channel first, then the microphone, then unknown; capture before recognition.
        var order: Int {
            let c: Int
            switch channel { case .remote?: c = 0; case .me?: c = 1; case nil: c = 2 }
            return c * 2 + kind.rawValue
        }
    }

    /// Streamed text per call id: finished lines and the line being written.
    private struct Lines: Sendable {
        var tier: String
        var turnID: String
        /// The brain call these lines came from (the delta's `id`).
        var callID = ""
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
        /// ... and the points the owner covered, by card id (`covered.card_id` -> point indices).
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
    /// AUTO language: the language the brain wrote each turn's answer in (`answer_lang`), by turn id.
    private var answerLangs: [String: String] = [:]
    /// Regenerate: the question each regenerated card-now turn answers again (the brain's `regenerate` metric), by turn id.
    private var regenQuestions: [String: String] = [:]
    /// When the regenerate in flight was pressed (or last confirmed busy); `RegenerateRule.inFlightTimeout` after it, it no longer blocks.
    private var regenSince: TimeInterval = 0
    /// Remote `statement` turns not addressed to someone else, by turn id: (text, addressee). The brain may still
    /// answer one as a question; its first S/F SAY line then opens the card.
    private var statements: [String: (text: String, addressee: String)] = [:]
    /// The newest remote turn: only that one may open a card late.
    private var lastRemoteTurnID: String?
    /// Cards a regenerated card took the island from, by turn id: they keep streaming off screen (the history records them),
    /// so the answer to a newer question is neither frozen nor lost while the regenerated one is shown.
    private(set) var backgroundCards: [String: OverlayCard] = [:]
    /// What the other side said last (the open partial, else the last final): the question a card-now answer is for.
    private var lastHeard = ""
    private var lastContent: TimeInterval = 0
    /// When each topic chip (by text) was last seen.
    private var topicSeen: [String: TimeInterval] = [:]
    /// The turn each topic chip (by text) came from, so a bank hit in that turn can take it down again.
    private var topicTurn: [String: String] = [:]
    /// When the meeting's audio was last above `config.audibleDbfs` (or text from it arrived).
    private var lastAudible: TimeInterval = -.infinity
    /// The session's time cue, when its `call.json` has one.
    private var callCue: CallCue?

    public init(config: OverlayConfig = OverlayConfig(), bank: [String: BankOpener] = [:]) {
        self.config = config
        self.bank = bank
    }

    /// The island's Regenerate was pressed: no other press counts until the brain says it is done (or the timeout passes).
    public mutating func beginRegenerate(now: TimeInterval) {
        state.regenerating = true
        regenSince = now
    }

    /// The brain could not be asked (no brain running): the press did not happen.
    public mutating func cancelRegenerate() {
        state.regenerating = false
    }

    public mutating func reset(lang: String) {
        state = OverlayState()
        state.lang = lang
        lines = [:]
        turns = [:]
        answerLangs = [:]
        regenQuestions = [:]
        regenSince = 0
        statements = [:]
        lastRemoteTurnID = nil
        backgroundCards = [:]
        lastHeard = ""
        topicSeen = [:]
        topicTurn = [:]
        lastAudible = -.infinity
        callCue = nil
        clearableError = false
        failures = [:]
        failurePanel = nil
        noticeUntil = nil
    }

    /// Sets (or, with nil, removes) the call's time cue. `tick` moves `state.timeCue` with the clock.
    public mutating func setCallCue(_ cue: CallCue?, now: TimeInterval) {
        callCue = cue
        state.timeCue = cue?.phase(now: now)
    }

    // MARK: events

    public mutating func apply(_ e: RunnerEvent, now: TimeInterval) {
        switch e {
        case .brain(let o):
            applyBrain(o, now: now)
            refreshBackground(o[string: "turn_id"])
        case .chip(let o):
            applyChip(o, now: now)
            refreshBackground(o[string: "turn_id"])
        case .outbound(let o):
            applyOutbound(o, now: now)
            refreshBackground(o[string: "turn_id"])
        case .status(let st, let m): applyStatus(st, message: m)
        case .issue(let code, let m, let channel):
            applyIssue(code, message: m, channel: channel, now: now)
        case .level(let remote, let me): applyLevel(remoteDbfs: remote, meDbfs: me, now: now)
        case .metric(let o):
            if o[string: "stage"] == "session_t0" {
                state.running = true
                if state.activity == .idle || state.activity == .warming { state.activity = .listening }
                if state.startup != nil { state.startup?.phase = .ready }
            }
        case .ended(let code):
            state.running = false
            state.regenerating = false
            state.activity = .idle
            state.card = nil
            state.topics = []
            state.startup = nil
            state.addresseeTag = nil
            state.tagDimmed = false
            state.remoteSpeaking = false
            state.remoteBars = [0, 0, 0]
            state.meBars = [0, 0, 0]
            if state.status?.isTransientNotice == true { state.status = nil; noticeUntil = nil }
            if code != 0, state.status == nil { state.status = .error(L10n.tr("The session ended with an error.")) }
            if code == 0, state.status == .restarting || state.status == .offline || state.status == .rateLimited { state.status = nil }
        }
    }

    /// Collapses a card that has had no new content for `cardTimeout`.
    public mutating func tick(now: TimeInterval) {
        if state.regenerating, now - regenSince >= RegenerateRule.inFlightTimeout { state.regenerating = false }
        if callCue != nil || state.timeCue != nil { state.timeCue = callCue?.phase(now: now) }
        if let until = noticeUntil, now >= until {
            noticeUntil = nil
            if state.status?.isTransientNotice == true { state.status = nil }
        }
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
                                         unprepared: Bool = false, auto: Bool = false) {
        reset(lang: lang)
        state.running = true
        state.activity = .warming
        state.route = route
        state.unprepared = unprepared
        state.startup = StartupPanel(phase: .starting(step: L10n.tr("Starting the brain and loading models")), session: session, app: app,
                                     route: route, lang: lang, autoLang: auto)
    }

    /// A mid-call route or language switch: the labels follow, nothing else moves. The open card, the topic chips and what the
    /// reducer remembers of the turns belong to the call, which goes on.
    public mutating func listeningChanged(route: AudioRoute, lang: String, app: String?, auto: Bool? = nil) {
        state.route = route
        state.lang = lang
        guard state.startup != nil else { return }
        state.startup?.route = route
        state.startup?.lang = lang
        if let auto { state.startup?.autoLang = auto }
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

    /// The sentence for a `reason` the brain put on a `status` event (brain/verse_brain/runtime/engine.py: NO_API_KEY,
    /// INVALID_API_KEY). Without one the brain's own English `message` is shown, as before.
    static func reasonText(_ reason: String?) -> String? {
        switch reason {
        case "no_api_key": return L10n.tr("No Anthropic API key. Add it in Settings, then start again.")
        case "invalid_api_key": return L10n.tr("The Anthropic API key was not accepted. Check it in Settings, then start again.")
        default: return nil
        }
    }

    private mutating func applyStatus(_ st: String, message: String, reason: String? = nil) {
        switch st {
        case "warming":
            state.activity = .warming
            if state.startup != nil { state.startup?.answersWarming = true }
        case "ready":
            state.startup?.answersWarming = false
            if case .starting? = state.startup?.phase { state.startup?.phase = .starting(step: L10n.tr("Brain ready · starting speech recognition")) }
            if state.activity == .warming || state.activity == .offline || state.activity == .idle { state.activity = .listening }
            if state.status == .offline || state.status == .rateLimited || state.status == .restarting { state.status = nil }
        case "offline":
            state.status = .offline
            state.activity = .offline
        case "rate_limited": state.status = .rateLimited
        case "credit_exhausted": state.status = .creditExhausted(message)
        case "refusal": break   // the fast tiers show nothing; D still answers
        case "restarting": state.status = .restarting
        case "error":
            state.status = .error(Self.reasonText(reason) ?? message)
            // A brain error in a running call (one failed request, an internal error) goes away with the next card that has
            // content. A missing or rejected key, no credit or a bad session folder stays until dismissed.
            clearableError = state.running && !Self.lastingErrorReasons.contains(reason ?? "")
            return
        case "permission_denied": state.status = .permission(message)
        case "listen_failed": state.status = .error(message)
        default: break
        }
        // Any other status replaces the error; `listen_failed` is an error of its own that no card can clear.
        if st == "listen_failed" { clearableError = false } else if case .error? = state.status {} else { clearableError = false }
    }

    /// A runtime problem of the listen session (VerseRunner `issue`). Review H5/H8: a channel whose capture or recognizer died
    /// for good is an error no card clears, like `listen_failed`; a capture that came back takes its own error down. A recovered
    /// capture or recognizer then says so briefly ("Microphone reconnected", `OverlayStatus.reconnected`): there was a gap in
    /// the transcript. Failures are kept per channel and kind (the issue's own `channel`; only when it has none, the channel the
    /// text names, see `ListenError.channel(inIssueMessage:)`): the panel stays until every failed channel has recovered and
    /// names the ones still down.
    private mutating func applyIssue(_ code: String, message m: String, channel field: Channel?, now: TimeInterval) {
        let channel = field ?? ListenError.channel(inIssueMessage: m)
        switch code {
        case "permission_denied": state.status = .permission(m.contains("microphone") ? "microphone" : "audioCapture")
        case "capture_failed", "speech_failed":
            failures[ChannelFailure(kind: code == "capture_failed" ? .capture : .speech, channel: channel)] = m
            let panel = failureText
            state.status = .error(panel)
            failurePanel = panel
            clearableError = false
        case "capture_recovered":
            recover(.capture, channel: channel)
            let part: OverlayStatus.Recovered = channel == .me ? .microphone : channel == .remote ? .meetingAudio : .audio
            showReconnected(part, now: now)
        case "speech_recovered":
            recover(.speech, channel: channel)
            showReconnected(.transcription, now: now)
        default: break
        }
    }

    /// The "reconnected" notice, in a running call, only where nothing else is showing (an error, a permission message, "No
    /// connection" stay) or another such notice is (the two merge and the time starts again).
    private mutating func showReconnected(_ part: OverlayStatus.Recovered, now: TimeInterval) {
        guard state.running else { return }
        switch state.status {
        case nil: state.status = .reconnected([part])
        case .reconnected(let parts)?: state.status = .reconnected(parts.union([part]))
        default: return
        }
        noticeUntil = now + config.noticeDuration
    }

    /// Every failure still standing, one line each, in a fixed order.
    private var failureText: String {
        failures.sorted { $0.key.order < $1.key.order }.map(\.value).joined(separator: "\n")
    }

    /// A channel's capture or recognizer works again: its failure goes; the panel shows what is left, or goes too. A recovery
    /// whose text names no channel is applied only when exactly one failure of that kind stands (nothing to guess between).
    private mutating func recover(_ kind: ChannelFailure.Kind, channel: Channel?) {
        let key: ChannelFailure
        if let channel {
            key = ChannelFailure(kind: kind, channel: channel)
        } else {
            let ofKind = failures.keys.filter { $0.kind == kind }
            guard ofKind.count == 1, let only = ofKind.first else { return }
            key = only
        }
        guard failures.removeValue(forKey: key) != nil else { return }
        // Only the panel the failures put up is changed; a status that replaced it since stays.
        guard let shown = failurePanel, state.status == .error(shown) else { return }
        if failures.isEmpty {
            state.status = nil
            failurePanel = nil
        } else {
            let panel = failureText
            state.status = .error(panel)
            failurePanel = panel
        }
    }

    /// `reason`s of a brain `status error` that are not about one call (brain/verse_brain/runtime/engine.py).
    static let lastingErrorReasons: Set<String> = ["no_api_key", "invalid_api_key", "no_credit", "bad_session"]

    /// A new card with content proves the brain answers again: a per-call error and the rate-limit chip go (review H6; the
    /// brain never sends the `ready` that would clear `rate_limited`).
    private mutating func clearPerCallStatus() {
        guard state.running else { return }
        if state.status == .rateLimited {
            state.status = nil
        } else if clearableError, case .error? = state.status {
            state.status = nil
            clearableError = false
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
                state.addresseeTag = otherName(in: text).map { L10n.tr("for \($0)") } ?? L10n.tr("for someone else")
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
        backgroundCards[tid] = nil
        // A new remote question ends follow mode for the card it replaces.
        if let previous = state.card?.turnID, previous != tid { turns[previous]?.endFollow() }
        state.addresseeTag = who == "me" ? L10n.tr("for you") : nil
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
        // A turn with a bank hit has its answer: a topic chip that was already on its way is dropped. A hit the brain rejected
        // (`bank_verdict agree:false`) is no answer, so its turn keeps its topic chips.
        if kind == "topic", let bid = turns[tid]?.bankHit, turns[tid]?.rejectedBankIDs.contains(bid) != true { return }
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
            var l = lines[key] ?? Lines(tier: tier, turnID: tid, callID: id)
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
                if let q = regenQuestions[tid] {
                    // A regenerated card asks the question of the card it answers again. It answers an earlier card while the call
                    // goes on, so it is not the newest remote turn (a waiting statement or a late bank hit of that one still opens
                    // its card), and the card it takes the island from keeps streaming off screen into the history.
                    if let shown = state.card, shown.turnID != tid { backgroundCards[shown.turnID] = shown }
                    openCard(turnID: tid, question: q, addressee: "me", now: now)
                } else {
                    // A plain card-now card answers what was said last: it is the newest turn.
                    lastRemoteTurnID = tid
                    openCard(turnID: tid, question: lastHeard, addressee: "me", now: now)
                }
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
            // The owner left the card: a new card version (the C deltas of `card_id`) replaces the visible text. Only the open
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
            applyStatus(o[string: "state"] ?? "", message: o[string: "message"] ?? "", reason: o[string: "reason"])
        case "metric":
            // AUTO language (brain runtime/lang.py): the call's dominant language and the language each turn's answer is in.
            switch o[string: "stage"] {
            case "lang_dominant"?:
                if let l = o[string: "lang"], Self.answerLanguages.contains(l) { state.dominantLang = l }
                if let l = o[string: "majority"], Self.answerLanguages.contains(l) { state.majorityLang = l }
            case "lang_majority"?:
                if let l = o[string: "lang"], Self.answerLanguages.contains(l) { state.majorityLang = l }
            case "lang_auto"?:
                if o[bool: "on"] == false {
                    state.dominantLang = nil
                    state.majorityLang = nil
                }
            case "regenerate"?:
                // Sent before the new turn's first delta: that delta opens the card with this question.
                if let tid = o[string: "turn_id"], !tid.isEmpty, let q = o[string: "question"], !q.isEmpty { regenQuestions[tid] = q }
            case "regenerate_done"?, "regenerate_empty"?:
                state.regenerating = false
            case "regenerate_busy"?:
                // The brain still streams the previous one: wait for its `regenerate_done`.
                if state.regenerating { regenSince = now }
            case "answer_lang"?:
                guard let tid = o[string: "turn_id"], !tid.isEmpty, let l = o[string: "lang"], Self.answerLanguages.contains(l) else { return }
                // Kept apart from `turns`: a card-now turn opens its card on its first delta only while `turns` does not know it.
                answerLangs[tid] = l
                if state.card?.turnID == tid { refreshCard(now: now) }
            default:
                break
            }
        case "notice":
            // `me_missing`: the profile files named in `start` do not exist. A status that never covers a card (openCard
            // takes it down). The other notice (`me_conflicts`) is for the Me page, not the island.
            if o[string: "kind"] == "me_missing", state.status == nil { state.status = .meMissing }
        default:
            break   // unknown message types (and unknown fields) are ignored
        }
    }

    private static func followKey(_ cardID: String) -> String { "C|" + cardID }

    /// The languages an answer can be in.
    static let answerLanguages: Set<String> = ["en", "it", "tr"]

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

    /// A card off screen (`backgroundCards`) is rebuilt like the one on screen when its turn changes.
    private mutating func refreshBackground(_ tid: String?) {
        guard let tid, state.card?.turnID != tid, let card = backgroundCards[tid], let built = assemble(card) else { return }
        backgroundCards[tid] = built
    }

    /// Rebuilds the card from what is known about its turn. Text is replaced in place (never animated).
    private mutating func refreshCard(now: TimeInterval) {
        guard let before = state.card, let card = assemble(before) else { return }
        if card != before {
            touch(now)
            if card.say != nil || !card.bullets.isEmpty, state.activity == .thinking { state.activity = .listening }
            if card.say != nil || !card.bullets.isEmpty || !card.deepPoints.isEmpty { clearPerCallStatus() }
        }
        state.card = card
    }

    /// `card` rebuilt from what is known about its turn; nil when nothing is known of it yet.
    private mutating func assemble(_ shown: OverlayCard) -> OverlayCard? {
        var card = shown
        guard let info = turns[card.turnID] else { return nil }

        // Fast tier: the selected S; F only when no S was selected.
        var say: String?, sayTier: String?, bullets: [Item] = []
        var cardID: String?
        let fastID = info.selectedS ?? info.fID
        if let fid = fastID, let l = lines[fid] {
            cardID = fid
            let parsed = Self.parseLines(l)
            say = parsed.say
            if say != nil { sayTier = l.tier }
            bullets = parsed.items
        }
        // P: the bank opener until the fast tier has a SAY line of its own (and only while the brain has not rejected it).
        if say == nil, let bid = info.bankHit, !info.rejectedBankIDs.contains(bid), let p = bank[bid] {
            say = p.opener
            sayTier = "P"
            cardID = nil            // the opener on screen is the bank's: a mark names it by its turn (`P-<turn>`)
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
                cardID = did        // the SAY line on screen is D's, not the opener it replaced
            }
            deep = points
            if cardID == nil, sayTier != "P" { cardID = did }
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
                cardID = lines[Self.followKey(shown)]?.callID ?? cardID
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
        card.followCardID = following ? fi.shownFollowID : nil
        card.answerLang = answerLangs[card.turnID]
        card.cardID = cardID
        // `covered` counts the brain's numbered points; the card strikes the displayed line that has that number.
        card.struck = Set(shownItems.enumerated().compactMap { i, item in item.point.flatMap { coveredNow.contains($0) ? i : nil } })
        return card
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

    public var capsuleTag: String { qTotal > 0 ? L10n.tr("practice · Q\(qIndex)/\(qTotal)") : L10n.tr("practice") }

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
            if code != 0, state.status == nil { state.status = .error(L10n.tr("The practice interview ended with an error.")) }
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
