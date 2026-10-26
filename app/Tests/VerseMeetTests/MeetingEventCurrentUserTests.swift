import Foundation
import XCTest
@testable import VerseMeet

/// `MeetingEvent.currentUser` (memory spec 2.5): the calendar's owner, filled from `CalendarEntry.currentUser`. Old JSON has none.
final class MeetingEventCurrentUserTests: XCTestCase {
    private let owner = Attendee(name: "Dana Reyes", email: "owner@example.com")

    private func event(currentUser: Attendee? = nil) -> MeetingEvent {
        MeetingEvent(id: "ev1", title: "Halden weekly", start: Date(timeIntervalSince1970: 1_800_000_000),
                     end: Date(timeIntervalSince1970: 1_800_001_800),
                     attendees: [Attendee(name: "Marta Velin", email: "marta@halden.example"), owner], currentUser: currentUser)
    }

    func testJSONWithoutCurrentUserDecodesAsNil() throws {
        let old = #"{"id":"ev1","title":"Old","start":0,"end":60,"attendees":[{"name":"Marta Velin","email":"marta@halden.example"}],"provider":"meet"}"#
        let e = try JSONDecoder().decode(MeetingEvent.self, from: Data(old.utf8))
        XCTAssertNil(e.currentUser)
        XCTAssertEqual(e.attendees.count, 1)
    }

    func testCurrentUserRoundTrips() throws {
        let e = event(currentUser: owner)
        let back = try JSONDecoder().decode(MeetingEvent.self, from: try JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.currentUser, owner)
    }

    func testBrainJSONKeepsWorkingAndCarriesTheOptionalKey() throws {
        let data = try event(currentUser: owner).jsonData()
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The keys `prep/event.py` reads are all still there.
        for key in ["id", "title", "start", "end", "attendees", "provider"] { XCTAssertNotNil(o[key], key) }
        XCTAssertNotNil(o["currentUser"])
        // Without a current user the key is absent, so the brain's input is what it was.
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: try event().jsonData()) as? [String: Any])
        XCTAssertNil(plain["currentUser"])
    }

    func testCalendarSourceFillsCurrentUserFromTheEntry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = CalendarEntry(id: "ev1", title: "Halden weekly", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(1_800),
                                  attendees: [owner], currentUser: owner)
        let source = CalendarSource(backend: FakeCalendarBackend(status: .fullAccess, entries: [entry]))
        let events = source.overlapping(now: now)
        XCTAssertEqual(events.first?.currentUser, owner)
    }
}
