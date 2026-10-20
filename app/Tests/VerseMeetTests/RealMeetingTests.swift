import Foundation
import XCTest
@testable import VerseMeet

/// The "real meeting" rule behind Prepare's Up next and Practice's Upcoming. Fake entries only; no calendar is read.
final class RealMeetingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let me = Attendee(name: "Test Owner", email: "owner@example.invalid")
    let other = Attendee(name: "Ingrid S", email: "ingrid@example.invalid")

    func entry(_ id: String = "e", attendees: [Attendee] = [], url: String? = nil, location: String? = nil, notes: String? = nil,
               allDay: Bool = false, currentUser: Attendee? = nil) -> CalendarEntry {
        CalendarEntry(id: id, title: "Event \(id)", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2_400), isAllDay: allDay,
                      attendees: attendees, notes: notes, location: location, url: url.flatMap(URL.init(string:)), currentUser: currentUser)
    }

    func testAttendeeBesidesTheOwnerIsEnough() {
        XCTAssertTrue(RealMeeting.isReal(entry(attendees: [me, other], currentUser: me)))
        XCTAssertTrue(RealMeeting.isReal(entry(attendees: [other])))
    }

    func testTheOwnerAloneIsNotAMeeting() {
        XCTAssertFalse(RealMeeting.isReal(entry(attendees: [me], currentUser: me)))
        let shouting = Attendee(name: nil, email: "OWNER@example.invalid")
        XCTAssertFalse(RealMeeting.isReal(entry(attendees: [shouting], currentUser: me)), "emails compare case-insensitively")
    }

    func testNeitherAttendeesNorLinkIsExcluded() {
        XCTAssertFalse(RealMeeting.isReal(entry()))
        XCTAssertFalse(RealMeeting.isReal(entry(url: "https://example.invalid/page", location: "Office 3", notes: "Focus time")))
        XCTAssertFalse(RealMeeting.isReal(entry(url: "https://calendar.google.com/event?eid=abc")))
    }

    func testEachProviderLinkCountsInUrlLocationAndNotes() {
        let links = [
            "https://meet.google.com/abc-defg-hij",
            "https://acme.zoom.us/j/123456789?pwd=abc",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0",
            "https://acme.webex.com/meet/someone",
            "https://acme.webex.com/acme/j.php?MTID=abc",
            "https://facetime.apple.com/join#v=1&p=abc",
        ]
        for link in links {
            XCTAssertTrue(RealMeeting.isReal(entry(url: link)), "url \(link)")
            XCTAssertTrue(RealMeeting.isReal(entry(location: link)), "location \(link)")
            XCTAssertTrue(RealMeeting.isReal(entry(notes: "Join here: \(link) see you")), "notes \(link)")
        }
    }

    func testAllDayIsNeverRealEvenWithAttendeesAndLink() {
        XCTAssertFalse(RealMeeting.isReal(entry(attendees: [other], url: "https://meet.google.com/abc-defg-hij", allDay: true)))
    }

    func testCalendarSourceFiltersOnlyWhenAsked() async throws {
        let entries = [
            entry("link", url: "https://meet.google.com/abc-defg-hij"),
            entry("people", attendees: [me, other], currentUser: me),
            entry("solo"),
            entry("self", attendees: [me], currentUser: me),
            entry("allday", attendees: [other], allDay: true),
        ]
        let src = CalendarSource(backend: FakeCalendarBackend(status: .fullAccess, entries: entries))
        let all = try await src.upcoming(within: 3_600, now: now)
        XCTAssertEqual(all.map(\.id).sorted(), ["link", "people", "self", "solo"], "the default is unchanged")
        let real = try await src.upcoming(within: 3_600, now: now, realMeetingsOnly: true)
        XCTAssertEqual(real.map(\.id).sorted(), ["link", "people"])
    }
}
