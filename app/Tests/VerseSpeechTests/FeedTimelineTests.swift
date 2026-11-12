@testable import VerseSpeech
import XCTest

/// Review S8: the silence pump must not fill zeros for audio that is still on its way from a slow input, which would then be
/// trimmed off the real chunk. Pure timeline arithmetic, no audio stack.
final class FeedTimelineTests: XCTestCase {
    private let rate = 16_000.0
    private let chunk = 0.02            // 20 ms chunks

    /// Replays `seconds` of continuous capture whose chunks each arrive `latency` after their capture end, with the pipeline's
    /// 50 ms ticks interleaved by clock time. Returns the timeline afterwards.
    private func replay(latency: TimeInterval, jitter: TimeInterval = 0, seconds: TimeInterval) -> FeedTimeline {
        var t = FeedTimeline(pumpAfter: ChannelPipeline.pumpAfter)
        enum Event { case tick(TimeInterval), audio(start: TimeInterval, arrive: TimeInterval) }
        var events: [Event] = []
        var start = 0.0, i = 0, lastArrival = 0.0
        while start < seconds {
            // Bursty delivery: every fifth chunk is held back by `jitter` on top of the latency (and the ones behind it wait).
            let extra = i % 5 == 4 ? jitter : 0
            lastArrival = max(lastArrival, start + chunk + latency + extra)
            events.append(.audio(start: start, arrive: lastArrival))
            start += chunk; i += 1
        }
        var tick = 0.05
        while tick < seconds + latency + jitter + 0.1 { events.append(.tick(tick)); tick += 0.05 }
        func time(_ e: Event) -> TimeInterval { switch e { case .tick(let n): n; case .audio(_, let a): a } }
        for e in events.sorted(by: { time($0) < time($1) }) {
            switch e {
            case .tick(let now): _ = t.pump(now: now, rate: rate)
            case .audio(let s, let a):
                _ = t.place(start: s, end: s + chunk, count: Int(chunk * rate), rate: rate, arrivedAt: a)
            }
        }
        return t
    }

    func testPromptInputNeverLosesAudio() {
        XCTAssertEqual(replay(latency: 0.005, seconds: 3).droppedSamples, 0)
    }

    /// A Bluetooth-like input: chunks arrive 250 ms after capture, with a further 80 ms held back now and then. Without the
    /// lateness tracking the pump fills ahead of every chunk and most of the speech is trimmed.
    func testLateInputKeepsItsAudio() {
        let t = replay(latency: 0.25, jitter: 0.08, seconds: 3)
        XCTAssertEqual(t.droppedSamples, 0, "real audio was trimmed in place of pumped silence")
        XCTAssertEqual(t.lateness, 0.25 + 0.08, accuracy: 0.01)
    }

    /// The pump still works for a late input: when chunks stop, silence follows within lateness + pumpAfter (well under 1 s),
    /// and audio that resumes later is padded, not trimmed.
    func testPumpStillFillsAfterRealSilence() throws {
        var t = FeedTimeline(pumpAfter: ChannelPipeline.pumpAfter)
        _ = t.place(start: 0, end: 0.5, count: 8000, rate: rate, arrivedAt: 0.75)
        XCTAssertNil(t.pump(now: 0.85, rate: rate), "pumped while the next chunk could still be on its way")
        let (n, end) = try XCTUnwrap(t.pump(now: 0.95, rate: rate))
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(end, 0.95 - 0.25 - ChannelPipeline.pumpAfter / 2, accuracy: 0.001)
        let fit = t.place(start: 2.0, end: 2.02, count: 320, rate: rate, arrivedAt: 2.27)
        XCTAssertGreaterThan(fit.pad, 0)
        XCTAssertEqual(fit.drop, 0)
    }

    /// A single stalled callback does not switch the pump off: lateness is capped, and it decays as prompt audio follows.
    func testStallIsCappedAndDecays() {
        var t = FeedTimeline(pumpAfter: ChannelPipeline.pumpAfter)
        _ = t.place(start: 0, end: 0.02, count: 320, rate: rate, arrivedAt: 3.0)
        XCTAssertEqual(t.lateness, FeedTimeline.maxLateness)
        var s = 0.02
        while s < 6 { _ = t.place(start: s, end: s + chunk, count: 320, rate: rate, arrivedAt: s + chunk + 0.005); s += chunk }
        XCTAssertLessThan(t.lateness, 0.3)
    }
}
