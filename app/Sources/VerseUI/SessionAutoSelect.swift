import Foundation
import VerseMeet

/// Which session is Start for right now: the pure rules. `SessionSelector` applies them. Time, events and sessions come in, so every
/// rule is a table test.
///
/// - The target is the real meeting (`RealMeeting`) that is running now or comes next within `lookahead`, ranked by `MeetingRanking`.
/// - A live manual pick is kept. Otherwise the target's matched session is selected. A target without a session, or no target, keeps
///   the current selection (owner decision 1: "Next: <title> — not prepared" is shown, nothing is switched).
public enum SessionAutoSelect {
    /// How far ahead the next meeting is looked for (owner decision 2: the same 36 hours as Up next).
    public static let lookahead: TimeInterval = 36 * 3600
    /// A manual pick made while no meeting was ahead lasts until one appears, or this long.
    public static let manualWithoutTargetLasts: TimeInterval = 12 * 3600

    /// The meeting the selection is for: a real meeting (someone else on the invite, or a call link) that has not ended and starts
    /// within `lookahead`; the running one, else the next, with the back-to-back handover. Focus blocks and solo entries never are.
    public static func target(now: Date, events: [MeetingEvent], lookahead: TimeInterval = lookahead) -> MeetingEvent? {
        let eligible = events.filter { $0.end > now && $0.start <= now.addingTimeInterval(lookahead) && RealMeeting.isReal($0) }
        return MeetingRanking.best(eligible, now: now)
    }

    public enum Reason: Equatable, Sendable {
        /// The target's own session (occurrence key of the target).
        case nextMeeting(String)
        /// A live manual pick holds.
        case manual
        /// The target (its occurrence key) has no prepared session: the selection is kept.
        case notPrepared(String)
        /// No meeting within the lookahead (or the calendar is off): the selection is kept.
        case noMeeting
        /// The selected session disappeared: the target's session, else the newest one, was taken.
        case fallback
    }

    public struct Decision: Equatable, Sendable {
        /// The session Start should use; nil keeps the current one.
        public var select: String?
        public var reason: Reason
        public var target: MeetingEvent?
        /// The target's match, when it has one (also when a manual pick holds).
        public var match: SessionMatch?
    }

    public static func pick(now: Date, events: [MeetingEvent], matcher: SessionMatcher, manual: ManualChoice?) -> Decision {
        let t = target(now: now, events: events)
        let m = t.flatMap { matcher.match($0) }
        if let manual, matcher.sessions.contains(manual.session), manual.isActive(now: now, targetKey: t?.occurrenceKey) {
            return Decision(select: nil, reason: .manual, target: t, match: m)
        }
        guard let t else { return Decision(select: nil, reason: .noMeeting, target: nil, match: nil) }
        guard let m else { return Decision(select: nil, reason: .notPrepared(t.occurrenceKey), target: t, match: nil) }
        return Decision(select: m.session, reason: .nextMeeting(t.occurrenceKey), target: t, match: m)
    }

    /// The selection is gone (trashed, renamed): the target's session, else the newest session by creation time (ties: A-Z first),
    /// else nil (no sessions). Never asks the calendar: `events` are the ones read last.
    public static func fallback(now: Date, events: [MeetingEvent], matcher: SessionMatcher, createdAt: [String: Date]) -> String? {
        if let t = target(now: now, events: events), let m = matcher.match(t) { return m.session }
        return newest(matcher.sessions, createdAt: createdAt)
    }

    public static func newest(_ sessions: [String], createdAt: [String: Date]) -> String? {
        sessions.max { a, b in
            let da = createdAt[a] ?? .distantPast, db = createdAt[b] ?? .distantPast
            return da != db ? da < db : a > b
        }
    }

    /// When each session was made: `meta.json` `created_at` (ISO 8601, an absolute time), else the modification time of `meta.json`,
    /// `pack.md` or the folder.
    public static func createdAt(sessions: [String], root: URL) -> [String: Date] {
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        var out: [String: Date] = [:]
        for name in sessions {
            let dir = SessionCatalog.url(name, root: root)
            let meta = dir.appendingPathComponent("meta.json")
            var created: Date?
            if let d = try? Data(contentsOf: meta), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let s = o["created_at"] as? String {
                let f = ISO8601DateFormatter()
                created = f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) }()
            }
            out[name] = created ?? mtime(meta) ?? mtime(dir.appendingPathComponent("pack.md")) ?? mtime(dir)
        }
        return out
    }
}

/// A session he picked by hand (the menu, the Home popup, Use for Start, Open in Up next). It holds while the meeting it was picked
/// for is still the target; picked with no meeting ahead, it holds until one appears or for 12 hours. Persisted, so a relaunch keeps it.
public struct ManualChoice: Codable, Equatable, Sendable {
    public var session: String
    /// The target's occurrence key when it was picked; nil when no meeting was ahead.
    public var targetKey: String?
    public var at: Date

    public init(session: String, targetKey: String?, at: Date) {
        self.session = session
        self.targetKey = targetKey
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case session, targetKey = "target_key", at }

    public func isActive(now: Date, targetKey current: String?) -> Bool {
        if let targetKey { return targetKey == current }
        return current == nil && now.timeIntervalSince(at) < SessionAutoSelect.manualWithoutTargetLasts
    }
}
