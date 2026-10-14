import Foundation
import XCTest
@testable import VerseMeet

final class FakeProcessTable: AudioProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [AudioProcessInfo] = []
    func set(_ p: [AudioProcessInfo]) { lock.withLock { procs = p } }
    func snapshot() -> [AudioProcessInfo] { lock.withLock { procs } }
}

final class MeetingDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    let braveOutput = AudioProcessInfo(bundleID: "com.brave.Browser.helper", pid: 10, isRunningInput: false, isRunningOutput: true)
    let braveMic = AudioProcessInfo(bundleID: "com.brave.Browser.helper", pid: 10, isRunningInput: true, isRunningOutput: true)

    /// Runs `tick` once per second over `range` and collects (second, signal).
    func run(_ d: MeetingDetector, _ range: ClosedRange<Int>) async -> [(Int, MeetingSignal)] {
        var out: [(Int, MeetingSignal)] = []
        for s in range { for sig in await d.tick(at: at(Double(s))) { out.append((s, sig)) } }
        return out
    }

    func testDetectorNeedsMicInput() async {
        let table = FakeProcessTable()
        let d = MeetingDetector(table: table)

        // A browser only playing audio never counts, however long.
        table.set([braveOutput])
        var sigs = await run(d, 0...60)
        XCTAssertTrue(sigs.isEmpty)

        // Mic input from t=100: nothing before 3 s, started at 103 with `since` = 100.
        table.set([braveMic])
        sigs = await run(d, 100...102)
        XCTAssertTrue(sigs.isEmpty, "needs 3 s of input")
        sigs = await run(d, 103...120)
        XCTAssertEqual(sigs.count, 1)
        XCTAssertEqual(sigs.first?.0, 103)
        guard case .started(let info)? = sigs.first?.1 else { return XCTFail("expected started") }
        XCTAssertEqual(info.appName, "Brave")
        XCTAssertEqual(info.bundleID, "com.brave.Browser")
        XCTAssertEqual(info.since, at(100))
        let active = await d.activeMeetings
        XCTAssertEqual(active.count, 1)

        // Input stops after t=120: still active at 129, ended at 130 (10 s of silence), exactly once.
        table.set([braveOutput])
        sigs = await run(d, 121...129)
        XCTAssertTrue(sigs.isEmpty)
        sigs = await run(d, 130...150)
        XCTAssertEqual(sigs.count, 1)
        XCTAssertEqual(sigs.first?.0, 130)
        guard case .ended(let ended)? = sigs.first?.1 else { return XCTFail("expected ended") }
        XCTAssertEqual(ended.appName, "Brave")
        let none = await d.activeMeetings
        XCTAssertTrue(none.isEmpty)
    }

    func testShortInputBlipAndShortGapDoNotSignal() async {
        let table = FakeProcessTable()
        let d = MeetingDetector(table: table)
        // 2 s of mic input then silence: never a call.
        table.set([braveMic])
        _ = await run(d, 0...1)
        table.set([])
        var sigs = await run(d, 2...30)
        XCTAssertTrue(sigs.isEmpty)
        // A real call with a 5 s gap in the middle stays one call.
        table.set([braveMic]); sigs = await run(d, 40...50)
        table.set([braveOutput]); sigs += await run(d, 51...55)
        table.set([braveMic]); sigs += await run(d, 56...70)
        XCTAssertEqual(sigs.count, 1)
        if case .started? = sigs.first?.1 {} else { XCTFail("expected a single started") }
    }

    func testOtherAppsAndSubBundles() async {
        let table = FakeProcessTable()
        let d = MeetingDetector(table: table)
        // Not a meeting app, and a lookalike bundle ID, never count.
        table.set([AudioProcessInfo(bundleID: "com.apple.VoiceMemos", isRunningInput: true),
                   AudioProcessInfo(bundleID: "com.brave.BrowserEvil", isRunningInput: true)])
        var sigs = await run(d, 0...10)
        XCTAssertTrue(sigs.isEmpty)
        // Zoom is detected and named.
        table.set([AudioProcessInfo(bundleID: "us.zoom.xos", isRunningInput: true)])
        sigs = await run(d, 20...24)
        XCTAssertEqual(sigs.count, 1)
        if case .started(let i)? = sigs.first?.1 { XCTAssertEqual(i.appName, "Zoom") } else { XCTFail("expected started") }
    }

    func testDetectorAttachesEvent() async {
        let table = FakeProcessTable()
        table.set([braveMic])
        let near = MeetingEvent(id: "near", title: "Standup", start: at(-5 * 60), end: at(25 * 60), provider: .meet)
        let far = MeetingEvent(id: "far", title: "Dinner", start: at(3 * 3600), end: at(4 * 3600))
        let finishedAWhileAgo = MeetingEvent(id: "old", title: "Old", start: at(-3600), end: at(-20 * 60))
        let d = MeetingDetector(table: table, eventLookup: { _ in [far, finishedAWhileAgo, near] })
        let sigs = await run(d, 0...5)
        XCTAssertEqual(sigs.count, 1)
        guard case .started(let info)? = sigs.first?.1 else { return XCTFail("expected started") }
        XCTAssertEqual(info.event?.id, "near", "the overlapping event is attached, the distant ones are not")

        // Only distant events: signal without an event.
        let table2 = FakeProcessTable(); table2.set([braveMic])
        let d2 = MeetingDetector(table: table2, eventLookup: { _ in [far, finishedAWhileAgo] })
        let sigs2 = await run(d2, 0...5)
        guard case .started(let info2)? = sigs2.first?.1 else { return XCTFail("expected started") }
        XCTAssertNil(info2.event)

        // An event that starts in 8 minutes counts (within ±10 min), one that starts in 12 minutes does not.
        let soon = MeetingEvent(id: "soon", title: "Soon", start: at(8 * 60), end: at(38 * 60))
        let notYet = MeetingEvent(id: "notyet", title: "Not yet", start: at(12 * 60), end: at(40 * 60))
        let table3 = FakeProcessTable(); table3.set([braveMic])
        let d3 = MeetingDetector(table: table3, eventLookup: { _ in [notYet, soon] })
        let sigs3 = await run(d3, 0...5)
        guard case .started(let info3)? = sigs3.first?.1 else { return XCTFail("expected started") }
        XCTAssertEqual(info3.event?.id, "soon")
    }
}
