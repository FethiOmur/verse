@preconcurrency import AVFoundation
import Foundation
import os
import VerseAudio
import VerseSpeech
@testable import VerseTurns
import XCTest

/// Opt-in measurement of the interim AUTO language mode on the REAL Apple recognizers: an Italian TTS clip followed by an English
/// TTS clip (macOS `say`, fictional sentences, rendered to a temp folder, read into memory and deleted at once), played to the
/// runner as a live call. Reports the time to switch and the CPU / RAM of the speech services with the shadow off and on.
///
///     VERSE_REAL_AUTO=1 swift test --filter RealAutoLanguageCheck
///
/// Skipped otherwise. Nothing is recorded; the clip lives in memory.
final class RealAutoLanguageCheck: XCTestCase {

    /// A source that plays `clip` as if it were a live call: when it starts it delivers the audio from the wall-clock moment
    /// the call is at, so a pipeline swapped in mid-call hears what is being said now and misses what was said during the swap.
    final class LiveClipSource: AudioCaptureSource, @unchecked Sendable {
        private let clip: PCMClip
        private let call: CallClock
        private let lock = OSAllocatedUnfairLock()
        private var task: Task<Void, Never>?
        init(clip: PCMClip, call: CallClock) { self.clip = clip; self.call = call }
        var routeDescription: String { "live clip" }
        func targetIsProducingOutput() -> Bool? { nil }
        func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
            let t0 = clock.now()
            let startAt = call.elapsed()
            let clip = self.clip
            let step = 160
            let t = Task.detached(priority: .userInitiated) {
                let cc = ContinuousClock()
                let base = cc.now
                var i = 0
                var pos = Int(startAt * clip.sampleRate)
                while !Task.isCancelled, pos < clip.samples.count {
                    try? await cc.sleep(until: base + .milliseconds(10 * (i + 1)))
                    if Task.isCancelled { break }
                    let end = min(clip.samples.count, pos + step)
                    onChunk(AudioChunk(samples: Array(clip.samples[pos..<end]), sampleRate: clip.sampleRate, startTime: t0 + Double(i) * 0.01))
                    pos = end
                    i += 1
                }
                if !Task.isCancelled { onEnd() }
            }
            lock.withLockUnchecked { task = t }
        }
        func stop() { lock.withLockUnchecked { task }?.cancel() }
    }

    final class CallClock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var t0: Date?
        func elapsed() -> Double {
            lock.withLockUnchecked {
                if t0 == nil { t0 = Date() }
                return Date().timeIntervalSince(t0!)
            }
        }
    }

    final class Lines: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLockUnchecked { items.append(s) } }
        var all: [String] { lock.withLockUnchecked { items } }
    }

    static func clip(voice: String, text: String) throws -> PCMClip {
        let f = try SayFixture.make(voice: voice, text: text)
        defer { f.delete() }
        return try PCMClip.read(f.file)
    }

    // MARK: process sampling

    final class PeakBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var m: [String: Int] = [:]
        func note(_ name: String, _ kb: Int) { lock.withLockUnchecked { m[name] = max(m[name] ?? 0, kb) } }
        var all: [String: Int] { lock.withLockUnchecked { m } }
    }

    struct Proc { var cpu: Double; var rssKB: Int; var name: String }

    /// Every process: cumulative CPU seconds and RSS (KB), keyed by pid.
    static func snapshot() -> [Int: Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,cputime=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [Int: Proc] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let rss = Int(parts[2]) else { continue }
            let t = parts[1].split(separator: ":").compactMap { Double($0) }
            let cpu = t.count == 2 ? t[0] * 60 + t[1] : (t.count == 3 ? t[0] * 3600 + t[1] * 60 + t[2] : 0)
            out[pid] = Proc(cpu: cpu, rssKB: rss, name: (String(parts[3]) as NSString).lastPathComponent)
        }
        return out
    }

    struct Run {
        var label: String
        var wall: Double
        var cpuByName: [(name: String, cpu: Double)]
        var peakRSS: [String: Int]
        var speechCPU: Double
        var ourCPU: Double
        var speechRSSMB: Int
        var ourRSSMB: Int
        var decisionAt: Double?
        var swapOffset: Double?
        var gapMs: Double?
        var langs: [String]
        var shadowLines: [String]
        var mainFinals: [String]
        var turns: [(String, String)]
    }

    func runOnce(label: String, clip: PCMClip, onset: Double, auto: Bool, shadow: Bool) async throws -> Run {
        let call = CallClock()
        let env = ListenEnvironment(
            permissions: FixedPermissions(),
            makeRemoteSource: { _ in LiveClipSource(clip: clip, call: call) },
            makeMicSource: { _ in nil },
            // The Apple engine for every language (the English production engine is Nemotron; its 600 MB are not part of this question).
            makeEngine: { cfg in
                var c = cfg
                c.engineKind = EngineFactory.defaultKind(for: cfg.lang)
                return try EngineFactory.make(config: c)
            })
        let session = try TempSession()
        defer { session.delete() }
        var o = RunOptions(sessionDir: session.dir)
        o.listenEnvironment = env
        o.source = nil
        o.lang = "it"
        o.route = .meeting
        o.mode = .unprepared
        o.fakeBrain = true
        o.brainDir = try brainDir()
        o.seconds = clip.duration + 4
        o.drainSeconds = 2
        o.quietSeconds = 0.5
        o.autoLanguage = auto
        o.autoShadow = shadow
        o.trace = true
        let lines = Lines()
        let rec = SinkRecorder()
        o.sink = rec.sink
        let mainFinals = Lines()
        o.transcriptTap = { e in if e.isFinal { mainFinals.add("\(e.lang) \(String(format: "%.1f-%.1f", e.audioStart, e.audioEnd)) \(e.text)") } }
        let runner = VerseRunner(options: o, log: { lines.add($0) })
        let task = Task { await runner.run() }
        let t0 = Date()
        while !rec.all.contains(where: { if case .metric(let m) = $0 { return m[string: "stage"] == "session_t0" }; return false }) {
            if Date().timeIntervalSince(t0) > 90 { runner.requestStop(); _ = await task.value; throw XCTSkip("the brain never became ready") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = call.elapsed()          // the call starts now
        let before = Self.snapshot()
        let start = Date()
        let peak = PeakBox()
        let sampler = Task {
            while !Task.isCancelled {
                for (_, p) in Self.snapshot() where p.rssKB > 20_000 { peak.note(p.name, p.rssKB) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        try await Task.sleep(for: .seconds(clip.duration + 1.5))
        sampler.cancel()
        let after = Self.snapshot()
        let wall = Date().timeIntervalSince(start)
        runner.requestStop()
        _ = await task.value
        var byName: [String: Double] = [:]
        for (pid, a) in after {
            if let b = before[pid], a.name == b.name { byName[a.name, default: 0] += max(0, a.cpu - b.cpu) }
        }
        let speechCPU = byName.filter { $0.key.lowercased().contains("speechrecognition") || $0.key.lowercased().contains("speechanalyzer") }.values.reduce(0, +)
        let ourCPU = byName["xctest"] ?? 0
        let speechRSS = (peak.all.filter { $0.key.lowercased().contains("speechrecognition") || $0.key.lowercased().contains("speechanalyzer") }.values.max() ?? 0) / 1024
        let ourRSS = (peak.all["xctest"] ?? 0) / 1024
        let top = byName.filter { $0.value >= 0.05 }.sorted { $0.value > $1.value }.prefix(8).map { (name: $0.key, cpu: $0.value) }
        let metrics = rec.all.compactMap { e -> [String: JSONValue]? in if case .metric(let m) = e { return m }; return nil }
        let decision = metrics.first { $0[string: "stage"] == "lang_auto" }
        let swap = metrics.first { $0[string: "stage"] == "listen_swap" }
        let turns = rec.all.compactMap { e -> (String, String)? in
            if case .outbound(let o) = e, o.type == "turn" { return (o[string: "lang"] ?? "-", o[string: "text"] ?? "") }
            return nil
        }
        return Run(label: label, wall: wall, cpuByName: Array(top), peakRSS: peak.all, speechCPU: speechCPU, ourCPU: ourCPU,
                   speechRSSMB: speechRSS, ourRSSMB: ourRSS,
                   decisionAt: decision?[double: "t"], swapOffset: swap?[double: "offset"], gapMs: swap?[double: "gap_ms"],
                   langs: metrics.filter { $0[string: "stage"] == "lang_auto" }.map { "\($0[string: "from"] ?? "?")>\($0[string: "to"] ?? "?")" },
                   shadowLines: lines.all.filter { $0.contains("trace shadow") },
                   mainFinals: mainFinals.all, turns: turns)
    }

    func testItalianThenEnglishOnRealEngines() async throws {
        guard ProcessInfo.processInfo.environment["VERSE_REAL_AUTO"] != nil else {
            throw XCTSkip("opt-in measurement: VERSE_REAL_AUTO=1 (real Apple recognizers, about 3 minutes)")
        }
        let it = try Self.clip(voice: "Alice", text: "Buongiorno a tutti. Puoi raccontarmi come hai costruito il servizio di instradamento? Poi vorrei capire come avete gestito la migrazione dei dati.")
        let en = try Self.clip(voice: "Samantha", text: "Thanks, that is clear. And what was the hardest part of the whole migration? Tell me how the team handled the rollout and the monitoring afterwards.")
        let gap = Int(0.8 * it.sampleRate)
        let tail = Int(3.0 * it.sampleRate)
        let both = PCMClip(samples: it.samples + [Float](repeating: 0, count: gap) + en.samples + [Float](repeating: 0, count: tail), sampleRate: it.sampleRate)
        let onset = it.duration + 0.8
        print("[auto-real] clip: it \(String(format: "%.1f", it.duration)) s, then en at \(String(format: "%.1f", onset)) s, total \(String(format: "%.1f", both.duration)) s")

        let base = try await runOnce(label: "pinned it (baseline)", clip: both, onset: onset, auto: false, shadow: false)
        let main = try await runOnce(label: "auto, main text only", clip: both, onset: onset, auto: true, shadow: false)
        let full = try await runOnce(label: "auto + shadow", clip: both, onset: onset, auto: true, shadow: true)
        let again = try await runOnce(label: "auto + shadow (repeat)", clip: both, onset: onset, auto: true, shadow: true)
        let base2 = try await runOnce(label: "pinned it (baseline, repeat)", clip: both, onset: onset, auto: false, shadow: false)
        for r in [base, main, full, again, base2] {
            print("[auto-real] SUMMARY \(r.label): localspeechrecognition cpu \(String(format: "%.2f", r.speechCPU)) s (\(String(format: "%.1f", r.speechCPU / r.wall * 100)) % of a core), rss peak \(r.speechRSSMB) MB; test process cpu \(String(format: "%.2f", r.ourCPU)) s (\(String(format: "%.1f", r.ourCPU / r.wall * 100)) %), rss peak \(r.ourRSSMB) MB")
            print("[auto-real] ---- \(r.label): wall \(String(format: "%.1f", r.wall)) s")
            print("[auto-real]   switches: \(r.langs), decision at run t=\(r.decisionAt.map { String(format: "%.1f", $0) } ?? "-") s (onset \(String(format: "%.1f", onset)) s) -> \(r.decisionAt.map { String(format: "%.1f s after onset", $0 - onset) } ?? "none")")
            print("[auto-real]   new pipeline listening from run t=\(r.swapOffset.map { String(format: "%.1f", $0) } ?? "-") s, swap gap \(r.gapMs.map { String(format: "%.0f ms", $0) } ?? "-")")
            for (n, c) in r.cpuByName { print("[auto-real]   cpu \(n): \(String(format: "%.2f", c)) s = \(String(format: "%.1f", c / r.wall * 100)) %") }
            for (n, k) in r.peakRSS.sorted(by: { $0.value > $1.value }).prefix(5) { print("[auto-real]   peak rss \(n): \(k / 1024) MB") }
            for t in r.turns { print("[auto-real]   turn [\(t.0)] \(t.1)") }
            for f in r.mainFinals { print("[auto-real]   main final \(f)") }
            for s in r.shadowLines.prefix(12) { print("[auto-real]   \(s)") }
        }
        XCTAssertTrue(base.langs.isEmpty, "pinned: no switch")
    }
}
