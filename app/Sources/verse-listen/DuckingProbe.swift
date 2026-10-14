@preconcurrency import AVFoundation
import Foundation
import os
import VerseSpeech

/// `verse-listen --probe-ducking`: measures how much voice processing ducks another app's audio.
/// A child `verse-listen --emit-test-tone` plays a quiet tone (from memory); a bundle-ID process tap on it measures
/// its level (the tap sees the ducked signal) while the mic runs without VP, with VP at the default ducking, and
/// with VP at Verse's minimum ducking (MicSource). Numbers only; nothing is written.
enum DuckingProbe {
    final class Meter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var ss = 0.0
        private var n = 0
        func add(_ c: AudioChunk) {
            var s = 0.0
            for v in c.samples { s += Double(v * v) }
            lock.withLockUnchecked { ss += s; n += c.samples.count }
        }
        func takeDb() -> Double? {
            lock.withLockUnchecked {
                defer { ss = 0; n = 0 }
                guard n > 0, ss > 0 else { return nil }
                return 20 * log10((ss / Double(n)).squareRoot())
            }
        }
    }

    static func median(_ meter: Meter, seconds: Double) async -> Double? {
        _ = meter.takeDb()
        var v: [Double] = []
        for _ in 0..<Int(seconds / 0.25) {
            try? await Task.sleep(for: .milliseconds(250))
            if let d = meter.takeDb() { v.append(d) }
        }
        guard !v.isEmpty else { return nil }
        return v.sorted()[v.count / 2]
    }

    static func run() async {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let tone = Process()
        tone.executableURL = me
        tone.arguments = ["--emit-test-tone", "40"]
        do { try tone.run() } catch { fail("cannot start tone child: \(error)") }
        defer { if tone.isRunning { tone.terminate(); tone.waitUntilExit() } }
        try? await Task.sleep(for: .seconds(1))

        let meter = Meter()
        let tap = ProcessTapSource(bundleIDs: ["dev.verse.listen"], preference: .bundleID)
        do {
            try tap.start(clock: SessionClock(), onChunk: { meter.add($0) }, onEnd: {})
        } catch { fail("tap: \(error)") }
        defer { tap.stop() }

        var rows: [[String: Any]] = []
        func row(_ label: String, _ db: Double?) {
            rows.append(["phase": label, "toneDbfs": db.map { (($0 * 10).rounded()) / 10 } ?? NSNull()])
        }
        let base = await median(meter, seconds: 3)
        row("no voice processing", base)

        // Default ducking (what setVoiceProcessingEnabled(true) does unless configured).
        do {
            let e = AVAudioEngine()
            _ = e.outputNode; _ = e.mainMixerNode
            try e.inputNode.setVoiceProcessingEnabled(true)
            let sink = AVAudioSinkNode { _, _, _ in noErr }
            e.attach(sink)
            e.connect(e.inputNode, to: sink, format: e.inputNode.outputFormat(forBus: 0))
            try e.start()
            try? await Task.sleep(for: .milliseconds(700))
            row("voice processing, default ducking", await median(meter, seconds: 3))
            e.stop()
            try? e.inputNode.setVoiceProcessingEnabled(false)
        } catch { row("voice processing, default ducking (failed: \(error))", nil) }
        try? await Task.sleep(for: .milliseconds(700))
        row("no voice processing (again)", await median(meter, seconds: 2))

        // Verse's MicSource with voice processing on: minimum ducking, advanced ducking off.
        let mic = MicSource(voiceProcessing: true)
        do {
            try mic.start(clock: SessionClock(), onChunk: { _ in }, onEnd: {})
            try? await Task.sleep(for: .milliseconds(700))
            row("voice processing, Verse minimum (\(mic.appliedDucking ?? "?"))", await median(meter, seconds: 3))
            mic.stop()
        } catch { row("voice processing, Verse minimum (failed: \(error))", nil) }
        try? await Task.sleep(for: .milliseconds(700))
        row("no voice processing (end)", await median(meter, seconds: 2))

        for r in rows {
            var out = r
            if let b = base, let d = r["toneDbfs"] as? Double { out["deltaDb"] = ((d - b) * 10).rounded() / 10 }
            status(out.merging(["type": "ducking"]) { a, _ in a })
        }
        status(["type": "ducking", "route": tap.routeDescription, "outputDevice": defaultOutputName() ?? "?"])
    }
}
