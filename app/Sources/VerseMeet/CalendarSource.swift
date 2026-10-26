import Foundation

public enum CalendarAuthorization: Sendable, Equatable {
    case notDetermined, fullAccess, writeOnly, denied, restricted
}

/// Typed errors the app can show; the calendar never crashes the process.
public enum CalendarError: Error, Sendable, Equatable, CustomStringConvertible {
    case accessDenied
    case restricted
    case writeOnly
    case noAccounts
    case failed(String)

    public var description: String {
        switch self {
        case .accessDenied: return "Calendar access was denied. Allow it in System Settings > Privacy & Security > Calendars."
        case .restricted: return "Calendar access is restricted on this Mac."
        case .writeOnly: return "Verse has write-only calendar access; it needs full access to read events."
        case .noAccounts: return "No calendar accounts are set up on this Mac."
        case .failed(let m): return "Calendar error: \(m)"
        }
    }
}

/// A raw calendar entry before Verse reads the meeting link out of it.
public struct CalendarEntry: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [Attendee]
    public var notes: String?
    public var location: String?
    public var url: URL?
    /// The attendee that is the calendar's owner (EventKit's `isCurrentUser`); nil when the owner is not on the list.
    public var currentUser: Attendee?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, attendees: [Attendee] = [],
                notes: String? = nil, location: String? = nil, url: URL? = nil, currentUser: Attendee? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.notes = notes
        self.location = location
        self.url = url
        self.currentUser = currentUser
    }
}

/// The part of the calendar store the source needs. EventKit implements it; tests use a fake.
public protocol CalendarBackend: Sendable {
    func authorization() -> CalendarAuthorization
    func requestFullAccess() async throws -> Bool
    func accountCount() -> Int
    func entries(from: Date, to: Date) -> [CalendarEntry]
}

public struct CalendarSource: Sendable {
    private let backend: any CalendarBackend

    public init(backend: any CalendarBackend = EventKitBackend()) {
        self.backend = backend
    }

    public func authorization() -> CalendarAuthorization { backend.authorization() }

    /// Asks for full access when it was never decided or only write access exists (macOS offers an upgrade prompt);
    /// throws the typed error for every state that cannot read events.
    @discardableResult
    public func ensureAccess() async throws -> CalendarAuthorization {
        var status = backend.authorization()
        if status == .notDetermined || status == .writeOnly {
            do {
                _ = try await backend.requestFullAccess()
            } catch {
                throw CalendarError.failed("\(error)")
            }
            status = backend.authorization()
        }
        switch status {
        case .fullAccess:
            if backend.accountCount() == 0 { throw CalendarError.noAccounts }
            return status
        case .denied, .notDetermined: throw CalendarError.accessDenied
        case .restricted: throw CalendarError.restricted
        case .writeOnly: throw CalendarError.writeOnly
        }
    }

    /// Events that end after `now` and start within `within` of it (so a call that is running now counts), soonest first.
    /// All-day events are skipped. With `realMeetingsOnly`, only events with someone besides the owner or a video-call link
    /// are kept (see `RealMeeting`); the pickers set it, the call detector does not.
    public func upcoming(within: TimeInterval = 30 * 60, now: Date = Date(), realMeetingsOnly: Bool = false) async throws -> [MeetingEvent] {
        try await ensureAccess()
        return events(from: now, to: now.addingTimeInterval(within), realMeetingsOnly: realMeetingsOnly).filter { $0.end > now }
    }

    /// Events overlapping `[now - margin, now + margin]`, for attaching to a detected call. Never prompts: without
    /// full access it returns an empty list.
    public func overlapping(now: Date = Date(), margin: TimeInterval = 10 * 60) -> [MeetingEvent] {
        guard backend.authorization() == .fullAccess else { return [] }
        return events(from: now.addingTimeInterval(-margin), to: now.addingTimeInterval(margin))
    }

    /// One event by identifier, searched from a day ago to two weeks ahead (a recurring event: the next occurrence).
    public func event(id: String, now: Date = Date()) async throws -> MeetingEvent? {
        try await ensureAccess()
        let all = events(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
        return all.first { $0.id == id && $0.end >= now } ?? all.first { $0.id == id }
    }

    private func events(from: Date, to: Date, realMeetingsOnly: Bool = false) -> [MeetingEvent] {
        backend.entries(from: from, to: to)
            .filter { !$0.isAllDay && (!realMeetingsOnly || RealMeeting.isReal($0)) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .map { e in
                let link = MeetingLink.extract(url: e.url, location: e.location, notes: e.notes)
                return MeetingEvent(id: e.id, title: e.title, start: e.start, end: e.end, attendees: e.attendees,
                                    notes: e.notes, url: link.url, provider: link.provider, currentUser: e.currentUser)
            }
    }
}
