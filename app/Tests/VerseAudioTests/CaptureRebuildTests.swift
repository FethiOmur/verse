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
}
