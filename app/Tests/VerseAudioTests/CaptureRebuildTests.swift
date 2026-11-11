import CoreAudio
import Foundation
import os
@testable import VerseAudio
import XCTest

/// Review H5: the rebuild after an audio device change (no hardware: the rebuild step and the decision are exercised directly).
final class CaptureRebuildTests: XCTestCase {

    final class Recorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var events_: [CaptureEvent] = []
        private var calls_ = 0
        var events: [CaptureEvent] { lock.withLockUnchecked { events_ } }
        var calls: Int { lock.withLockUnchecked { calls_ } }
        func add(_ e: CaptureEvent) { lock.withLockUnchecked { events_.append(e) } }
        func call() -> Int { lock.withLockUnchecked { calls_ += 1; return calls_ } }
    }

    struct Boom: Error, CustomStringConvertible { var description: String { "no input device (format 0 Hz)" } }

    private func rebuilder(_ rec: Recorder, failFirst: Int = 0, rebuilt: Bool = true, retries: Int = 3) -> CaptureRebuilder {
        CaptureRebuilder(queue: DispatchQueue(label: "test.rebuild"), debounce: 0.02,
                         retryDelays: Array(repeating: 0.01, count: retries),
                         rebuild: {
                             let n = rec.call()
                             if n <= failFirst { throw Boom() }
                             return rebuilt
                         },
                         report: { rec.add($0) })
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// A burst of notifications (AirPods connecting fires several) makes one rebuild and one report.
    func testBurstOfTriggersRebuildsOnce() async {
        let rec = Recorder()
        let rb = rebuilder(rec)
        for _ in 0..<5 { rb.trigger("audio engine configuration changed") }
        rb.trigger("default input device changed")
        await settle()
        XCTAssertEqual(rec.calls, 1)
        XCTAssertEqual(rec.events, [.rebuilt("audio engine configuration changed; default input device changed")])
    }

    /// A device that is still appearing fails the first attempts; the retry gets it and reports one `.rebuilt`.
    func testRetriesUntilTheDeviceIsReady() async {
        let rec = Recorder()
        let rb = rebuilder(rec, failFirst: 2)
        rb.trigger("default input device changed")
        await settle()
        XCTAssertEqual(rec.calls, 3)
        XCTAssertEqual(rec.events, [.rebuilt("default input device changed")])
    }

    /// Every retry failed: one `.failed` with the reason, so the session can say the channel is silent.
    func testGivesUpAfterTheRetriesAndSaysWhy() async {
        let rec = Recorder()
        let rb = rebuilder(rec, failFirst: 100, retries: 2)
        rb.trigger("default input device changed")
        await settle()
        XCTAssertEqual(rec.calls, 3, "first attempt + 2 retries")
        guard case .failed(let why)? = rec.events.first, rec.events.count == 1 else { return XCTFail("\(rec.events)") }
        XCTAssertTrue(why.contains("default input device changed"), why)
        XCTAssertTrue(why.contains("0 Hz"), why)
        // A later device change starts a new pass (AirPods back): it can still recover.
        rb.trigger("default input device changed")
        await settle()
        XCTAssertEqual(rec.calls, 6)
    }

    /// A notification caused by the rebuild itself finds nothing to do: no report, no loop.
    func testNothingToDoReportsNothing() async {
        let rec = Recorder()
        let rb = rebuilder(rec, rebuilt: false)
        rb.trigger("tap format changed")
        await settle()
        XCTAssertEqual(rec.calls, 1)
        XCTAssertEqual(rec.events, [])
    }

    /// After `stop()` (cancel) a pending pass does not run.
    func testCancelledRebuilderDoesNothing() async {
        let rec = Recorder()
        let rb = rebuilder(rec)
        rb.trigger("default input device changed")
        rb.cancel()
        await settle()
        XCTAssertEqual(rec.calls, 0)
        XCTAssertEqual(rec.events, [])
    }

    /// The mic's decision: a stopped engine, another default input or another format needs a new engine; nothing else does.
    func testMicRebuildDecision() {
        func needs(running: Bool = true, rate: Double = 48000, ch: UInt32 = 1, dev: AudioObjectID = 42) -> Bool {
            MicSource.needsRebuild(running: running, builtRate: 48000, builtChannels: 1, builtDevice: 42,
                                   nowRate: rate, nowChannels: ch, nowDevice: dev)
        }
        XCTAssertFalse(needs(), "same device, same format, running: a spurious notification")
        XCTAssertTrue(needs(running: false), "AVAudioEngine stopped itself on a configuration change")
        XCTAssertTrue(needs(rate: 24000), "AirPods in headset mode")
        XCTAssertTrue(needs(ch: 2))
        XCTAssertTrue(needs(dev: 77), "EarPods plugged in: the default input changed")
    }

    /// The tap's decision: no tap or an unreadable format, another format or another default output needs a new tap.
    func testTapRebuildDecision() {
        func needs(exists: Bool = true, rate: Double? = 48000, ch: UInt32? = 2, dev: AudioObjectID = 7) -> Bool {
            ProcessTapSource.needsRebuild(tapExists: exists, builtRate: 48000, builtChannels: 2, builtDevice: 7,
                                          nowRate: rate, nowChannels: ch, nowDevice: dev)
        }
        XCTAssertFalse(needs())
        XCTAssertTrue(needs(exists: false), "a failed PID refresh left no tap")
        XCTAssertTrue(needs(rate: nil), "format unreadable")
        XCTAssertTrue(needs(rate: 44100), "chunks would carry the old rate")
        XCTAssertTrue(needs(dev: 9), "output moved to AirPods")
    }

    // MARK: the meeting app on a non-default output device

    /// The meeting app's own output devices (any device, not only the default): a move or a format change of a device it
    /// plays to rebuilds; the app starting or pausing its output does not.
    func testAppOutputDecision() {
        func change(_ built: [AudioObjectID: Double], _ now: [AudioObjectID: Double]) -> ProcessTapSource.AppOutputChange {
            ProcessTapSource.appOutputChange(built: built, now: now)
        }
        XCTAssertEqual(change([5: 48000], [5: 48000]), .none)
        XCTAssertEqual(change([:], [:]), .none)
        XCTAssertEqual(change([:], [5: 48000]), .adopt, "the call's audio starts after the tap was built: same as a session start")
        XCTAssertEqual(change([5: 48000], [:]), .none, "the app paused its output: keep what it played to")
        guard case .rebuild(let moved) = change([5: 48000], [9: 48000]) else { return XCTFail("USB headset unplugged, Zoom moved on") }
        XCTAssertTrue(moved.contains("5") && moved.contains("9"), moved)
        guard case .rebuild = change([5: 48000], [5: 44100]) else { return XCTFail("the app's device changed rate") }
        guard case .rebuild = change([5: 48000], [5: 48000, 9: 48000]) else { return XCTFail("a helper plays to a second device") }
        guard case .rebuild = change([5: 48000], [5: 0]) else { return XCTFail("rate unreadable: the device is going away") }
    }

    /// What the tap listens to: the device list, the process list, each meeting process's output devices and each device
    /// it plays to (its nominal rate), whether or not that device is the default output.
    func testTapWatchesTheDevicesTheMeetingAppUses() {
        let keys = ProcessTapSource.watchKeys(processes: [101, 102], devices: [5, 9])
        let out = kAudioObjectPropertyScopeOutput
        XCTAssertTrue(keys.contains(AudioWatchKey(object: CA.system, selector: kAudioHardwarePropertyDevices)))
        XCTAssertTrue(keys.contains(AudioWatchKey(object: CA.system, selector: kAudioHardwarePropertyProcessObjectList)))
        for p: AudioObjectID in [101, 102] {
            XCTAssertTrue(keys.contains(AudioWatchKey(object: p, selector: kAudioProcessPropertyDevices, scope: out)), "process \(p)")
        }
        for d: AudioObjectID in [5, 9] {
            XCTAssertTrue(keys.contains(AudioWatchKey(object: d, selector: kAudioDevicePropertyNominalSampleRate)), "device \(d)")
        }
        XCTAssertEqual(keys.count, 6)
        XCTAssertEqual(ProcessTapSource.watchKeys(processes: [], devices: []).count, 2, "no meeting app: only the system lists")
    }

    /// Listener bookkeeping: a sync adds what is new and removes what is gone, nothing else.
    func testWatchDiff() {
        let a = AudioWatchKey(object: 5, selector: kAudioDevicePropertyNominalSampleRate)
        let b = AudioWatchKey(object: 9, selector: kAudioDevicePropertyNominalSampleRate)
        let c = AudioWatchKey(object: 101, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        let d = AudioPropertyWatch.diff(current: [a, b], desired: [b, c])
        XCTAssertEqual(d.add, [c])
        XCTAssertEqual(d.remove, [a])
    }

    /// The stall watchdog: no IOProc callback at all for the threshold while the meeting app is sending audio to an output.
    /// Ordinary silence still delivers callbacks (zeros), so it never counts; an app that is not playing (or unknown) never
    /// counts; one rebuild per stall (latched until a callback arrives again).
    func testStallDecision() {
        func stalled(now: Double = 10, last: Double? = 6, built: Double = 0, latched: Bool = false, producing: Bool? = true) -> Bool {
            ProcessTapSource.isStalled(now: now, lastCallback: last, builtAt: built, threshold: 3, latched: latched,
                                       producing: { producing })
        }
        XCTAssertTrue(stalled(), "callbacks stopped 4 s ago while the app plays")
        XCTAssertFalse(stalled(last: 9.99), "callbacks keep coming (silence is zeros, not missing callbacks)")
        XCTAssertFalse(stalled(producing: false), "the app is not playing: nothing to hear")
        XCTAssertFalse(stalled(producing: nil), "unknown: never a false positive")
        XCTAssertFalse(stalled(latched: true), "already rebuilt for this stall")
        XCTAssertTrue(stalled(last: nil, built: 5), "no callback since the tap was built 5 s ago")
        XCTAssertFalse(stalled(last: nil, built: 8), "a fresh tap gets its grace period")
    }

    // MARK: silent tap (calls back with exact zeros while the meeting app plays)

    /// Drives a watch with one exact-zero buffer every 10 ms from `from` to `to` and a check every second; returns the actions.
    private func runZeros(_ w: inout SilentTapWatch, from: Double, to: Double, producing: Bool? = true) -> [(Double, SilentTapWatch.Action)] {
        var out: [(Double, SilentTapWatch.Action)] = []
        var t = from, nextCheck = from.rounded(.up)
        while t < to {
            w.buffer(zero: true, at: t)
            if t >= nextCheck {
                let a = w.check(now: t, lastCallback: t, producing: { producing })
                if a != .none { out.append((t, a)) }
                nextCheck += 1
            }
            t += 0.01
        }
        return out
    }

    /// Strong evidence only: the tap calls back, every buffer is exact zero and the app reports running output for the whole
    /// `firstProbeAfter`. Then at most two quiet probes per zero run, the second 30 s after the first, then nothing.
    func testSilentTapProbesAfterSustainedZerosWithABudget() {
        var w = SilentTapWatch()
        let actions = runZeros(&w, from: 0, to: 120)
        XCTAssertEqual(actions.count, 2, "\(actions)")
        guard actions.count == 2, case .probe(1, let s1) = actions[0].1, case .probe(2, _) = actions[1].1 else { return XCTFail("\(actions)") }
        XCTAssertEqual(actions[0].0, 10, accuracy: 1.01, "first probe after 10 s of zeros")
        XCTAssertEqual(s1, 10, accuracy: 1.01)
        XCTAssertEqual(actions[1].0 - actions[0].0, 30, accuracy: 1.01, "backoff before the second")
    }

    /// A silent remote side in an app that is not playing (or unknown) never probes; an interruption of "producing" restarts
    /// the wait.
    func testSilentTapNeedsTheAppPlayingTheWholeTime() {
        var a = SilentTapWatch()
        XCTAssertTrue(runZeros(&a, from: 0, to: 60, producing: false).isEmpty, "app not playing: ordinary silence")
        var b = SilentTapWatch()
        XCTAssertTrue(runZeros(&b, from: 0, to: 60, producing: nil).isEmpty, "unknown counts as no")
        var c = SilentTapWatch()
        XCTAssertTrue(runZeros(&c, from: 0, to: 8).isEmpty)
        XCTAssertTrue(runZeros(&c, from: 8, to: 9, producing: false).isEmpty, "output paused for a moment")
        let after = runZeros(&c, from: 9, to: 25)
        guard let first = after.first, case .probe(1, _) = first.1 else { return XCTFail("\(after)") }
        XCTAssertGreaterThanOrEqual(first.0, 19, "the 10 s count restarts when the app plays again")
    }

    /// A tap that stopped calling back is the stall watchdog's case, not this one.
    func testSilentTapIgnoresATapThatStoppedCallingBack() {
        var w = SilentTapWatch()
        w.buffer(zero: true, at: 0)
        for t in stride(from: 1.0, through: 30, by: 1) {
            XCTAssertEqual(w.check(now: t, lastCallback: 0.5, producing: { true }), .none, "t=\(t)")
        }
        XCTAssertEqual(w.probes, 0)
    }

    /// Audio within the confirm window after a probe: the probe repaired the tap, reported once. Audio later than that is the
    /// remote side talking again: nothing is reported, and the budget starts over for the next zero run.
    func testSilentTapReportsRecoveryOnlyRightAfterAProbe() {
        var w = SilentTapWatch()
        let probes = runZeros(&w, from: 0, to: 11)
        guard let p = probes.first?.0 else { return XCTFail("no probe") }
        w.buffer(zero: false, at: p + 1)
        XCTAssertEqual(w.check(now: p + 1.5, lastCallback: p + 1, producing: { true }), .recovered)
        XCTAssertEqual(w.check(now: p + 2.5, lastCallback: p + 2, producing: { true }), .none, "said once")
        XCTAssertEqual(w.probes, 0, "a non-zero buffer ends the zero run and its budget")

        var late = SilentTapWatch()
        let lp = runZeros(&late, from: 0, to: 11)
        guard let q = lp.first?.0 else { return XCTFail("no probe") }
        _ = runZeros(&late, from: 11, to: q + 8)
        late.buffer(zero: false, at: q + 8)
        XCTAssertEqual(late.check(now: q + 8.5, lastCallback: q + 8, producing: { true }), .none, "8 s after the probe: not its doing")
    }

    /// A rebuild only the silent probe asked for is not reported at once (`.rebuilt` would claim a repair that may not have
    /// happened); with any other cause it is.
    func testQuietProbeRebuildIsNotReported() {
        XCTAssertFalse(ProcessTapSource.reportRebuild(tapChanged: false, stall: false, appRebuild: false, probe: true))
        XCTAssertTrue(ProcessTapSource.reportRebuild(tapChanged: true, stall: false, appRebuild: false, probe: true))
        XCTAssertTrue(ProcessTapSource.reportRebuild(tapChanged: false, stall: true, appRebuild: false, probe: true))
        XCTAssertTrue(ProcessTapSource.reportRebuild(tapChanged: false, stall: false, appRebuild: true, probe: true))
        XCTAssertTrue(ProcessTapSource.reportRebuild(tapChanged: true, stall: false, appRebuild: false, probe: false))
    }

    /// Review M7: a failed PID-list refresh keeps the old list, so the next notification (even with the same list) retries.
    func testFailedPIDRefreshKeepsTheOldList() {
        XCTAssertEqual(ProcessTapSource.objectsAfterRefresh(old: [1, 2], attempted: [1, 2, 3], failed: true), [1, 2])
        XCTAssertEqual(ProcessTapSource.objectsAfterRefresh(old: [1, 2], attempted: [1, 2, 3], failed: false), [1, 2, 3])
    }
}
