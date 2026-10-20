import EventKit
import Foundation

/// EventKit implementation of `CalendarBackend`. Needs `NSCalendarsFullAccessUsageDescription` in the host's
/// Info.plist (the `verse-meet` tool embeds one) and the user's Calendar permission.
public final class EventKitBackend: CalendarBackend, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func authorization() -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func accountCount() -> Int { store.sources.count }

    public func entries(from: Date, to: Date) -> [CalendarEntry] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).compactMap { e in
            if e.status == .canceled { return nil }
            let me = e.attendees?.first { $0.isCurrentUser }
            if me?.participantStatus == .declined { return nil }
            return CalendarEntry(
                id: e.eventIdentifier ?? "\(e.startDate.timeIntervalSince1970)-\(e.title ?? "")",
                title: (e.title ?? "").isEmpty ? "(no title)" : e.title!,
                start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                attendees: (e.attendees ?? []).map(Self.attendee),
                notes: e.notes, location: e.location, url: e.url, currentUser: me.map(Self.attendee))
        }
    }

    private static func attendee(_ p: EKParticipant) -> Attendee {
        var email: String?
        if p.url.scheme?.lowercased() == "mailto" {
            email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
        }
        var name = p.name?.trimmingCharacters(in: .whitespaces)
        if let n = name, n.isEmpty || n == email { name = nil }
        return Attendee(name: name, email: email)
    }
}
