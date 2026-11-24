import EventKit
import Foundation

/// EventKit implementation of `CalendarBackend`. Needs `NSCalendarsFullAccessUsageDescription` in the host's
/// Info.plist (the `verse-meet` tool embeds one) and the user's Calendar permission.
///
/// The store is rebuilt whenever the authorization status changes (S9): a store made before access was granted (in
/// Settings, or through another store's prompt) keeps returning no events. Apple: "If you request events before
/// prompting people for access with this method, you'll need to reset the event store" (`requestFullAccessToEvents`).
public final class EventKitBackend: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let status: @Sendable () -> EKAuthorizationStatus
    private let makeStore: @Sendable () -> EKEventStore
    private var cached: EKEventStore?
    private var cachedFor: EKAuthorizationStatus?

    public convenience init() {
        self.init(status: { EKEventStore.authorizationStatus(for: .event) }, makeStore: { EKEventStore() })
    }

    /// Tests inject the status and count the stores made.
    init(status: @escaping @Sendable () -> EKAuthorizationStatus, makeStore: @escaping @Sendable () -> EKEventStore) {
        self.status = status
        self.makeStore = makeStore
    }

    /// The store for the current authorization; a new one after the status changed.
    func currentStore() -> EKEventStore {
        let now = status()
        return lock.withLock {
            if let s = cached, cachedFor == now { return s }
            let s = makeStore()
            cached = s
            cachedFor = now
            return s
        }
    }

    public func authorization() -> CalendarAuthorization {
        switch status() {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestFullAccess() async throws -> Bool {
        try await currentStore().requestFullAccessToEvents()
    }

    public func accountCount() -> Int { currentStore().sources.count }

    public func entries(from: Date, to: Date) -> [CalendarEntry] {
        let store = currentStore()
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
                notes: e.notes, location: e.location, url: e.url, currentUser: me.map(Self.attendee),
                isRecurring: e.hasRecurrenceRules)
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

public extension CalendarSource {
    /// Posted (by EventKit) when anything in the calendar store changed: a new, moved or deleted event, a calendar added.
    static var storeChangedNotification: Notification.Name { .EKEventStoreChanged }
}
