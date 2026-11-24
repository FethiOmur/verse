import Foundation
import VerseMeet

/// The menu's Start row (owner decision 3): a pure preview of what ⌥⌘V does, made from the same `QuickStart.SessionChoice` that
/// `VerseController.startNow` acts on.
public struct StartRowPreview: Equatable, Sendable {
    public var choice: QuickStart.SessionChoice
    /// "Start · <session>" or "Start · unprepared".
    public var title: String

    public init(choice: QuickStart.SessionChoice, sessionLabel: (String) -> String) {
        self.choice = choice
        switch choice {
        case .prepared(let name): title = L10n.tr("Start · \(sessionLabel(name))")
        case .adhoc: title = L10n.tr("Start · unprepared")
        }
    }

    /// The session the main row names, nil when it starts an unprepared call.
    public var session: String? {
        if case .prepared(let s) = choice { return s }
        return nil
    }

    /// "Start unprepared" shows under it only while the main row names a session (owner decision 5); when the main row already
    /// starts an unprepared call the second row would do the same thing.
    public var showsUnpreparedRow: Bool { session != nil }
}

/// The two info rows of the idle menu when a meeting is ahead: the meeting and the state of its session.
public struct NextMeetingRows: Equatable, Sendable {
    public enum SessionState: Equatable, Sendable {
        case ready, preparing, notPrepared
    }

    /// "Next meeting: Today 14:00 · <title>".
    public var meeting: String
    public var state: SessionState

    /// "Session: ready" / "Session: preparing…" / "Session: not prepared".
    public var stateText: String {
        switch state {
        case .ready: return L10n.tr("Session: ready")
        case .preparing: return L10n.tr("Session: preparing…")
        case .notPrepared: return L10n.tr("Session: not prepared")
        }
    }

    /// "Prepare for this meeting" shows only while its session is neither ready nor being prepared.
    public var offersPrepare: Bool { state == .notPrepared }

    /// The rows for the selection's target meeting, nil when no meeting is ahead. The meeting counts as ready when the picker has
    /// no "not prepared" line for it (it has a matched session, or he chose one for it by hand).
    public static func make(target: MeetingEvent?, picker: SessionPickerModel, now: Date, calendar: Calendar = .current) -> NextMeetingRows? {
        guard let target else { return nil }
        let when = SessionPickerModel.dayTime(target.start, now: now, calendar: calendar)
        let state: SessionState
        if let np = picker.notPrepared, np.event.occurrenceKey == target.occurrenceKey {
            state = np.preparing ? .preparing : .notPrepared
        } else {
            state = .ready
        }
        return NextMeetingRows(meeting: L10n.tr("Next meeting: \(when) · \(target.title)"), state: state)
    }
}

public extension SessionPickerModel {
    /// How many sessions the menu's Session submenu lists; "All sessions…" opens the rest in Home.
    static let menuLimit = 8

    /// The menu's Session submenu: the rows in the picker's order (next meetings, then the other sessions newest first), at most
    /// `limit`. The selected session is always listed: when it falls past the cap it takes the last place, so the submenu never
    /// hides what Start would use.
    func capped(_ limit: Int = menuLimit, selected: String) -> SessionPickerModel {
        let all = rows
        guard all.count > limit, limit > 0 else { return self }
        var keep = Array(all.prefix(limit))
        if !keep.contains(where: { $0.session == selected }), let sel = all.first(where: { $0.session == selected }) {
            keep[limit - 1] = sel
        }
        let kept = Set(keep.map(\.session))
        return SessionPickerModel(nextMeetings: nextMeetings.filter { kept.contains($0.session) },
                                  others: others.filter { kept.contains($0.session) }, notPrepared: notPrepared)
    }
}
