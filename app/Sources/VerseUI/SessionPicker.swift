import Foundation
import VerseMeet

/// What the menu-bar Session picker and the Home "Session for Start" popup show (G5): one model, so both list the same rows in the
/// same order. Pure: time, events, matches and the session facts come in.
///
/// - "Next meetings": the sessions matched to the real meetings of the lookahead (`SessionSelector.upcoming` / `matches`), in event
///   order, each once, labelled "Today 14:00 · <meeting title>".
/// - "Other sessions": every other session, newest first (created time, ties A-Z); a session prepared from an event is labelled by
///   the event's title and date (its `event.json`), others by their folder name.
/// - The selected row carries why it is selected: "(next meeting)" when it is the target meeting's session, "(chosen)" for a live
///   manual pick.
/// - The target meeting without a session gets a line of its own: "Next: <title> <time> — not prepared" (or "— preparing…").
public struct SessionPickerModel: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        case nextMeeting, chosen
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var session: String
        /// The row's text without the mark.
        public var label: String
        public var mark: Mark?
        /// The meeting this row is listed for (Next meetings only).
        public var event: MeetingEvent?
        public var id: String { session }

        /// The text the picker shows: the label, then the mark.
        public var display: String {
            switch mark {
            case .nextMeeting?: return L10n.tr("\(label) (next meeting)")
            case .chosen?: return L10n.tr("\(label) (chosen)")
            case nil: return label
            }
        }
    }

    public struct NotPrepared: Equatable, Sendable {
        public var event: MeetingEvent
        /// The background prep (or a Prepare click) is working on it.
        public var preparing: Bool
        public var label: String
    }

    public var nextMeetings: [Row]
    public var others: [Row]
    public var notPrepared: NotPrepared?

    public var rows: [Row] { nextMeetings + others }

    /// The label of `session`'s row (no mark), or nil when it is not listed.
    public func label(of session: String) -> String? { rows.first { $0.session == session }?.label }

    public static func build(now: Date, sessions: [String], upcoming: [MeetingEvent], matches: [String: SessionMatch],
                             target: MeetingEvent?, selected: String, manual: ManualChoice?, sidecars: [String: EventSidecar],
                             createdAt: [String: Date], preparing: Set<String>, calendar: Calendar = .current) -> SessionPickerModel {
        let exists = Set(sessions)
        let targetSession = target.flatMap { matches[$0.occurrenceKey]?.session }.flatMap { exists.contains($0) ? $0 : nil }
        func mark(_ s: String) -> Mark? {
            guard s == selected else { return nil }
            if s == targetSession { return .nextMeeting }
            if let manual, manual.session == s { return .chosen }
            return nil
        }
        var listed = Set<String>()
        var next: [Row] = []
        for e in upcoming.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            guard let s = matches[e.occurrenceKey]?.session, exists.contains(s), listed.insert(s).inserted else { continue }
            next.append(Row(session: s, label: "\(dayTime(e.start, now: now, calendar: calendar)) · \(e.title)", mark: mark(s), event: e))
        }
        let rest = sessions.filter { !listed.contains($0) }.sorted { a, b in
            let da = createdAt[a] ?? .distantPast, db = createdAt[b] ?? .distantPast
            return da != db ? da > db : a < b
        }
        let others = rest.map { s in Row(session: s, label: sessionLabel(s, sidecar: sidecars[s], calendar: calendar), mark: mark(s)) }
        var notPrepared: NotPrepared?
        if let t = target, targetSession == nil {
            let when = dayTime(t.start, now: now, calendar: calendar)
            let busy = preparing.contains(t.occurrenceKey)
            notPrepared = NotPrepared(event: t, preparing: busy,
                                      label: busy ? L10n.tr("Next: \(t.title) \(when) — preparing…")
                                                  : L10n.tr("Next: \(t.title) \(when) — not prepared"))
        }
        return SessionPickerModel(nextMeetings: next, others: others, notPrepared: notPrepared)
    }

    /// "Today 14:00", "Tomorrow 09:30", "Wed 26 Nov 10:00" (relative to `now`, in `calendar`'s time zone).
    public static func dayTime(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = d.formatted(timeStyle(calendar))
        return "\(day(d, now: now, calendar: calendar)) \(time)"
    }

    static func day(_ d: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return L10n.tr("Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: tomorrow) {
            return L10n.tr("Tomorrow")
        }
        return d.formatted(dayStyle(calendar))
    }

    /// A session prepared from an event: "<title> · Mon 24 Nov"; any other: its folder name.
    static func sessionLabel(_ name: String, sidecar: EventSidecar?, calendar: Calendar) -> String {
        guard let sidecar, let title = sidecar.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return name }
        guard let start = sidecar.start else { return title }
        return "\(title) · \(start.formatted(dayStyle(calendar)))"
    }

    private static func timeStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var f = HomeFormat.time
        f.timeZone = calendar.timeZone
        return f
    }

    private static func dayStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var f = HomeFormat.dayMonth
        f.timeZone = calendar.timeZone
        return f
    }
}

/// The calendar row of the menu and of Home (G2, owner decision 4).
public enum CalendarNudge: Equatable, Sendable {
    /// Sessions exist and the calendar is off: the menu's "Connect calendar…" (asks for access once).
    case turnOn
    /// "Use my calendar" is on but macOS does not give full access: say so instead of showing an empty calendar.
    case permissionMissing

    /// `done`: the one-time row was used or put away. The Turn on row never shows during a run (it may raise the permission sheet).
    public static func state(hasSessions: Bool, useCalendar: Bool, authorization: CalendarAuthorization, running: Bool,
                             done: Bool) -> CalendarNudge? {
        if useCalendar { return authorization == .fullAccess ? nil : .permissionMissing }
        guard hasSessions, !done, !running else { return nil }
        return .turnOn
    }
}
