import Foundation

/// One rule for "which calendar event is the meeting now": the call detector's attach, Start now and the session auto-select all
/// use it, so they never disagree. Pure; time comes in.
///
/// An event running now beats one that has not started, except at a back-to-back handover: when the next event starts within
/// `handoverLead` and the running one either ends within `handoverTail` or started `staleAfter` or more ago, the next one wins
/// (joining an 11:00 call at 10:52 while a 10:00-11:00 event is still on the calendar attaches the 11:00 one).
public enum MeetingRanking {
    public static let handoverLead: TimeInterval = 10 * 60
    public static let handoverTail: TimeInterval = 10 * 60
    public static let staleAfter: TimeInterval = 45 * 60

    /// `events` best first. Running events first (the one that started last first), then the others by distance of their start
    /// from `now` (ties by start, then id), with the handover applied on top. Callers filter the window themselves.
    public static func ordered(_ events: [MeetingEvent], now: Date) -> [MeetingEvent] {
        func running(_ e: MeetingEvent) -> Bool { e.start <= now && e.end > now }
        var out = events.sorted { a, b in
            let ra = running(a), rb = running(b)
            if ra != rb { return ra }
            let da = abs(a.start.timeIntervalSince(now)), db = abs(b.start.timeIntervalSince(now))
            if da != db { return da < db }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
        guard let r = out.first, running(r),
              let n = out.filter({ $0.start > now }).min(by: { ($0.start, $0.id) < ($1.start, $1.id) }) else { return out }
        if handsOver(running: r, next: n, now: now), let i = out.firstIndex(of: n) {
            out.remove(at: i)
            out.insert(n, at: 0)
        }
        return out
    }

    /// The best event, or nil for none.
    public static func best(_ events: [MeetingEvent], now: Date) -> MeetingEvent? { ordered(events, now: now).first }

    /// The next event takes over from the running one.
    public static func handsOver(running r: MeetingEvent, next n: MeetingEvent, now: Date) -> Bool {
        guard now >= n.start.addingTimeInterval(-handoverLead) else { return false }
        return r.end.timeIntervalSince(now) <= handoverTail || now.timeIntervalSince(r.start) >= staleAfter
    }
}
