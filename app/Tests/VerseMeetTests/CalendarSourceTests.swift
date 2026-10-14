import Foundation
import XCTest
@testable import VerseMeet

final class FakeCalendarBackend: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var status: CalendarAuthorization
    private let grantOnRequest: Bool
    private let accounts: Int
    private let all: [CalendarEntry]
    private(set) var requested = 0

    init(status: CalendarAuthorization, grantOnRequest: Bool = false, accounts: Int = 1, entries: [CalendarEntry] = []) {
        self.status = status
        self.grantOnRequest = grantOnRequest
        self.accounts = accounts
        self.all = entries
    }

    func authorization() -> CalendarAuthorization { lock.withLock { status } }
    func requestFullAccess() async throws -> Bool {
        lock.withLock {
            requested += 1
            if grantOnRequest { status = .fullAccess } else if status == .notDetermined { status = .denied }
            return grantOnRequest
        }
    }
    func accountCount() -> Int { accounts }
    func entries(from: Date, to: Date) -> [CalendarEntry] { all.filter { $0.end > from && $0.start < to } }
}

final class CalendarSourceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ id: String, startMin: Double, lenMin: Double = 30, allDay: Bool = false, url: String? = nil, notes: String? = nil) -> CalendarEntry {
        CalendarEntry(id: id, title: "Event \(id)", start: now.addingTimeInterval(startMin * 60),
                      end: now.addingTimeInterval((startMin + lenMin) * 60), isAllDay: allDay,
                      notes: notes, url: url.flatMap(URL.init(string:)))
    }

    func testCalendarDenied() async {
        for (status, expected) in [(CalendarAuthorization.denied, CalendarError.accessDenied),
                                   (.restricted, .restricted), (.writeOnly, .writeOnly)] {
            let src = CalendarSource(backend: FakeCalendarBackend(status: status, entries: [entry("a", startMin: 5)]))
            do {
                _ = try await src.upcoming(now: now)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? CalendarError, expected)
            }
        }
        // Undecided + the user says no -> typed error, and the prompt was asked for exactly once.
        let fake = FakeCalendarBackend(status: .notDetermined, grantOnRequest: false)
        do {
            _ = try await CalendarSource(backend: fake).upcoming(now: now)
            XCTFail("expected accessDenied")
        } catch {
            XCTAssertEqual(error as? CalendarError, .accessDenied)
        }
        XCTAssertEqual(fake.requested, 1)
        // Granted but no accounts at all.
        do {
            _ = try await CalendarSource(backend: FakeCalendarBackend(status: .fullAccess, accounts: 0)).upcoming(now: now)
            XCTFail("expected noAccounts")
        } catch {
            XCTAssertEqual(error as? CalendarError, .noAccounts)
        }
        // `overlapping` never prompts and never throws.
        let denied = CalendarSource(backend: FakeCalendarBackend(status: .denied, entries: [entry("a", startMin: 0)]))
        XCTAssertTrue(denied.overlapping(now: now).isEmpty)
    }

    func testUpcomingWindowSkipsAllDayAndPast() async throws {
        let backend = FakeCalendarBackend(status: .notDetermined, grantOnRequest: true, entries: [
            entry("past", startMin: -90),                                   // ended 60 min ago
            entry("running", startMin: -10, url: "https://meet.google.com/abc-defg-hij"),
            entry("soon", startMin: 20, notes: "https://us02web.zoom.us/j/42"),
            entry("later", startMin: 45),                                   // outside 30 min
            entry("allday", startMin: -600, lenMin: 1200, allDay: true),
        ])
        let events = try await CalendarSource(backend: backend).upcoming(within: 30 * 60, now: now)
        XCTAssertEqual(events.map(\.id), ["running", "soon"])
        XCTAssertEqual(events.map(\.provider), [.meet, .zoom])
        XCTAssertEqual(backend.requested, 1)
    }
}
