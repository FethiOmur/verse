import Foundation

/// Tuning of the interim AUTO language mode (spec 2.5, "interim AUTO (before C3)").
public struct AutoLangConfig: Sendable, Equatable {
    /// The languages AUTO may pick.
    public var allowed = LanguageID.supported
    /// A switch needs this many judged finals in a row ...
    public var minConsecutive = 2
    /// ... or this many seconds of speech judged the same way (one long answer is enough).
    public var minSpeechSeconds = 6.0
    /// No second switch this soon after one (or after a pin).
    public var minDwell = 10.0
    /// Text-language probability times the engine's confidence a final needs before it counts for a language.
    public var minScore = 0.6
    /// A shadow recognizer's text must beat the main recognizer's own text by this much to outvote it.
    public var margin = 0.1
    /// How long a main final waits for the shadow's final of the same speech before it is judged: past the Apple recognizers'
    /// final lag (p90 1.3 s, bench/stt-local), so a shadow text is rarely judged before the main text it competes with.
    public var pairGrace = 1.5
    /// The `me` channel votes only when the remote channel has been silent this long (the remote has priority).
    public var meQuietSeconds = 20.0
    /// Shadow finals older than this are forgotten.
    public var keepSeconds = 30.0

    public init() {}
}

/// One final result a recognizer produced, as the detector sees it. Times are run seconds.
public struct LangFinal: Sendable, Equatable {
    public var channel: Channel
    /// The language of the recognizer that produced `text` (the session's for the main one, a candidate's for the shadow).
    public var lang: String
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// The engine's mean confidence (0...1) where it reports one.
    public var confidence: Double?
    /// True for the shadow recognizer.
    public var shadow: Bool

    public init(channel: Channel, lang: String, text: String, start: TimeInterval, end: TimeInterval,
                confidence: Double? = nil, shadow: Bool = false) {
        self.channel = channel
        self.lang = lang
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.shadow = shadow
    }
}

/// A switch the detector decided on.
public struct AutoLangDecision: Sendable, Equatable {
    public var from: String
    public var to: String
    /// Finals in a row that were judged `to`.
    public var finals: Int
    /// Seconds of speech in that run.
    public var seconds: Double
    public var channel: Channel
}

/// Decides when the language of a call has changed, from the finals of the main recognizer (which speaks the current
/// language) and of a shadow recognizer (which runs a candidate language on the same audio). Pure state machine over run
/// time: no clocks, no audio, no recognizers, so the hysteresis is testable with scripted finals.
///
/// Each main final is judged once, after `pairGrace` has passed for the shadow's final of the same speech to arrive. A final
/// votes for a language, or abstains:
/// - the text of the main final is identified (`LanguageID`, probability times engine confidence);
/// - the shadow text counts for its language only when it beats the main text by `margin` (a clean candidate-language text
///   against a garbled current-language one);
/// - a vote for the current language ends any run of votes for another one.
/// The language switches when the run of votes for one other language reaches `minConsecutive` finals or `minSpeechSeconds`,
/// not within `minDwell` of the last switch, and only while `auto` is on.
public struct AutoLanguageDetector: Sendable {
    public var config: AutoLangConfig
    /// The language the recognizers run in now.
    public private(set) var current: String
    /// Off: the language is pinned and nothing is ever decided.
    public private(set) var auto: Bool
    /// A shadow recognizer is running, so main finals wait for it. Without one they are judged at once.
    public var shadowActive = false
    public private(set) var lastSwitchAt: TimeInterval?

    private struct Run { var lang: String; var finals: Int; var seconds: Double; var channel: Channel }
    private var run: Run?
    private var units: [LangFinal] = []         // main finals waiting for their shadow
    private var shadows: [(f: LangFinal, used: Bool)] = []
    private var lastRemoteEnd: TimeInterval?
    private var recentVotes: [String] = []

    public init(current: String, auto: Bool, config: AutoLangConfig = AutoLangConfig()) {
        self.current = current
        self.auto = auto
        self.config = config
    }

    /// The finals judged so far in the open run (for the metric lines).
    public var openRun: (lang: String, finals: Int, seconds: Double)? { run.map { ($0.lang, $0.finals, $0.seconds) } }

    /// Turns AUTO on or off. A run of votes from before is forgotten either way.
    public mutating func setAuto(_ on: Bool) {
        guard on != auto else { return }
        auto = on
        run = nil
        units = []
        shadows = []
    }

    /// The recognizers now run in `lang` (a pin from the chip, or a switch applied elsewhere). Counts as a switch for the dwell.
    public mutating func setCurrent(_ lang: String, at t: TimeInterval) {
        guard lang != current else { return }
        current = lang
        lastSwitchAt = t
        run = nil
        units = []
        shadows = []
    }

    /// A switch that was decided could not be applied: back to the old language, without a dwell.
    public mutating func revert(to lang: String, lastSwitchAt previous: TimeInterval?) {
        current = lang
        lastSwitchAt = previous
        run = nil
    }

    /// Candidate languages for the shadow, most likely first: the language of the open run, then the ones voted for lately,
    /// then the default order (en, it, tr). Never the current language.
    public func shadowOrder() -> [String] {
        var order: [String] = []
        if let r = run { order.append(r.lang) }
        order += recentVotes.reversed()
        order += LanguageID.supported
        var seen = Set<String>([current])
        return order.filter { config.allowed.contains($0) && seen.insert($0).inserted }
    }

    // MARK: input

    /// A final result of the main or the shadow recognizer. Returns a language the shadow should look at next, when the
    /// main final's text hints at one (garbled current-language text that looks like another language).
    @discardableResult
    public mutating func note(_ f: LangFinal) -> String? {
        guard auto else { return nil }
        if f.shadow {
            guard f.channel == .remote, f.lang != current else { return nil }
            shadows.append((f, false))
            return nil
        }
        units.append(f)
        if let top = LanguageID.hypotheses(f.text, allowed: config.allowed).first(where: { $0.lang != current }), top.confidence >= 0.25 {
            return top.lang
        }
        return nil
    }

    /// Judges what is due at run time `t` and returns the switch, if one is decided. The detector has then already moved on
    /// to the new language (`current`); call `revert` if the switch cannot be applied.
    public mutating func advance(to t: TimeInterval) -> AutoLangDecision? {
        guard auto else { return nil }
        // Main finals first, oldest first, each once its shadow had time to arrive.
        units.sort { $0.end < $1.end }
        var rest: [LangFinal] = []
        for u in units {
            if shadowActive && u.channel == .remote && t < u.end + config.pairGrace { rest.append(u); continue }
            vote(for: u)
        }
        units = rest
        // Shadow finals nobody overlapped (the main recognizer heard nothing in a language it does not speak).
        for i in shadows.indices where !shadows[i].used && t >= shadows[i].f.end + config.pairGrace {
            shadows[i].used = true
            vote(for: nil, shadow: shadows[i].f)
        }
        shadows.removeAll { $0.f.end < t - config.keepSeconds }

        guard let r = run, r.lang != current, config.allowed.contains(r.lang),
              r.finals >= config.minConsecutive || r.seconds >= config.minSpeechSeconds else { return nil }
        if let last = lastSwitchAt, t - last < config.minDwell { return nil }
        let d = AutoLangDecision(from: current, to: r.lang, finals: r.finals, seconds: r.seconds, channel: r.channel)
        current = r.lang
        lastSwitchAt = t
        run = nil
        units = []
        shadows = []
        return d
    }

    // MARK: judging

    private func score(_ text: String, lang: String, confidence: Double?) -> Double {
        let p = LanguageID.hypotheses(text, allowed: config.allowed).first { $0.lang == lang }?.confidence ?? 0
        return p * (confidence ?? 1)
    }

    private mutating func vote(for main: LangFinal?, shadow lone: LangFinal? = nil) {
        // The shadow finals that overlap this main final in time.
        var shadowBest: (lang: String, score: Double)?
        if let u = main {
            for i in shadows.indices where u.channel == .remote {
                let s = shadows[i].f
                let overlap = min(u.end, s.end) - max(u.start, s.start)
                guard overlap > 0.2 else { continue }
                shadows[i].used = true
                let sc = score(s.text, lang: s.lang, confidence: s.confidence)
                if sc > (shadowBest?.score ?? 0) { shadowBest = (s.lang, sc) }
            }
        } else if let s = lone {
            shadowBest = (s.lang, score(s.text, lang: s.lang, confidence: s.confidence))
        }
        let channel = main?.channel ?? .remote
        let start = main?.start ?? lone!.start
        let end = main?.end ?? lone!.end

        // Main text: its best language and score.
        var primary: (lang: String, score: Double)?
        if let u = main {
            for h in LanguageID.hypotheses(u.text, allowed: config.allowed) {
                let sc = h.confidence * (u.confidence ?? 1)
                if sc > (primary?.score ?? 0) { primary = (h.lang, sc) }
            }
        }
        let sP = primary?.score ?? 0
        var voted: String?
        if let p = primary, sP >= config.minScore, shadowBest.map({ $0.lang == p.lang || $0.score < sP + config.margin }) ?? true {
            voted = p.lang
        } else if let s = shadowBest, s.score >= config.minScore, s.score >= sP + config.margin || sP < config.minScore {
            voted = s.lang
        }

        if channel == .remote { lastRemoteEnd = max(lastRemoteEnd ?? end, end) }
        guard let lang = voted else { return }     // abstained: neither starts nor ends a run
        // The remote has priority: the microphone votes only after the remote has been quiet for a while.
        if channel == .me, let r = lastRemoteEnd, end - r < config.meQuietSeconds { return }
        recentVotes.append(lang)
        if recentVotes.count > 4 { recentVotes.removeFirst() }
        if lang == current {
            run = nil
        } else if run?.lang == lang {
            run!.finals += 1
            run!.seconds += max(0, end - start)
        } else {
            run = Run(lang: lang, finals: 1, seconds: max(0, end - start), channel: channel)
        }
    }
}
