import Foundation
import XCTest
@testable import VerseMeet

final class MeetingLinkTests: XCTestCase {
    func testMeetingURLExtraction() {
        // Google Meet from the event URL
        var r = MeetingLink.extract(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil)
        XCTAssertEqual(r.provider, .meet)
        XCTAssertEqual(r.url?.absoluteString, "https://meet.google.com/abc-defg-hij")

        // Zoom from the location
        r = MeetingLink.extract(url: nil, location: "https://acme.zoom.us/j/123456789?pwd=AbC123", notes: nil)
        XCTAssertEqual(r.provider, .zoom)
        XCTAssertEqual(r.url?.absoluteString, "https://acme.zoom.us/j/123456789?pwd=AbC123")

        // Teams from the notes, inside prose and an HTML anchor, with trailing punctuation
        r = MeetingLink.extract(url: nil, location: "Room 4",
                                notes: "Agenda below.\nJoin: <a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0\">link</a>.")
        XCTAssertEqual(r.provider, .teams)
        XCTAssertEqual(r.url?.absoluteString, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0")

        let sentence = MeetingLink.extract(url: nil, location: nil, notes: "Call me on https://meet.google.com/xyz-abcd-efg.")
        XCTAssertEqual(sentence.url?.absoluteString, "https://meet.google.com/xyz-abcd-efg")

        // Meeting link in the notes wins over a plain event URL that is not a meeting
        r = MeetingLink.extract(url: URL(string: "https://example.com/agenda"), location: nil, notes: "https://us02web.zoom.us/j/999")
        XCTAssertEqual(r.provider, .zoom)

        // None: provider other; the event's own URL is kept, nothing invented
        r = MeetingLink.extract(url: nil, location: "Cafe", notes: "Bring the slides. See https://example.com/doc")
        XCTAssertEqual(r.provider, .other)
        XCTAssertNil(r.url)
        r = MeetingLink.extract(url: URL(string: "https://example.com/agenda"), location: nil, notes: nil)
        XCTAssertEqual(r.provider, .other)
        XCTAssertEqual(r.url?.absoluteString, "https://example.com/agenda")
    }

    func testEventJSONCarriesIsoDatesAndProvider() throws {
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let e = MeetingEvent(id: "e1", title: "Sync", start: start, end: start.addingTimeInterval(1800),
                             attendees: [Attendee(name: "A B", email: "ab@example.invalid")], notes: "n",
                             url: URL(string: "https://meet.google.com/abc-defg-hij"), provider: .meet)
        let obj = try JSONSerialization.jsonObject(with: e.jsonData()) as? [String: Any]
        XCTAssertEqual(obj?["provider"] as? String, "meet")
        XCTAssertEqual(obj?["title"] as? String, "Sync")
        let s = try XCTUnwrap(obj?["start"] as? String)
        let f = ISO8601DateFormatter()
        XCTAssertEqual(f.date(from: s), start)  // "+02:00"-style offset, parseable by Python's fromisoformat
        XCTAssertEqual(obj?["url"] as? String, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual((obj?["attendees"] as? [[String: Any]])?.count, 1)
    }
}
