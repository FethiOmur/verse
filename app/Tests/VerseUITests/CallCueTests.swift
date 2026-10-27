import Foundation
@testable import VerseUI
import XCTest

/// The call's time cue (`call.json`): parsing, the phases around the end, the reducer and the island's width.
@MainActor
final class CallCueTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: h, minute: m, second: s))!
    }

    func testWalkthroughEndIsTodayAtThatWallClockTime() {
        let cue = CallCue.parse(["walkthrough_end": "14:07"], now: date(13, 58), calendar: cal)
        XCTAssertEqual(cue?.end, date(14, 7).timeIntervalSince1970)
        XCTAssertNil(CallCue.parse(["walkthrough_end": "25:00"], now: date(13, 58), calendar: cal))
        XCTAssertNil(CallCue.parse(["walkthrough_end": "soon"], now: date(13, 58), calendar: cal))
        XCTAssertNil(CallCue.parse(["card_lines": 2], now: date(13, 58), calendar: cal))
    }

    func testMinutesFromStart() {
        let cue = CallCue.parse(["minutes_from_start": 7], now: date(14, 0), calendar: cal)
        XCTAssertEqual(cue?.end, date(14, 7).timeIntervalSince1970)
        XCTAssertNil(CallCue.parse(["minutes_from_start": 0], now: date(14, 0), calendar: cal))
        XCTAssertNil(CallCue.parse(["minutes_from_start": 5000], now: date(14, 0), calendar: cal))
    }

    func testPhases() {
        let end = date(14, 7).timeIntervalSince1970
        let cue = CallCue(end: end)
        XCTAssertNil(cue.phase(now: end - 61))
        XCTAssertEqual(cue.phase(now: end - 60), .soon)
        XCTAssertEqual(cue.phase(now: end - 1), .soon)
        XCTAssertEqual(cue.phase(now: end), .now)
        XCTAssertEqual(cue.phase(now: end + 89), .now)
        XCTAssertNil(cue.phase(now: end + 90))
    }

    func testLoadReadsCallJsonAndIgnoresAMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("callcue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(CallCue.load(sessionDir: dir))
        try Data(#"{"card_lines": 2, "minutes_from_start": 3}"#.utf8).write(to: dir.appendingPathComponent("call.json"))
        let now = date(14, 0)
        XCTAssertEqual(CallCue.load(sessionDir: dir, now: now, calendar: cal)?.end, now.timeIntervalSince1970 + 180)
    }

    func testReducerFollowsTheClockAndResetsWithTheSession() {
        let end: TimeInterval = 10_000
        var r = OverlayReducer()
        r.sessionStarting(lang: "en")
        r.setCallCue(CallCue(end: end), now: end - 300)
        XCTAssertNil(r.state.timeCue)
        r.tick(now: end - 30)
        XCTAssertEqual(r.state.timeCue, .soon)
        r.tick(now: end + 5)
        XCTAssertEqual(r.state.timeCue, .now)
        r.tick(now: end + 120)
        XCTAssertNil(r.state.timeCue)
        r.setCallCue(CallCue(end: end), now: end - 10)
        XCTAssertEqual(r.state.timeCue, .soon)
        r.sessionStarting(lang: "en")
        r.tick(now: end - 10)
        XCTAssertNil(r.state.timeCue, "a new session starts without the old cue")
    }

    func testTheCapsuleWidensForTheCue() {
        let m = NotchMetrics.macBookPro
        var s = OverlayState()
        s.running = true
        XCTAssertEqual(IslandWidth.width(kind: .capsule, state: s, metrics: m, cardWidth: 600), m.capsuleWidth(wide: false))
        s.timeCue = .soon
        XCTAssertEqual(IslandWidth.width(kind: .capsule, state: s, metrics: m, cardWidth: 600), m.listeningWidth)
    }
}
