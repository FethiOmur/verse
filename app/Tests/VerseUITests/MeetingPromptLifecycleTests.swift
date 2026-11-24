import Foundation
import VerseMeet
@testable import VerseUI
import XCTest

/// The start prompt's life after a click or a pause: the question withdrawn when the call ends (V4), and a dismissed
/// call not asked about again after its microphone pauses (S11).
@MainActor
final class MeetingPromptLifecycleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    let cometMic = AudioProcessInfo(bundleID: "ai.perplexity.comet.helper", pid: 7, isRunningInput: true, isRunningOutput: true)
    let cometOnlyAudio = AudioProcessInfo(bundleID: "ai.perplexity.comet.helper", pid: 7, isRunningInput: false, isRunningOutput: true)

    /// The coordinator's clock, moved by the test along with the detector's ticks.
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    private func make(_ host: FakeHost, clock: Clock) throws -> MeetingCoordinator {
        MeetingCoordinator(host: host, settings: meetingSettings(), calendar: CalendarSource(backend: NoCalendar()),
                           detector: MeetingDetector(table: MicTable()), upcoming: { _ in [] },
                           eventMap: EventSessionMap(url: try tempDir().appendingPathComponent("map.json")), now: { clock.now })
    }

    private func run(_ c: MeetingCoordinator, _ d: MeetingDetector, clock: Clock, _ seconds: ClosedRange<Int>) async {
        for s in seconds {
            clock.now = at(Double(s))
            for sig in await d.tick(at: at(Double(s))) { c.handle(sig) }
        }
    }

    // MARK: V4

    func testTheCallEndingBeforeStartWithdrawsTheQuestionOfAMeetingWithoutASession() async throws {
        let host = FakeHost(sessions: ["sample-interview"])
        let clock = Clock(t0)
        let c = try make(host, clock: clock)
        let table = MicTable()
        let ev = MeetingEvent(id: "ev9", title: "Quarterly review", start: at(-60), end: at(1800), attendees: [], notes: nil,
                              url: URL(string: "https://meet.google.com/abc-defg-hij"), provider: .meet)
        let d = MeetingDetector(table: table, eventLookup: { _ in [ev] })
        table.set([cometMic])
        await run(c, d, clock: clock, 0...5)
        XCTAssertNotNil(host.overlay.state.meetingPrompt)
        XCTAssertFalse(host.overlay.state.meetingPrompt?.busy ?? true, "nothing is prepared behind the question")

        table.set([cometOnlyAudio])
        await run(c, d, clock: clock, 6...30)
        XCTAssertNil(host.overlay.state.meetingPrompt, "the call ended: the question is taken back")
        XCTAssertEqual(host.startCount + host.unpreparedStarts, 0)
    }

    // MARK: S11

    func testADismissedCallIsNotAskedAgainAfterItsMicrophonePauses() async throws {
        let host = FakeHost()
        let clock = Clock(t0)
        let c = try make(host, clock: clock)
        let table = MicTable()
        let d = MeetingDetector(table: table)
        table.set([cometMic])
        await run(c, d, clock: clock, 0...5)
        XCTAssertNotNil(host.overlay.state.meetingPrompt)
        host.overlay.promptAction(.dismiss)
        XCTAssertNil(host.overlay.state.meetingPrompt)

        // Muted for 40 s: the detector ends the call after 10 s and starts it again, with a new start time, on unmute.
        table.set([cometOnlyAudio])
        await run(c, d, clock: clock, 6...46)
        table.set([cometMic])
        await run(c, d, clock: clock, 47...55)
        let active = await d.activeMeetings
        XCTAssertEqual(active.count, 1, "the detector did see the input come back")
        XCTAssertNil(host.overlay.state.meetingPrompt, "the same call: no second question")
    }

    func testANewCallLongAfterADismissedOneIsAskedAbout() async throws {
        let host = FakeHost()
        let clock = Clock(t0)
        let c = try make(host, clock: clock)
        let table = MicTable()
        let d = MeetingDetector(table: table)
        table.set([cometMic])
        await run(c, d, clock: clock, 0...5)
        host.overlay.promptAction(.dismiss)
        table.set([])
        await run(c, d, clock: clock, 6...20)
        // Well past the resume window: another call.
        let later = 20 + Int(MeetingCoordinator.resumeWindow) + 60
        table.set([cometMic])
        await run(c, d, clock: clock, later...(later + 5))
        XCTAssertEqual(host.overlay.state.meetingPrompt?.kind, .detected)
    }
}
