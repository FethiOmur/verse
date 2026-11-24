import EventKit
import Foundation
import XCTest
@testable import VerseMeet

/// The owner's part in an event (`Participation`): read from EventKit, carried to `MeetingEvent`, and only organiser or accepted
/// counts as confirmed. Anyone can put an invite in his calendar; it is there before he answers it. Invented names only.
final class ParticipationTests: XCTestCase {
    func testParticipationFromWhatEventKitReports() {
        typealias Row = (organizerIsMe: Bool, hasOrganizer: Bool, hasAttendees: Bool, status: EKParticipantStatus?, own: Bool,
                         want: Participation, why: String)
        let table: [Row] = [
            (true, true, true, .accepted, true, .organizer, "he organises it"),
            (true, true, true, nil, false, .organizer, "he organises it, whatever the calendar"),
            (false, true, true, .accepted, true, .accepted, "he accepted the invite"),
            (false, true, true, .tentative, true, .tentative, "maybe"),
            (false, true, true, .pending, true, .pending, "an invite he has not answered"),
            (false, true, true, .unknown, true, .unknown, "an unknown status"),
            (false, true, true, .delegated, true, .unknown, "delegated"),
            (false, true, true, nil, true, .unknown, "he is not on the invite"),
            (false, false, false, nil, true, .unknown, "no organiser and no invitees: not provably his, even on his own calendar"),
            (false, false, false, nil, false, .unknown, "a subscribed or read-only calendar"),
            (false, false, true, .pending, true, .pending, "invitees without an organiser: his answer decides"),
        ]
        for r in table {
            XCTAssertEqual(EventKitBackend.participation(organizerIsMe: r.organizerIsMe, hasOrganizer: r.hasOrganizer,
                                                         hasAttendees: r.hasAttendees, myStatus: r.status, ownCalendar: r.own),
                           r.want, r.why)
        }
    }

    func testOnlyOrganiserAndAcceptedAreConfirmed() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ p: Participation?) -> MeetingEvent {
            MeetingEvent(id: "ev", title: "Intro", start: start, end: start.addingTimeInterval(1_800), participation: p)
        }
        XCTAssertEqual(Participation.allCases.filter(\.isConfirmed), [.organizer, .accepted])
        for p in Participation.allCases { XCTAssertEqual(event(p).ownerConfirmed, p == .organizer || p == .accepted, p.rawValue) }
        XCTAssertFalse(event(nil).ownerConfirmed, "not known (older JSON): not confirmed")
    }

    func testCalendarSourceCarriesTheParticipationAndOldJSONDecodesAsNil() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let guest = Attendee(name: "Rowan Pell", email: "rowan@example.com")
        let entries = [Participation.pending, .accepted].enumerated().map { i, p in
            CalendarEntry(id: "ev\(i)", title: "Intro", start: now.addingTimeInterval(60), end: now.addingTimeInterval(1_800),
                          attendees: [guest], participation: p)
        }
        let events = CalendarSource(backend: FakeCalendarBackend(status: .fullAccess, entries: entries)).overlapping(now: now)
        XCTAssertEqual(events.map(\.participation), [.pending, .accepted])
        let old = #"{"id":"ev1","title":"Old","start":0,"end":60,"attendees":[],"provider":"meet"}"#
        XCTAssertNil(try JSONDecoder().decode(MeetingEvent.self, from: Data(old.utf8)).participation)
    }
}
