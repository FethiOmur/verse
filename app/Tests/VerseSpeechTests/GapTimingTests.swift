import Foundation
import os
import VerseSpeech
import XCTest

/// Plays clip A, delivers nothing for `gap` seconds (no callbacks, like a tap whose app went away), then clip B.
final class GapSource: AudioCaptureSource, @unchecked Sendable {
    let a: PCMClip, b: PCMClip, gap: Double
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Never>?
    private(set) var bStartTime: TimeInterval = 0
    init(a: PCMClip, b: PCMClip, gap: Double) { self.a = a; self.b = b; self.gap = gap }
    var routeDescription: String { "gap source" }
    func targetIsProducingOutput() -> Bool? { false }
    func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        let a = self.a, b = self.b, gap = self.gap
        let t0 = clock.now()
        let bStart = t0 + a.duration + gap
        lock.withLockUnchecked { bStartTime = bStart }
        task = Task.detached {
            let cc = ContinuousClock()
            let base = cc.now
            func play(_ c: PCMClip, at offset: Double, tail: Double) async {
                let frames = Int(c.sampleRate * 0.01)
                let total = c.samples.count + Int(tail * c.sampleRate)
                var pos = 0, i = 0
                while pos < total, !Task.isCancelled {
                    let n = min(frames, total - pos)
                    var chunk = [Float](repeating: 0, count: n)
                    for k in 0..<n where pos + k < c.samples.count { chunk[k] = c.samples[pos + k] }
                    try? await cc.sleep(until: base + .seconds(offset + Double(i + 1) * 0.01))
                    onChunk(AudioChunk(samples: chunk, sampleRate: c.sampleRate, startTime: t0 + offset + Double(i) * 0.01))
                    pos += n; i += 1
                }
            }
            await play(a, at: 0, tail: 0)
            await play(b, at: a.duration + gap, tail: 2.0)
            onEnd()
        }
    }
    func stop() { task?.cancel() }
}

final class GapTimingTests: XCTestCase {
    /// A 3 s stretch without any callbacks: clip A's last word still arrives promptly, and clip B's words are placed
    /// at their true session time.
    func testLongGapKeepsAudioTimesOnSessionClock() async throws {
        let a = try SayFixture.clip(voice: "Samantha", text: "First question about the budget.")
        let b = try SayFixture.clip(voice: "Samantha", text: "Second question about the timeline.")
        let bBounds = try XCTUnwrap(b.speechBounds())
        let source = GapSource(a: a, b: b, gap: 3.0)
        let env = ListenEnvironment(permissions: FixedPermissions(), makeRemoteSource: { _ in source },
                                    makeMicSource: { _ in nil }, makeEngine: ListenEnvironment.system.makeEngine)
        let session = ListenSession(config: ListenConfig(lang: "en", micEnabled: false, source: .live), environment: env)
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        // Clip A's last word must not wait for the gap to end (the pipeline pumps silence when callbacks stop).
        let aEnd = try XCTUnwrap(a.speechBounds()).end + (await session.channelOrigin(.remote) ?? 0)
        let aLast = try XCTUnwrap(events.first { words($0.text).contains("budget") }, "clip A's last word never appeared")
        print(String(format: "[testLongGap] clip A last word after %.2f s (gap of 3 s without callbacks)", aLast.emittedAt - aEnd))
        XCTAssertLessThan(aLast.emittedAt - aEnd, 1.0, "clip A's last word waited for the gap to end")
        let bFinal = try XCTUnwrap(events.last { $0.isFinal && words($0.text).contains("timeline") }, "no final for clip B")
        let expectedEnd = source.bStartTime + bBounds.end
        let err = bFinal.audioEnd - expectedEnd
        print(String(format: "[testLongGap] clip B final '%@' audioEnd %.2f s, true acoustic end %.2f s, error %+.2f s",
                     bFinal.text, bFinal.audioEnd, expectedEnd, err))
        XCTAssertLessThan(abs(err), 0.5, "audio times drifted across the gap")
    }
}
