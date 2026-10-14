import CoreAudio
import CoreGraphics
import Foundation

// TapProbe: proves whether Brave's (or another app's) audio can be captured from a CLI.
// Numbers only: per-10 ms / 100 ms RMS and peaks. No audio is ever written.

struct Args {
    var app = "Brave Browser"
    var seconds = 20.0
    var tests: [String] = ["list", "tap"]
    var label = "unspecified"          // playing | paused | not_playing | unspecified
    var route = "pids"                 // pids | bundle
    var floorDb = -60.0
    var isoSeconds = 12.0
    var bleedSeconds = 15.0
    var requestPermission = 0.0        // >0: trigger the audio-capture prompt and wait this long
    var outDir = "results"
    var watchSeconds = 150.0

    static func parse() -> Args {
        var a = Args()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let k = it.next() {
            func v() -> String { guard let x = it.next() else { fail("missing value for \(k)") }; return x }
            switch k {
            case "--app": a.app = v()
            case "--seconds": a.seconds = Double(v()) ?? a.seconds
            case "--test": a.tests = v().split(separator: ",").map(String.init)
            case "--label": a.label = v()
            case "--route": a.route = v()
            case "--floor-db": a.floorDb = Double(v()) ?? a.floorDb
            case "--iso-seconds": a.isoSeconds = Double(v()) ?? a.isoSeconds
            case "--bleed-seconds": a.bleedSeconds = Double(v()) ?? a.bleedSeconds
            case "--request-permission": a.requestPermission = Double(v()) ?? 0
            case "--out-dir": a.outDir = v()
            case "--watch-seconds": a.watchSeconds = Double(v()) ?? a.watchSeconds
            case "--with-subdevice": TapCapture.defaultWithSubDevice = true
            case "-h", "--help":
                print("""
                TapProbe [--app NAME] [--seconds N] [--test list,tap,isolation,mic_bleed,pause_watch,sck|all]
                         [--label playing|paused|not_playing] [--route pids|bundle] [--floor-db -60]
                         [--iso-seconds 12] [--bleed-seconds 15] [--request-permission SECONDS] [--out-dir results]
                         [--with-subdevice]
                """)
                exit(0)
            default: fail("unknown argument \(k)")
            }
        }
        if a.tests == ["all"] { a.tests = ["list", "tap", "isolation", "mic_bleed", "pause_watch"] }
        return a
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("TapProbe: " + msg + "\n").data(using: .utf8)!)
    Cleanup.shared.run()
    exit(2)
}

/// Everything started by this process, torn down on exit, error or signal.
final class Cleanup: @unchecked Sendable {
    static let shared = Cleanup()
    private let lock = NSLock()
    private var taps: [TapCapture] = []
    private var mics: [MicCapture] = []
    private var children: [Process] = []
    func add(_ t: TapCapture) { lock.lock(); taps.append(t); lock.unlock() }
    func add(_ m: MicCapture) { lock.lock(); mics.append(m); lock.unlock() }
    func add(_ p: Process) { lock.lock(); children.append(p); lock.unlock() }
    func run() {
        lock.lock(); let t = taps, m = mics, c = children; taps = []; mics = []; children = []; lock.unlock()
        for x in t { x.stop() }
        for x in m { x.stop() }
        for p in c where p.isRunning { p.terminate(); p.waitUntilExit() }
    }
}

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { Cleanup.shared.run(); exit(128 + sig) }
        src.resume()
        signalSources.append(src)
    }
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func jsonObject<T: Encodable>(_ v: T) -> Any {
    let d = try! JSONEncoder().encode(v)
    return try! JSONSerialization.jsonObject(with: d)
}

func sleepSeconds(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func fmt(_ x: Double?, _ digits: Int = 1) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "n/a" }

// MARK: targets

struct Targets {
    let osProcs: [OSProcess]
    let audioProcs: [AudioProcessInfo]
    let appAudio: [AudioProcessInfo]
    let bundleIDs: [String]
}

func resolveTargets(app: String) throws -> Targets {
    let os = osProcesses(ofApp: app)
    let pids = Set(os.map { $0.pid })
    let all = try listAudioProcesses()
    let mine = all.filter { pids.contains($0.pid) }
    let bundles = Array(Set(mine.compactMap { $0.bundleID })).sorted()
    return Targets(osProcs: os, audioProcs: all, appAudio: mine, bundleIDs: bundles)
}

func shortName(_ path: String?) -> String {
    guard let p = path else { return "?" }
    if let r = p.range(of: "/Contents/MacOS/") { return String(p[r.upperBound...]) }
    return (p as NSString).lastPathComponent
}

func testList(_ a: Args) throws -> [String: Any] {
    let t = try resolveTargets(app: a.app)
    print("\n== list_targets ==")
    print("Audio-registered processes (coreaudiod): \(t.audioProcs.count); running output now:")
    for p in t.audioProcs where p.isRunningOutput {
        print("  obj \(p.objectID)  pid \(p.pid)  \(p.bundleID ?? "-")  \(shortName(p.path))")
    }
    print("\(a.app): \(t.osProcs.count) OS processes; \(t.appAudio.count) registered with Core Audio:")
    for p in t.appAudio {
        print("  obj \(p.objectID)  pid \(p.pid)  \(p.bundleID ?? "-")  out=\(p.isRunningOutput) in=\(p.isRunningInput)  \(shortName(p.path))")
    }
    let kinds = Dictionary(grouping: t.osProcs, by: { shortName($0.path) }).mapValues { $0.count }
    print("  OS process kinds: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
    let playing = t.appAudio.contains { $0.isRunningOutput }
    print("  \(a.app) audio output running now: \(playing)")
    return [
        "audioRegisteredProcessCount": t.audioProcs.count,
        "runningOutputNow": t.audioProcs.filter { $0.isRunningOutput }.map { jsonObject($0) },
        "appOSProcessCount": t.osProcs.count,
        "appOSProcessKinds": kinds,
        "appAudioProcesses": t.appAudio.map { jsonObject($0) },
        "appBundleIDs": t.bundleIDs,
        "appOutputRunningNow": playing,
    ]
}

// MARK: tap test

func makeTapTarget(_ a: Args, _ t: Targets) throws -> TapTarget {
    if a.route == "bundle" {
        let b = t.bundleIDs.isEmpty ? ["com.brave.Browser", "com.brave.Browser.helper"] : t.bundleIDs
        return .bundleIDs(b)
    }
    if t.appAudio.isEmpty {
        throw CAError(what: "no \(a.app) process is registered with Core Audio (has it played audio since launch?)", status: -1)
    }
    return .processes(t.appAudio.map { $0.objectID })
}

func verdict(label: String, _ s: LevelStats) -> String {
    switch label {
    case "playing": return s.fractionAboveFloor >= 0.8 ? "pass" : "fail"
    case "paused", "not_playing": return s.fractionAboveFloor <= 0.05 ? "pass" : "fail"
    default: return "n/a (no label)"
    }
}

func testTap(_ a: Args) async throws -> [String: Any] {
    print("\n== tap_brave (route \(a.route), \(a.seconds) s, label \(a.label)) ==")
    let t = try resolveTargets(app: a.app)
    let target = try makeTapTarget(a, t)
    let t0 = nowSeconds()
    let env = Envelope(name: "\(a.app) tap", t0: t0)
    let tap = TapCapture(env: env)
    Cleanup.shared.add(tap)
    do { try tap.start(target) } catch { tap.stop(); throw error }
    await sleepSeconds(a.seconds + 0.3)
    tap.stop()
    let from = 0.3, to = 0.3 + a.seconds - 0.1
    let s = levelStats(env, fromSec: from, toSec: to, floorDb: a.floorDb, startedAt: tap.startedAt)
    let after = try resolveTargets(app: a.app)
    let tapped = Set(t.appAudio.map { $0.objectID })
    let newOnes = after.appAudio.filter { !tapped.contains($0.objectID) }
    let v = verdict(label: a.label, s)
    print("  tap: \(tap.info["tapFormat"] ?? "?"), buffer \(tap.info["bufferFrames"] ?? "?") frames, layout \(env.bufferLayout)")
    print("  windows \(s.windows) (100 ms), with data \(s.windowsWithData), above \(Int(a.floorDb)) dBFS: \(s.windowsAboveFloor) (\(fmt(s.fractionAboveFloor * 100))%)")
    print("  RMS dBFS p10/p50/p90: \(fmt(s.rmsDbfsP10)) / \(fmt(s.rmsDbfsP50)) / \(fmt(s.rmsDbfsP90)); peak \(fmt(s.peakDbfs)) dBFS; all-zero: \(s.allZero)")
    print("  first callback after start: \(fmt(s.firstCallbackAfterStartMs)) ms; delivery delay p50/p90: \(fmt(s.deliveryDelayP50Ms, 2)) / \(fmt(s.deliveryDelayP90Ms, 2)) ms")
    if !newOnes.isEmpty { print("  NOTE: \(newOnes.count) new \(a.app) audio process(es) appeared during the run (not in a PID-list tap)") }
    print("  verdict (\(a.label)): \(v)")
    var r: [String: Any] = [
        "route": a.route, "label": a.label, "seconds": a.seconds, "verdict": v,
        "tappedProcessObjects": t.appAudio.map { jsonObject($0) },
        "tapInfo": tap.info, "inputBufferLayout": env.bufferLayout,
        "stats": jsonObject(s),
        "newAppAudioProcessesDuringRun": newOnes.map { jsonObject($0) },
    ]
    if case .bundleIDs(let b) = target { r["bundleIDs"] = b }
    return r
}

// MARK: pause watch (silence while playback is paused)

/// Taps until Alex pauses playback: needs >= 3 s of audio, then >= `pauseHold` s of windows at the floor.
func testPauseWatch(_ a: Args) async throws -> [String: Any] {
    let hold = 5.0
    print("\n== pause_watch (up to \(a.watchSeconds) s; waiting for playback to pause for \(hold) s) ==")
    let t = try resolveTargets(app: a.app)
    let target = try makeTapTarget(a, t)
    let t0 = nowSeconds()
    let env = Envelope(name: "\(a.app) tap", t0: t0)
    let tap = TapCapture(env: env)
    Cleanup.shared.add(tap)
    do { try tap.start(target) } catch { tap.stop(); throw error }
    var pausedAt: Double? = nil
    var lastAudioEnd = 0.0
    while nowSeconds() - t0 < a.watchSeconds {
        await sleepSeconds(0.5)
        let el = nowSeconds() - t0 - 0.2
        let snap = env.snapshot()
        let w = windowRMS(snap, binsPerWindow: 10, fromBin: 0, toBin: Int(el * 100))
        let loud = w.enumerated().filter { ($0.element.map { db($0) } ?? -200) > a.floorDb }.map { $0.offset }
        guard loud.count >= 30, let last = loud.last else { continue }
        lastAudioEnd = Double(last + 1) * 0.1
        if el - lastAudioEnd >= hold { pausedAt = lastAudioEnd; break }
    }
    tap.stop()
    let end = nowSeconds() - t0 - 0.2
    guard let p = pausedAt else {
        let s = levelStats(env, fromSec: 0.3, toSec: end, floorDb: a.floorDb, startedAt: tap.startedAt)
        print("  no pause detected; whole run above floor \(fmt(s.fractionAboveFloor * 100))%")
        return ["verdict": "no pause detected", "stats": jsonObject(s)]
    }
    let playing = levelStats(env, fromSec: max(0.3, p - 10), toSec: p, floorDb: a.floorDb, startedAt: tap.startedAt)
    let paused = levelStats(env, fromSec: p + 0.3, toSec: end, floorDb: a.floorDb, startedAt: tap.startedAt)
    let v = paused.fractionAboveFloor <= 0.05 ? "pass" : "fail"
    print("  pause detected at \(fmt(p, 1)) s")
    print("  last 10 s before pause: \(fmt(playing.fractionAboveFloor * 100))% above floor, RMS p50 \(fmt(playing.rmsDbfsP50)) dBFS")
    print("  paused segment (\(fmt(end - p - 0.3, 1)) s): \(fmt(paused.fractionAboveFloor * 100))% above floor, RMS p50 \(fmt(paused.rmsDbfsP50)) dBFS, peak \(fmt(paused.peakDbfs)) dBFS, callbacks \(paused.callbacks)")
    print("  verdict (silence while paused): \(v)")
    return ["verdict": v, "pauseDetectedAtSec": round2(p) as Any, "beforePause": jsonObject(playing), "paused": jsonObject(paused)]
}

// MARK: isolation

func testIsolation(_ a: Args) async throws -> [String: Any] {
    print("\n== isolation (\(a.isoSeconds) s, afplay Glass.aiff as the other app) ==")
    let t = try resolveTargets(app: a.app)
    let target = try makeTapTarget(a, t)
    let t0 = nowSeconds()
    let envB = Envelope(name: "\(a.app) tap", t0: t0)
    let envR = Envelope(name: "global tap excluding \(a.app)", t0: t0)
    let tapB = TapCapture(env: envB), tapR = TapCapture(env: envR)
    Cleanup.shared.add(tapB); Cleanup.shared.add(tapR)
    do {
        try tapB.start(target)
        try tapR.start(.globalExcluding(t.appAudio.map { $0.objectID }))
    } catch { tapB.stop(); tapR.stop(); throw error }

    final class Intervals: @unchecked Sendable { let lock = NSLock(); var v: [(Double, Double?)] = [] }
    let iv = Intervals()
    var spawnAt = 1.0
    var procs: [Process] = []
    while spawnAt + 1.8 < a.isoSeconds {
        await sleepSeconds(max(0, spawnAt - (nowSeconds() - t0)))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["/System/Library/Sounds/Glass.aiff"]
        let idx: Int = { iv.lock.lock(); defer { iv.lock.unlock() }; iv.v.append((nowSeconds() - t0, nil)); return iv.v.count - 1 }()
        p.terminationHandler = { _ in iv.lock.lock(); iv.v[idx].1 = nowSeconds() - t0; iv.lock.unlock() }
        Cleanup.shared.add(p)
        try p.run()
        procs.append(p)
        spawnAt += 3.0
    }
    await sleepSeconds(max(0, a.isoSeconds - (nowSeconds() - t0)))
    tapB.stop(); tapR.stop()
    for p in procs where p.isRunning { p.terminate(); p.waitUntilExit() }
    for p in procs { p.waitUntilExit() }
    let intervals: [(Double, Double)] = { iv.lock.lock(); defer { iv.lock.unlock() }; return iv.v.map { ($0.0, $0.1 ?? $0.0 + 1.5) } }()

    let toSec = a.isoSeconds - 0.1
    let sB = levelStats(envB, fromSec: 0, toSec: toSec, floorDb: a.floorDb, startedAt: tapB.startedAt)
    let sR = levelStats(envR, fromSec: 0, toSec: toSec, floorDb: a.floorDb, startedAt: tapR.startedAt)
    func onOff(_ s: LevelStats) -> (on: Double?, off: Double?) {
        var on: [Double] = [], off: [Double] = []
        for (i, w) in s.perWindowRmsDbfs.enumerated() {
            guard let w else { continue }
            let mid = Double(i) * 0.1 + 0.05
            let lin = pow(10, w / 20)
            // Glass decays fast: count the first 0.8 s of each play as "on"; skip the tail.
            if intervals.contains(where: { mid >= $0.0 && mid < $0.0 + 0.8 }) { on.append(lin * lin) }
            else if !intervals.contains(where: { mid >= $0.0 && mid < $0.1 + 0.2 }) { off.append(lin * lin) }
        }
        func m(_ x: [Double]) -> Double? { x.isEmpty ? nil : db((x.reduce(0, +) / Double(x.count)).squareRoot()) }
        return (m(on), m(off))
    }
    let b = onOff(sB), r = onOff(sR)
    let rB = binRMS(envB.snapshot(), fromBin: 0, toBin: Int(toSec * 100))
    let rR = binRMS(envR.snapshot(), fromBin: 0, toBin: Int(toSec * 100))
    let corr = pearson(rB, rR)
    let deltaB = (b.on ?? -200) - (b.off ?? -200), deltaR = (r.on ?? -200) - (r.off ?? -200)
    let controlSaw = deltaR >= 6
    let leaked = deltaB >= 3 || (corr ?? 0) >= 0.3
    let v = !controlSaw ? "inconclusive (control tap did not see afplay)" : (leaked ? "fail (afplay leaks into \(a.app) tap)" : "pass")
    print("  afplay plays: \(intervals.count); intervals (s): " + intervals.map { "\(fmt($0.0, 2))-\(fmt($0.1, 2))" }.joined(separator: ", "))
    print("  \(a.app) tap   RMS during afplay \(fmt(b.on)) dBFS vs outside \(fmt(b.off)) dBFS (delta \(fmt(deltaB)) dB)")
    print("  control tap  RMS during afplay \(fmt(r.on)) dBFS vs outside \(fmt(r.off)) dBFS (delta \(fmt(deltaR)) dB)")
    print("  10 ms envelope correlation \(a.app) tap vs control: \(fmt(corr, 3))")
    print("  verdict: \(v)")
    return [
        "seconds": a.isoSeconds, "verdict": v,
        "afplayIntervalsSec": intervals.map { [($0.0 * 1000).rounded() / 1000, ($0.1 * 1000).rounded() / 1000] },
        "appTapOnDbfs": round2(b.on) as Any, "appTapOffDbfs": round2(b.off) as Any, "appTapDeltaDb": round2(deltaB) as Any,
        "controlTapOnDbfs": round2(r.on) as Any, "controlTapOffDbfs": round2(r.off) as Any, "controlTapDeltaDb": round2(deltaR) as Any,
        "envelopeCorr10ms": round2(corr.map { $0 * 10 }).map { $0 / 10 } as Any,
        "appTapStats": jsonObject(sB), "controlTapStats": jsonObject(sR),
        "appTapInfo": tapB.info, "controlTapInfo": tapR.info,
    ]
}

// MARK: mic bleed

func testMicBleed(_ a: Args) async throws -> [String: Any] {
    print("\n== mic_bleed ==")
    let mic = micAuthorization()
    let tccMic = TCC.preflight("kTCCServiceMicrophone")
    print("  microphone permission: AVCaptureDevice \(mic), TCC preflight \(tccMic)")
    guard mic == "authorized" else {
        print("  skipped: microphone permission not already granted")
        return ["skipped": true, "reason": "microphone permission is \(mic) (TCC \(tccMic)); not requested"]
    }
    let t = try resolveTargets(app: a.app)
    let target = try makeTapTarget(a, t)
    var passes: [[String: Any]] = []
    for vp in [false, true] {
        let t0 = nowSeconds()
        let envT = Envelope(name: "\(a.app) tap", t0: t0)
        let envM = Envelope(name: vp ? "mic (voice processing)" : "mic (raw)", t0: t0)
        let tap = TapCapture(env: envT), m = MicCapture(env: envM)
        Cleanup.shared.add(tap); Cleanup.shared.add(m)
        var micError: String? = nil
        do { try tap.start(target) } catch { tap.stop(); throw error }
        do { try m.start(voiceProcessing: vp) } catch { micError = "\(error)" }
        await sleepSeconds(a.bleedSeconds + 0.3)
        m.stop(); tap.stop()
        let toSec = a.bleedSeconds + 0.2
        let sT = levelStats(envT, fromSec: 0.3, toSec: toSec, floorDb: a.floorDb, startedAt: tap.startedAt)
        let sM = levelStats(envM, fromSec: 0.3, toSec: toSec, floorDb: a.floorDb, startedAt: tap.startedAt)
        let bT = binRMS(envT.snapshot(), fromBin: 30, toBin: Int(toSec * 100))
        let bM = binRMS(envM.snapshot(), fromBin: 30, toBin: Int(toSec * 100))
        var lags: [String: Double] = [:]
        var best: (lag: Int, r: Double)? = nil
        for lag in -5...15 {
            guard let r = laggedPearson(bT, bM, lagBins: lag) else { continue }
            lags["\(lag * 10)"] = (r * 1000).rounded() / 1000
            if (0...8).contains(lag), best == nil || r > best!.r { best = (lag, r) }
        }
        let name = vp ? "voice_processing" : "raw"
        print("  [\(name)] mic \(m.info["format"] ?? "?") VP=\(m.info["voiceProcessing"] ?? "?")\(micError.map { " ERROR \($0)" } ?? "")")
        print("  [\(name)] tap RMS p50 \(fmt(sT.rmsDbfsP50)) dBFS (\(fmt(sT.fractionAboveFloor * 100))% above floor); mic RMS p50 \(fmt(sM.rmsDbfsP50)) dBFS")
        print("  [\(name)] max envelope corr at 0-80 ms lag: \(fmt(best?.r, 3)) at \(best.map { "\($0.lag * 10) ms" } ?? "n/a")")
        passes.append([
            "mode": name, "micInfo": m.info, "micError": micError as Any,
            "maxCorr0to80ms": round2(best.map { $0.r * 10 }).map { $0 / 10 } as Any,
            "bestLagMs": best.map { $0.lag * 10 } as Any,
            "corrByLagMs": lags, "tapStats": jsonObject(sT), "micStats": jsonObject(sM),
        ])
    }
    return ["skipped": false, "outputDevice": defaultOutputDeviceName() as Any, "passes": passes]
}

// MARK: SCK fallback

func testSCK(_ a: Args) async throws -> [String: Any] {
    print("\n== fallback_sck (\(a.seconds) s) ==")
    let pre = CGPreflightScreenCaptureAccess()
    print("  Screen Recording preflight: \(pre)")
    let t0 = nowSeconds()
    let env = Envelope(name: "\(a.app) SCK", t0: t0)
    let c = SCKCapture(env: env)
    let started = nowSeconds()
    do { try await c.start(appName: a.app) } catch {
        print("  SCK start failed: \(error)")
        return ["screenRecordingPreflight": pre, "error": "\(error)"]
    }
    await sleepSeconds(a.seconds + 0.3)
    await c.stop()
    let s = levelStats(env, fromSec: 0.3, toSec: 0.3 + a.seconds - 0.1, floorDb: a.floorDb, startedAt: started)
    let v = verdict(label: a.label, s)
    print("  windows \(s.windows), above floor \(fmt(s.fractionAboveFloor * 100))%, RMS p50 \(fmt(s.rmsDbfsP50)) dBFS, peak \(fmt(s.peakDbfs)); verdict (\(a.label)): \(v)")
    return ["screenRecordingPreflight": pre, "label": a.label, "verdict": v, "info": c.info,
            "stopError": c.stopError as Any, "stats": jsonObject(s)]
}

// MARK: main

@main
struct TapProbeMain {
    static func main() async {
        installSignalHandlers()
        let a = Args.parse()
        var audioPerm = TCC.preflight("kTCCServiceAudioCapture")
        let responsible = responsibleAppGuess()
        print("TapProbe  app=\(a.app)  tests=\(a.tests.joined(separator: ","))  label=\(a.label)")
        print("Permissions: system-audio capture (TCC preflight) \(audioPerm); microphone \(micAuthorization()); responsible app (guess) \(responsible)")
        print("Default output device: \(defaultOutputDeviceName() ?? "?")")
        var requestResult: String? = nil
        if a.requestPermission > 0 && audioPerm != "granted" {
            print("Requesting system-audio capture permission (waiting up to \(Int(a.requestPermission)) s for the dialog)...")
            requestResult = TCC.request("kTCCServiceAudioCapture", timeout: a.requestPermission)
            audioPerm = TCC.preflight("kTCCServiceAudioCapture")
            print("  request result: \(requestResult!); preflight now \(audioPerm)")
        }
        var tests: [String: Any] = [:]
        let runs: [(String, String)] = [("list", "list_targets"), ("tap", "tap_brave"), ("isolation", "isolation"),
                                        ("mic_bleed", "mic_bleed"), ("pause_watch", "pause_watch"),
                                        ("sck", "fallback_sck")]
        for (key, name) in runs where a.tests.contains(key) {
            do {
                switch key {
                case "list": tests[name] = try testList(a)
                case "tap": tests[name] = try await testTap(a)
                case "isolation": tests[name] = try await testIsolation(a)
                case "mic_bleed": tests[name] = try await testMicBleed(a)
                case "pause_watch": tests[name] = try await testPauseWatch(a)
                case "sck": tests[name] = try await testSCK(a)
                default: break
                }
            } catch {
                print("  \(name) ERROR: \(error)")
                tests[name] = ["error": "\(error)"]
            }
            Cleanup.shared.run()
        }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let ts = df.string(from: Date())
        let iso = ISO8601DateFormatter().string(from: Date())
        let out: [String: Any] = [
            "tool": "TapProbe", "timestamp": iso,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "args": ["app": a.app, "seconds": a.seconds, "tests": a.tests, "label": a.label, "route": a.route,
                     "floorDb": a.floorDb, "withSubDevice": TapCapture.defaultWithSubDevice, "isoSeconds": a.isoSeconds, "bleedSeconds": a.bleedSeconds],
            "permissions": ["audioCaptureTCC": audioPerm, "audioCaptureRequest": requestResult as Any,
                            "microphone": micAuthorization(), "screenRecordingPreflight": CGPreflightScreenCaptureAccess()],
            "responsibleAppGuess": responsible,
            "defaultOutputDevice": defaultOutputDeviceName() as Any,
            "note": "numbers only; no audio was written",
            "tests": tests,
        ]
        do {
            try FileManager.default.createDirectory(atPath: a.outDir, withIntermediateDirectories: true)
            let path = "\(a.outDir)/audio-\(ts).json"
            let d = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try d.write(to: URL(fileURLWithPath: path))
            print("\nWrote \(path)")
        } catch { print("could not write results: \(error)") }
        Cleanup.shared.run()
    }
}
