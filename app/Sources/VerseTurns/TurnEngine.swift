import Foundation
import VerseSpeech

/// Thresholds and names the turn logic needs. Every number is a config value (plan P1-4).
public struct TurnConfig: Sendable {
    /// The owner's name and spellings the recognizer is known to produce for it ("Alex" often comes back as "Fi").
    public var ownerName: String
    public var ownerAliases: [String]
    /// Other participants; a question that names one of them is not for the owner.
    public var otherNames: [String]
    /// Quiet time after a complete-clause question before the turn is declared over.
    public var cueEndpointMs: Int
    /// Quiet time for everything else.
    public var plainEndpointMs: Int
    /// Quiet time (no result of the microphone recognizer at all) before a me turn is closed. Longer than the remote
    /// endpoint on purpose: the recognizer delivers volatile text in bursts up to ~1.1 s apart while the speaker goes on,
    /// and a me turn that closed between two bursts made the next burst look like Alex starting to talk again.
    public var meEndpointMs: Int
    public var matchThreshold: Double
    public var matchMargin: Double
    /// "en" | "it" | "tr".
    public var lang: String
    /// A gap this long between the previous words of a turn and new, non-overlapping audio starts a new turn.
    public var newTurnSilenceMs: Int
    /// A question that starts within this many seconds after the owner stopped talking is for the owner.
    public var meFollowSeconds: Double
    /// Consecutive transcript events that must agree on the same bank entry before `bank_hit` is sent.
    public var matchConsecutive: Int
    /// Remote audio counts as speech above this loudness (RMS dBFS over 100 ms) or `floor + speechAboveFloorDb`,
    /// whichever is higher but never above `speechCeilingDbfs`. Only used once `noteRemoteLevel` has been called.
    public var speechFloorDbfs: Double
    public var speechAboveFloorDb: Double
    public var speechCeilingDbfs: Double
    /// With audio levels: the longest the endpoint waits (after the last text change) for the audio to go quiet or the
    /// recognizer to catch up with it. Without levels the endpoint is purely text based and this is not used. It only
    /// matters for audio that never goes quiet (music under the voice), so it must stay longer than the longest gap
    /// between two recognizer results inside one sentence: Nemotron delivered results 1.13 s apart in a recorded run
    /// (a 1.0 s cap split that sentence).
    public var audioWaitCapMs: Int
    /// With audio levels: a turn is never closed sooner than this after its last text change, so the rest of a burst of
    /// recognizer results (several events in the same millisecond) still lands in it.
    public var burstSettleMs: Int
    /// With audio levels: the recognizer has caught up with the audio once it delivered any result (also one without
    /// new words, e.g. a final) at least this long after the remote audio went quiet. Its chunks are decoded whole, so
    /// a result that comes after the quiet began has seen the end of the speech (38 recorded Nemotron utterances: the
    /// words of a result 0.1 s after the quiet never changed afterwards; at 0.0 s two of them did).
    public var recognizerSettleMs: Int
    /// With audio levels, when no such result arrives: close this long after the audio went quiet anyway (the 560 ms
    /// chunk of the recognizer plus its compute time), instead of waiting out `audioWaitCapMs`.
    public var recognizerCatchUpMs: Int
    /// A remote turn with fewer words than this, or one cut off in the middle of a clause (it ends on a conjunction,
    /// article, preposition or subject pronoun), is only closed after `fragmentHoldMs` of silence.
    public var minTurnWords: Int
    public var fragmentHoldMs: Int
    /// Topic trigger (plan F4): remote speech without a question cue that comes close to a bank entry or a fact/glossary
    /// topic becomes a `chip{kind:"topic"}`. Similarity is the bank's n-gram matcher over the last `topicWindowSeconds`
    /// of remote speech with its own, lower threshold and margin.
    public var topicThreshold: Double
    public var topicMargin: Double
    public var topicWindowSeconds: Double
    /// At most one topic chip per this many seconds ...
    public var topicCooldownSeconds: Double
    /// ... and the same id (bank entry, fact or glossary term) at most once per this many seconds.
    public var topicSameIDSeconds: Double
    /// A bank question is shortened to this many characters for the chip label.
    public var topicLabelMax: Int
    public var topicEnabled: Bool
    /// Text guard against speaker bleed (`EchoGuard`): a me result whose words are mostly, in order, what the remote channel
    /// said within `echoWindowSeconds` of it is dropped. Off: `verse-run --no-echo-guard`.
    public var echoGuardEnabled: Bool
    public var echoWindowSeconds: Double
    public var echoSimilarity: Double
    /// A me result with fewer words is never judged an echo (one common word of the question proves nothing).
    public var echoMinWords: Int
    /// A me result that the text guard cannot (yet) call an echo but whose words are mostly what the remote channel said
    /// nearby (`EchoGuard.suspicion` >= `echoHoldSimilarity`: one word, or the microphone recognizer a few words ahead of the
    /// remote one) could be speaker bleed. It opens the me turn at once but may keep the open remote turn open for at most
    /// `meCloseHoldMs` (1200 ms: the recognizers deliver in bursts about a second apart, and the remote words that settle the
    /// question arrive with the next burst; 500 and 800 ms were measured too short): the remote turn closes when the me turn has `echoMinWords` words that are not echo-like, or when the
    /// window is over; a me turn discarded as echo never closes it. 0: close the remote turn at once. A result with fewer
    /// matching words (the owner's own words) closes the remote turn at once as before.
    public var meCloseHoldMs: Int
    public var echoHoldSimilarity: Double
    /// "Follow my answer": also emit a `partial` for the owner's speech (speaker `me`) whenever the open me turn's text
    /// changes, so the brain can see what he is saying while he says it. Off (the default): only the closed `me` turn
    /// goes to the brain, exactly as before. Emitting it changes no turn logic.
    public var emitMePartials: Bool

    public init(ownerName: String = "Alex", ownerAliases: [String] = [], otherNames: [String] = [],
                cueEndpointMs: Int = 300, plainEndpointMs: Int = 600, meEndpointMs: Int = 1200,
                matchThreshold: Double = 0.55, matchMargin: Double = 0.08,
                lang: String = "en", newTurnSilenceMs: Int = 600, meFollowSeconds: Double = 3.0, matchConsecutive: Int = 2,
                speechFloorDbfs: Double = -55, speechAboveFloorDb: Double = 10, speechCeilingDbfs: Double = -42,
                audioWaitCapMs: Int = 1500, burstSettleMs: Int = 80,
                recognizerSettleMs: Int = 100, recognizerCatchUpMs: Int = 800, minTurnWords: Int = 3, fragmentHoldMs: Int = 1200,
                topicThreshold: Double = 0.30, topicMargin: Double = 0.05, topicWindowSeconds: Double = 12,
                topicCooldownSeconds: Double = 12, topicSameIDSeconds: Double = 300, topicLabelMax: Int = 60,
                topicEnabled: Bool = true,
                echoGuardEnabled: Bool = true, echoWindowSeconds: Double = 1.5, echoSimilarity: Double = 0.6, echoMinWords: Int = 2, meCloseHoldMs: Int = 1200, echoHoldSimilarity: Double = 0.4,
                emitMePartials: Bool = false) {
        self.emitMePartials = emitMePartials
        self.ownerName = ownerName
        self.ownerAliases = ownerAliases
        self.otherNames = otherNames
        self.cueEndpointMs = cueEndpointMs
        self.plainEndpointMs = plainEndpointMs
        self.meEndpointMs = meEndpointMs
        self.matchThreshold = matchThreshold
        self.matchMargin = matchMargin
        self.lang = lang
        self.newTurnSilenceMs = newTurnSilenceMs
        self.meFollowSeconds = meFollowSeconds
        self.matchConsecutive = matchConsecutive
        self.speechFloorDbfs = speechFloorDbfs
        self.speechAboveFloorDb = speechAboveFloorDb
        self.speechCeilingDbfs = speechCeilingDbfs
        self.audioWaitCapMs = audioWaitCapMs
        self.burstSettleMs = burstSettleMs
        self.recognizerSettleMs = recognizerSettleMs
        self.recognizerCatchUpMs = recognizerCatchUpMs
        self.minTurnWords = minTurnWords
        self.fragmentHoldMs = fragmentHoldMs
        self.topicThreshold = topicThreshold
        self.topicMargin = topicMargin
        self.topicWindowSeconds = topicWindowSeconds
        self.topicCooldownSeconds = topicCooldownSeconds
        self.topicSameIDSeconds = topicSameIDSeconds
        self.topicLabelMax = topicLabelMax
        self.topicEnabled = topicEnabled
        self.echoGuardEnabled = echoGuardEnabled
        self.echoWindowSeconds = echoWindowSeconds
        self.echoSimilarity = echoSimilarity
        self.echoMinWords = echoMinWords
        self.meCloseHoldMs = meCloseHoldMs
        self.echoHoldSimilarity = echoHoldSimilarity
    }
}

/// Turns the two-channel transcript stream into the events the brain and the overlay need:
/// `partial` for every remote update, a predictive `turn` endpoint, the addressee, bank hits and fact chips.
///
/// Time is session time (`TranscriptEvent.emittedAt`). The engine never reads a clock: `ingest` moves it to the
/// event's time, and `advance(to:)` moves it forward when no event arrives (the endpoint is a timer, so the caller
/// has to poll it, e.g. every 10-20 ms).
public actor TurnEngine {
    /// An event with the session time it was due.
    public struct Timed: Sendable, Equatable {
        public var at: TimeInterval
        public var event: OutboundEvent
    }

    private struct Segment {
        var start: Double, end: Double
        var text: String
        var isFinal: Bool
        /// Session time of the result that last set this segment (the topic trigger's window runs on it).
        var at: Double
    }

    private struct Turn {
        var id: String
        var segments: [Segment] = []
        var startedAt: Double
        var lastChange: Double
        /// Session time of the last recognizer result that went into this turn, also one that changed nothing.
        var lastResult: Double
        var text = ""
        var cue = false
        var audioEnd = 0.0
        var chipIDs: Set<String> = []
        var hitCandidate: String?
        var hitCount = 0
        var sentHitID: String?
        var sentHitScore = 0.0
        /// The brain's paraphrase matcher (F3) hit a bank entry in this turn (`noteBrainBankHit`).
        var brainHit = false
        /// The words of the previous turn that a cumulative recognizer result still repeats at its start.
        var stripPrefix: [String]?
        var stripBelow = 0.0
        var followsMe = false
    }

    private struct Closed {
        var tokens: [String]
        var audioEnd: Double
    }

    private let config: TurnConfig
    private let matcher: MatchCache
    private let facts: FactIndex
    /// What the session knows by name, for short noun-phrase questions ("Notice period").
    private let terms: SessionTerms
    private var topic: TopicTrigger
    private var echo = EchoGuard()
    private var echoDrops: [EchoDrop] = []

    private var now: TimeInterval = 0
    private var remote: Turn?
    private var me: Turn?
    private var closedRemote: Closed?
    private var remoteCount = 0
    private var meCount = 0
    private var lastMeEnd: TimeInterval?
    private var remoteSinceMe = 0
    /// Session time a me result that may be bleed started while a remote turn was open; the remote turn stays open until the
    /// me turn is credible, discarded, or `meCloseHoldMs` passed.
    private var remoteCloseHeldSince: TimeInterval?
    // Remote audio activity (optional input, see noteRemoteLevel).
    private var levelsSeen = false
    private var lastActive: TimeInterval = -.infinity
    private var levelHistory: [(t: TimeInterval, db: Double)] = []

    public init(config: TurnConfig, bank: Bank, facts: FactIndex) {
        self.config = config
        self.matcher = MatchCache(BankMatcher(bank: bank, lang: config.lang))
        self.facts = facts
        self.terms = SessionTerms(bank: bank, facts: facts)
        self.topic = TopicTrigger(config: config, bank: bank, bankMatches: matcher, facts: facts)
    }

    // MARK: public API

    /// The brain found a prepared question in this turn with its paraphrase matcher (`bank_hit` with `via:"embed"`; the
    /// engine only knows its own n-gram hits). The turn already has a card, so it gets no more topic chips and its text
    /// does not stay in the topic window.
    public func noteBrainBankHit(turnID: String) {
        if var t = remote, t.id == turnID {
            t.brainHit = true
            remote = t
        } else {
            topic.forget(turn: turnID)
        }
    }

    /// What the text guard discarded since the last call (for the runner's metric lines).
    public func takeEchoDrops() -> [EchoDrop] {
        defer { echoDrops = [] }
        return echoDrops
    }

    /// Plan signature: the events caused by `e`, in order.
    public func ingest(_ e: TranscriptEvent) -> [OutboundEvent] {
        ingestTimed(e).map(\.event)
    }

    public func ingestTimed(_ e: TranscriptEvent) -> [Timed] {
        var out = advance(to: e.emittedAt)
        let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return out }
        switch e.channel {
        case .remote:
            echo.noteRemote(text: text, start: e.audioStart, end: e.audioEnd, now: now, lang: config.lang)
            out += ingestRemote(e, text: text)
            discardEchoedMeTurn()
        case .me: out += ingestMe(e, text: text)
        }
        // An event can be the one the endpoint was waiting for (the recognizer caught up with the audio).
        return out + advance(to: now)
    }

    /// Feeds the loudness of the remote channel (RMS dBFS over the last ~100 ms; nil for exact silence) and moves
    /// time forward. Call it every 10-20 ms. Once it has been called, the endpoint follows the audio instead of only
    /// the text: the recognizer delivers its volatile text in bursts about a second apart, so "the text did not change
    /// for 300 ms" is true between two bursts while the speaker is still talking.
    public func noteRemoteLevel(_ rmsDbfs: Double?, at t: TimeInterval) -> [Timed] {
        levelsSeen = true
        now = max(now, t)
        if let db = rmsDbfs {
            if levelHistory.last.map({ t - $0.t >= 0.05 }) ?? true { levelHistory.append((t, db)) }
            levelHistory.removeAll { t - $0.t > 8 }
        }
        let floor = levelHistory.map(\.db).min() ?? -.infinity
        let threshold = min(max(floor + config.speechAboveFloorDb, config.speechFloorDbfs), config.speechCeilingDbfs)
        if let db = rmsDbfs, db > threshold { lastActive = max(lastActive, t) }
        return advance(to: t)
    }

    /// Moves time forward and returns the endpoints that came due, each stamped with its due time.
    public func advance(to t: TimeInterval) -> [Timed] {
        now = max(now, t)
        var out: [Timed] = []
        if let held = remoteCloseHeldSince, remote != nil, held + Double(config.meCloseHoldMs) / 1000 <= now {
            // The me result never became credible speech within the window, yet it is still there: Alex is talking.
            out += closeRemote(at: held + Double(config.meCloseHoldMs) / 1000)
        }
        if let r = remote, deadline(r, remote: true) <= now {
            out += closeRemote(at: max(deadline(r, remote: true), r.lastChange), byQuiet: true)
        }
        if let m = me, deadline(m, remote: false) <= now {
            out += closeMe(at: max(deadline(m, remote: false), m.lastChange))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The session time of the next endpoint, nil when no turn is open.
    public var nextDeadline: TimeInterval? {
        let held = remoteCloseHeldSince.flatMap { h in remote == nil ? nil : h + Double(config.meCloseHoldMs) / 1000 }
        return [remote.map { deadline($0, remote: true) }, me.map { deadline($0, remote: false) }, held].compactMap { $0 }.min()
    }

    /// End of stream: closes whatever is open now.
    public func flush(at t: TimeInterval? = nil) -> [Timed] {
        let at = max(t ?? now, now)
        now = at
        var out: [Timed] = []
        if remote != nil { out += closeRemote(at: at) }
        if me != nil { out += closeMe(at: at) }
        return out
    }

    /// The text of the open remote turn, for logs and tests.
    public var openRemoteText: String? { remote?.text }

    // MARK: endpoint

    private func endpointMs(_ t: Turn) -> Int {
        t.cue && Cues.endsComplete(t.text, lang: config.lang) ? config.cueEndpointMs : config.plainEndpointMs
    }

    /// A remote turn that is not finished yet: too short or cut off in the middle of a clause.
    private func isFragment(_ t: Turn) -> Bool {
        Cues.isFragment(t.text, lang: config.lang, minWords: config.minTurnWords)
    }

    /// When the turn is over. Text only: `T` after the last text change. With audio levels: `T` after the remote audio
    /// went quiet, once the recognizer has processed that audio, and never later than `audioWaitCapMs` after the last
    /// text change. A fragment waits `fragmentHoldMs` instead of `T` (and its cap moves out by the same amount).
    ///
    /// "The recognizer has processed the audio" is not "its result range reaches the end of the audio": the range ends
    /// at the last token, which for an RNN-T decoder lies up to half a second before the end of the sound, so that
    /// condition never held and every turn waited out the cap. The recognizer decodes whole chunks and delivers a result
    /// per chunk (a final too), so a result that arrived `recognizerSettleMs` after the quiet began has seen the end of
    /// the speech. When none arrives, `recognizerCatchUpMs` after the quiet is long enough for one chunk.
    private func deadline(_ t: Turn, remote isRemote: Bool) -> TimeInterval {
        var T = Double(isRemote ? endpointMs(t) : config.meEndpointMs) / 1000
        let fragment = isRemote && isFragment(t)
        if fragment { T = max(T, Double(config.fragmentHoldMs) / 1000) }
        let textDue = (isRemote ? t.lastChange : max(t.lastChange, t.lastResult)) + T
        guard isRemote, levelsSeen, lastActive.isFinite, lastActive >= t.startedAt - 3 else { return textDue }
        let cap = t.lastChange + (fragment ? T : 0) + max(T, Double(config.audioWaitCapMs) / 1000)
        let caughtUp = t.audioEnd >= lastActive - 0.05 || t.lastResult >= lastActive + Double(config.recognizerSettleMs) / 1000
        var due = lastActive + (caughtUp ? T : max(T, Double(config.recognizerCatchUpMs) / 1000))
        due = max(due, t.lastChange + Double(config.burstSettleMs) / 1000)
        return min(due, cap)
    }

    // MARK: remote channel

    private func ingestRemote(_ e: TranscriptEvent, text: String) -> [Timed] {
        var out: [Timed] = []
        // A remote event does not close an open me turn. Whoever holds the floor keeps it until their own quiet endpoint:
        // when both talk at once, every event of one side used to close the other side's turn, which chopped a question
        // into pieces and the owner's answer into duplicate me turns (two-track replay, eval/twotrack/t01.json).

        var (start, end, body) = (e.audioStart, e.audioEnd, text)

        // Which earlier words does this result repeat? Cumulative results keep the words of a turn that is already
        // closed at their start; a turn opened by such a result remembers them and strips them from every update.
        var prefix: (tokens: [String], below: Double)?
        if let turn = remote, let p = turn.stripPrefix {
            prefix = (p, turn.stripBelow)
        } else if remote == nil, let closed = closedRemote {
            // Late recognizer output for a turn that is already closed (the final that settles it, a correction).
            if end <= closed.audioEnd + Self.slack { return out }
            prefix = (closed.tokens, closed.audioEnd)
        }
        var stripped: (tokens: [String], below: Double)?
        if let p = prefix, start < p.below - Self.slack, let rest = Self.dropPrefix(body, prefix: p.tokens, lang: config.lang) {
            if rest.isEmpty { return out }          // nothing new beyond the closed turn
            body = rest
            start = max(start, p.below)
            end = max(end, start)
            stripped = p
        }

        if remote == nil {
            remoteCount += 1
            var t = Turn(id: "r\(remoteCount)", startedAt: now, lastChange: now, lastResult: now)
            // Alex is still talking, or stopped a moment ago: this question follows his speech.
            t.followsMe = remoteSinceMe == 0 && (me != nil || lastMeEnd.map { now - $0 <= config.meFollowSeconds } == true)
            if let p = stripped { t.stripPrefix = p.tokens; t.stripBelow = p.below }
            remote = t
        }
        guard var turn = remote else { return out }

        // A long gap before non-overlapping audio: the previous words were a turn of their own.
        // (A cut-off turn only splits after the longer fragment silence: "Okay so we" + 0.8 s + "shipped it" is one turn.)
        let gapNeeded = Double(isFragment(turn) ? max(config.newTurnSilenceMs, config.fragmentHoldMs) : config.newTurnSilenceMs) / 1000
        if !turn.segments.isEmpty, config.newTurnSilenceMs > 0,
           start - turn.audioEnd >= gapNeeded,
           !turn.segments.contains(where: { Self.replaces($0, start: start, end: end) }) {
            out += closeRemote(at: now)
            remoteCount += 1
            var t = Turn(id: "r\(remoteCount)", startedAt: now, lastChange: now, lastResult: now)
            t.followsMe = false
            remote = t
            turn = t
        }
        return out + applyRemote(&turn, start: start, end: end, body: body, e: e)
    }

    private func applyRemote(_ turn: inout Turn, start: Double, end: Double, body: String, e: TranscriptEvent) -> [Timed] {
        let lang = config.lang
        let changed = Self.apply(&turn, start: start, end: end, text: body, isFinal: e.isFinal, now: now)
        turn.lastResult = max(turn.lastResult, e.emittedAt)
        remote = turn
        guard changed || !e.isFinal else { return [] }
        var out: [Timed] = []
        turn.cue = Cues.hasCue(turn.text, lang: lang)
        remote = turn
        out.append(Timed(at: now, event: .partial(turnID: turn.id, speaker: .remote, text: turn.text, cue: turn.cue, tAudioEnd: e.audioEnd)))
        // Fact chips: once per fact per turn.
        for c in facts.chips(in: turn.text) where !turn.chipIDs.contains(c.id) {
            turn.chipIDs.insert(c.id)
            out.append(Timed(at: now, event: .chip(turnID: turn.id, kind: c.kind, text: c.text, sourceRef: c.sourceRef, factID: c.id)))
        }
        // Bank hit: the same entry, clear of the runner-up, on consecutive events.
        if let cand = bestCandidate(turn.text) {
            if turn.hitCandidate == cand.id { turn.hitCount += 1 } else { turn.hitCandidate = cand.id; turn.hitCount = 1 }
            if turn.hitCount >= config.matchConsecutive,
               turn.sentHitID != cand.id || abs(cand.score - turn.sentHitScore) >= 0.08 {
                turn.sentHitID = cand.id
                turn.sentHitScore = cand.score
                out.append(Timed(at: now, event: .bankHit(turnID: turn.id, bankID: cand.id, score: cand.score)))
            }
        } else {
            turn.hitCandidate = nil
            turn.hitCount = 0
        }
        // Topic chip: a statement near a prepared topic. Never in a turn that has a question cue or a bank hit (or a
        // hit candidate that may become one): those already produce a card.
        if !turn.cue, turn.hitCandidate == nil, turn.sentHitID == nil, !turn.brainHit,
           let hit = topic.evaluate(now: now, current: Self.pieces(of: turn), skip: turn.chipIDs) {
            out.append(Timed(at: now, event: .chip(turnID: turn.id, kind: "topic", text: hit.text, sourceRef: hit.sourceRef, factID: hit.id)))
        }
        remote = turn
        return out
    }

    private static func pieces(of turn: Turn) -> [TopicTrigger.Piece] {
        turn.segments.map { TopicTrigger.Piece(at: $0.at, text: $0.text, turn: turn.id) }
    }

    /// The best bank entry for the turn text (whole text or its last sentence, whichever matches better), or nil
    /// when it is below the threshold or too close to the runner-up.
    private func bestCandidate(_ text: String) -> BankMatcher.Candidate? {
        guard !matcher.isEmpty else { return nil }
        var texts = [text]
        let sentences = text.split(whereSeparator: { ".?!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if sentences.count > 1, let last = sentences.last { texts.append(last) }
        var best: [BankMatcher.Candidate] = []
        for t in texts {
            let top = matcher.top2(t)
            if let f = top.first, f.score > (best.first?.score ?? -1) { best = top }
        }
        guard let first = best.first, first.score >= config.matchThreshold else { return nil }
        if best.count > 1, first.score - best[1].score < config.matchMargin { return nil }
        return first
    }

    /// `byQuiet`: the turn ended because the audio went quiet (not because the owner or a new utterance started), so
    /// the end of the sound is known and becomes the turn's `t_audio_end`.
    private func closeRemote(at t: TimeInterval, byQuiet: Bool = false) -> [Timed] {
        guard let turn = remote else { return [] }
        remote = nil
        remoteCloseHeldSince = nil
        if !turn.cue, turn.sentHitID == nil, !turn.brainHit { topic.noteClosed(Self.pieces(of: turn), now: now) }
        let tokens = Text.tokens(turn.text, lang: config.lang)
        // A turn that was opened by stripping an earlier turn's words keeps them in front, so the chain of turns of one
        // cumulative recognizer result can be stripped again.
        closedRemote = Closed(tokens: (turn.stripPrefix ?? []) + tokens, audioEnd: turn.audioEnd)
        // Nothing but fillers: not worth a model call.
        if tokens.isEmpty || Cues.isOnlyHesitation(turn.text, lang: config.lang) { return [] }
        remoteSinceMe += 1
        let who = classify(turn)
        // The recognizer's range ends at its last token, up to half a second before the sound ended. Half the 100 ms
        // level window is the uncertainty of `lastActive`.
        var audioEnd = turn.audioEnd
        if byQuiet, levelsSeen, lastActive.isFinite, lastActive >= turn.startedAt - 3 { audioEnd = max(audioEnd, lastActive - 0.05) }
        return [Timed(at: t, event: .turn(turnID: turn.id, speaker: .remote, text: turn.text, addressee: who, tAudioEnd: audioEnd,
                                          kind: Cues.kind(of: turn.text, lang: config.lang, minWords: config.minTurnWords, terms: terms)))]
    }

    // MARK: me channel

    private func ingestMe(_ e: TranscriptEvent, text: String) -> [Timed] {
        var out: [Timed] = []
        // Speaker bleed: the remote voice in the microphone is not Alex. Dropped before it can open a me turn or close the
        // remote one; an open me turn that started inside the same echo goes with it.
        if config.echoGuardEnabled,
           let sim = echo.similarity(text: text, start: e.audioStart, end: e.audioEnd, windowSeconds: config.echoWindowSeconds, minWords: config.echoMinWords, lang: config.lang),
           sim >= config.echoSimilarity {
            echoDrops.append(EchoDrop(text: text, isFinal: e.isFinal, audioStart: e.audioStart, audioEnd: e.audioEnd, at: now, similarity: sim))
            if let m = me, let first = m.segments.first, abs(first.start - e.audioStart) < 0.4 { discardMe() }
            return out
        }
        // The owner starts talking: the remote question is over, right now. Only the first event of a me turn does this;
        // the later events of the same utterance (Alex talking over the interviewer) leave the remote turn alone.
        // Exception: a result that is mostly words the remote channel said nearby may be the remote voice coming out of the
        // speakers that the guard cannot call yet (one word proves nothing; or the microphone recognizer is ahead of the
        // remote one and the rest of the words has not arrived). The remote turn then stays open for `meCloseHoldMs` at most;
        // a me turn that turns out to be real speech closes it, one discarded as echo never does.
        if me == nil, remote != nil {
            if config.echoGuardEnabled, config.meCloseHoldMs > 0,
               echo.suspicion(text: text, start: e.audioStart, end: e.audioEnd, windowSeconds: config.echoWindowSeconds, lang: config.lang) >= config.echoHoldSimilarity {
                remoteCloseHeldSince = now
            } else {
                out += closeRemote(at: now)
            }
        }
        if me == nil {
            meCount += 1
            me = Turn(id: "m\(meCount)", startedAt: now, lastChange: now, lastResult: now)
        }
        guard var turn = me else { return out }
        let changed = Self.apply(&turn, start: e.audioStart, end: e.audioEnd, text: text, isFinal: e.isFinal, now: now)
        turn.lastResult = max(turn.lastResult, e.emittedAt)
        me = turn
        if config.emitMePartials, changed {
            out.append(Timed(at: now, event: .partial(turnID: turn.id, speaker: .me, text: turn.text, cue: false, tAudioEnd: e.audioEnd)))
        }
        // The held result grew into speech that is not echo-like: the question was interrupted when it started.
        if remoteCloseHeldSince != nil, remote != nil, let first = turn.segments.first,
           Text.tokens(turn.text, lang: config.lang).count >= config.echoMinWords,
           echo.suspicion(text: turn.text, start: first.start, end: turn.audioEnd, windowSeconds: config.echoWindowSeconds, lang: config.lang) < config.echoHoldSimilarity {
            out += closeRemote(at: now)
        }
        return out
    }

    /// Drops the open me turn unsent (it was bleed); a remote turn kept open for it stays whole.
    private func discardMe() {
        me = nil
        remoteCloseHeldSince = nil
    }

    /// The microphone recognizer can be a result ahead of the remote one, so an echo is sometimes not recognizable as such
    /// until the remote words arrive. Each remote result therefore re-checks the open me turn; one that turns out to be an
    /// echo is discarded unsent.
    private func discardEchoedMeTurn() {
        guard config.echoGuardEnabled, let m = me, let first = m.segments.first else { return }
        guard let sim = echo.similarity(text: m.text, start: first.start, end: m.audioEnd, windowSeconds: config.echoWindowSeconds, minWords: config.echoMinWords, lang: config.lang),
              sim >= config.echoSimilarity else { return }
        echoDrops.append(EchoDrop(text: m.text, isFinal: false, audioStart: first.start, audioEnd: m.audioEnd, at: now, similarity: sim))
        discardMe()
    }

    private func closeMe(at t: TimeInterval) -> [Timed] {
        guard let turn = me else { return [] }
        me = nil
        remoteCloseHeldSince = nil
        lastMeEnd = turn.lastChange
        remoteSinceMe = 0
        guard !Text.tokens(turn.text, lang: config.lang).isEmpty else { return [] }
        return [Timed(at: t, event: .turn(turnID: turn.id, speaker: .me, text: turn.text, addressee: .unknown, tAudioEnd: turn.audioEnd,
                                          kind: Cues.kind(of: turn.text, lang: config.lang, minWords: config.minTurnWords, terms: terms)))]
    }

    // MARK: addressee

    private func classify(_ turn: Turn) -> Addressee {
        let lang = config.lang
        let toks = Text.foldedTokens(turn.text)
        func names(_ n: String) -> Bool { FactIndex.contains(toks, Text.foldedTokens(n)) }
        if ([config.ownerName] + config.ownerAliases).contains(where: { !$0.isEmpty && names($0) }) { return .me }
        if config.otherNames.contains(where: { !$0.isEmpty && names($0) }) { return .other }
        if Self.hasSecondPerson(toks, lang: lang) { return .me }
        if turn.followsMe { return .me }
        return .unknown
    }

    static func hasSecondPerson(_ toks: [String], lang: String) -> Bool {
        switch lang {
        case "it":
            return toks.contains { ["tu", "lei", "ti", "le"].contains($0) }
        case "tr":
            return toks.contains { t in
                if ["sen", "siz", "senin", "sizin", "seni", "sizi", "sana", "size"].contains(t) { return true }
                return t.count >= 6 && ["sin", "sun", "sünüz", "siniz", "sunuz", "sınız", "sın", "sün"].contains { t.hasSuffix($0) }
            }
        default:
            return toks.contains { ["you", "your", "yours", "yourself", "you're", "you'd", "you've", "you'll"].contains($0) }
        }
    }

    // MARK: segments

    static let slack = 0.08

    /// Does a new result (start...end) replace the stored segment? Volatile results grow the same range; a final
    /// settles it; a result starting where the old one ended is new material.
    private static func replaces(_ old: Segment, start: Double, end: Double) -> Bool {
        let overlap = min(old.end, end) - max(old.start, start)
        if overlap <= 0 { return abs(old.start - start) < 0.02 }
        let shortest = max(min(old.end - old.start, end - start), 0.02)
        return overlap >= 0.5 * shortest || (old.start >= start - 0.05 && old.start < end)
    }

    /// Returns whether the assembled text changed.
    private static func apply(_ turn: inout Turn, start: Double, end: Double, text: String, isFinal: Bool, now: Double) -> Bool {
        turn.segments.removeAll { replaces($0, start: start, end: end) }
        turn.segments.append(Segment(start: start, end: end, text: text, isFinal: isFinal, at: now))
        turn.segments.sort { $0.start < $1.start }
        let joined = turn.segments.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        turn.audioEnd = max(turn.audioEnd, end)
        if joined != turn.text {
            turn.text = joined
            turn.lastChange = now
            return true
        }
        return false
    }

    /// `body` without its first `prefix.count` words when those words match the prefix (within a few edits, since a
    /// final may correct them); nil when it does not start with the prefix.
    static func dropPrefix(_ body: String, prefix: [String], lang: String) -> String? {
        let chunks = body.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = 0
        var head: [String] = []
        var i = 0
        while i < chunks.count, seen < prefix.count {
            let t = Text.tokens(chunks[i], lang: lang)
            head += t
            seen += t.count
            i += 1
        }
        guard seen >= prefix.count || seen > 0 else { return nil }
        let k = prefix.count
        let allowed = max(1, k / 5)
        guard Text.editDistance(Array(head.prefix(k)), prefix) <= allowed, head.count >= max(1, k - allowed) else { return nil }
        return chunks[i...].joined(separator: " ")
    }
}
