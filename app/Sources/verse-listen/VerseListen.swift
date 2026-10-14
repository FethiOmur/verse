@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation
import VerseSpeech

// verse-listen: prints TranscriptEvents as JSON lines on stdout; status and issues go to stderr as JSON lines.
// No window, no audio written.

struct Options {
    var lang = "en"
    var seconds: Double = 30
    var file: String?
    var mic = true
    var bundleIDs = defaultRemoteBundleIDs
    var route = TapRoutePreference.auto
    var voiceProcessing = false
    var list = false
    var emitToneSeconds: Double?
    var probeDucking = false
    var levels = false
    var playTestFile: String?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        func value(_ k: String) -> String {
            guard let v = it.next() else { fail("missing value for \(k)") }
            return v
        }
        while let k = it.next() {
            switch k {
            case "--lang": o.lang = value(k)
            case "--seconds": o.seconds = Double(value(k)) ?? o.seconds
            case "--file": o.file = value(k)
            case "--no-mic": o.mic = false
            case "--bundle-ids": o.bundleIDs = value(k).split(separator: ",").map(String.init)
            case "--route":
                switch value(k) {
                case "auto": o.route = .auto
                case "bundle": o.route = .bundleID
                case "pids": o.route = .pidList
                default: fail("--route must be auto, bundle or pids")
                }
            case "--voice-processing": o.voiceProcessing = true
            case "--list": o.list = true
            case "--emit-test-tone": o.emitToneSeconds = Double(value(k)) ?? 5
            case "--probe-ducking": o.probeDucking = true
            case "--levels": o.levels = true
            case "--play-test-file": o.playTestFile = value(k)
            case "-h", "--help":
                print("""
                verse-listen --lang en|it|tr [--seconds 30] [--file PATH] [--no-mic] [--bundle-ids a,b]
                             [--route auto|bundle|pids] [--voice-processing] [--levels]
                --levels: once per second, per-channel RMS dBFS and chunk counts on stderr (numbers only)
                verse-listen --list                 audio processes known to Core Audio
                verse-listen --probe-ducking        measures how much voice processing ducks other audio
                stdout: one TranscriptEvent JSON object per line. stderr: status/issue JSON lines.
                """)
                exit(0)
            default: fail("unknown argument \(k) (see --help)")
            }
        }
        if !["en", "it", "tr"].contains(o.lang) { fail("--lang must be en, it or tr") }
        if o.file != nil { o.mic = false }
        return o
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("verse-listen: " + msg + "\n").utf8))
    exit(2)
}

func status(_ fields: [String: Any]) {
    var f = fields
    if f["type"] == nil { f["type"] = "status" }
    if let d = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) {
        FileHandle.standardError.write(d + Data("\n".utf8))
    }
}

func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

@main
struct VerseListen {
    static func main() async {
        let o = Options.parse(CommandLine.arguments)
        if let s = o.emitToneSeconds { emitTone(seconds: s); return }
        if o.list { listProcesses(); return }
        if o.probeDucking { await DuckingProbe.run(); return }
        if let f = o.playTestFile { playTestFile(f); return }

        var config = ListenConfig(lang: o.lang, remoteBundleIDs: o.bundleIDs, micEnabled: o.mic,
                                  source: o.file.map { .file(URL(fileURLWithPath: $0)) } ?? .live)
        config.tapRoute = o.route
        config.voiceProcessing = o.voiceProcessing
        let session = ListenSession(config: config)

        if config.isLiveSource {
            let p = SystemPermissions()
            var mic = p.status(.microphone)
            status(["permissions": ["audioCapture": p.status(.audioCapture).rawValue, "microphone": mic.rawValue],
                    "outputDevice": defaultOutputName() ?? "?", "inputDevice": defaultInputName() ?? "?"])
            if o.mic {
                if mic == .notDetermined {
                    status(["state": "requesting_microphone",
                            "message": "macOS will ask for microphone access for the app running verse-listen (e.g. Terminal); click Allow"])
                    mic = await p.request(.microphone)
                    status(["permissions": ["microphone": mic.rawValue], "state": "microphone_answered"])
                }
                if mic != .granted {
                    status(["type": "issue", "code": "permission_denied",
                            "message": "microphone access is \(mic.rawValue): System Settings > Privacy & Security > Microphone, enable the app running verse-listen, or pass --no-mic"])
                    exit(3)
                }
            }
        }

        let stream: AsyncStream<TranscriptEvent>
        do {
            stream = try await session.start()
        } catch let e as ListenError {
            status(["type": "issue", "code": e.code, "message": e.description])
            exit(e.code == "permission_denied" ? 3 : 1)
        } catch {
            status(["type": "issue", "code": "error", "message": "\(error)"])
            exit(1)
        }
        let routes = await session.routes()
        let engines = await session.engineNames()
        status(["state": "listening", "lang": o.lang,
                "routes": Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) }),
                "engines": Dictionary(uniqueKeysWithValues: engines.map { ($0.key.rawValue, $0.value) })])

        let issueTask = Task {
            for await issue in session.issues {
                var hint = ""
                if issue == .deadStream(.me) { hint = " (microphone delivers no audio: check the input device and microphone permission)" }
                if issue == .deadStream(.remote) { hint = " (the meeting app is playing but the tap gets silence: check System Audio Recording permission)" }
                status(["type": "issue", "code": issue.code, "message": issue.description + hint])
            }
        }
        let levelsTask: Task<Void, Never>? = o.levels ? Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let lv = await session.levels(window: 1.0)
                var f: [String: Any] = ["type": "levels", "t": r3(await session.now())]
                for (c, l) in lv {
                    f[c.rawValue] = ["rmsDbfs": l.rmsDbfs.map { $0 as Any } ?? NSNull(), "peakDbfs": l.peakBinDbfs.map { $0 as Any } ?? NSNull(), "chunks": l.chunksTotal] as [String: Any]
                }
                status(f)
            }
        } : nil
        let signals = installSignalHandlers { Task { await session.stop() } }
        let timer = Task {
            try? await Task.sleep(for: .seconds(o.seconds))
            await session.stop()
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var count = 0
        for await var e in stream {
            e.audioStart = r3(e.audioStart); e.audioEnd = r3(e.audioEnd); e.emittedAt = r3(e.emittedAt)
            if let d = try? enc.encode(e) {
                FileHandle.standardOutput.write(d + Data("\n".utf8))
                count += 1
            }
        }
        timer.cancel()
        await session.stop()
        issueTask.cancel()
        levelsTask?.cancel()
        _ = signals
        status(["state": "stopped", "events": count, "droppedEchoEvents": session.droppedEchoEvents])
    }
}

extension ListenConfig {
    var isLiveSource: Bool { if case .live = source { return true } else { return false } }
}

func installSignalHandlers(_ onSignal: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { onSignal() }
        s.resume()
        return s
    }
}

func defaultOutputName() -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return nil }
    var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &na, 0, nil, &ns, &name) == noErr, let n = name else { return nil }
    return n.takeRetainedValue() as String
}

func defaultInputName() -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return nil }
    var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &na, 0, nil, &ns, &name) == noErr, let n = name else { return nil }
    return n.takeRetainedValue() as String
}

/// Diagnostic for the tap-path test: plays an audio file (a `say` fixture the test made and deletes) through the
/// default output from memory, then exits. Gives the test a process with a known bundle ID that speaks known text.
func playTestFile(_ path: String) {
    let clip: PCMClip
    do { clip = try PCMClip.read(URL(fileURLWithPath: path)) } catch { fail("play: \(error)") }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(clip.samples.count)) else { fail("play: format") }
    buf.frameLength = AVAudioFrameCount(clip.samples.count)
    clip.samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: fmt)
    do { try engine.start() } catch { fail("play: \(error)") }
    player.scheduleBuffer(buf, at: nil)
    player.play()
    Thread.sleep(forTimeInterval: clip.duration + 0.3)
    engine.stop()
}

func listProcesses() {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    for p in AudioProcesses.list() {
        if let d = try? enc.encode(p) { FileHandle.standardOutput.write(d + Data("\n".utf8)) }
    }
}

/// Plays a quiet 440 Hz tone generated in memory (amplitude 0.002, about -54 dBFS) for `seconds`.
/// Diagnostic: gives tests and the ducking probe a process with a known bundle ID (dev.verse.listen) to tap.
func emitTone(seconds: Double, amplitude: Float = 0.002) {
    let engine = AVAudioEngine()
    let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
    nonisolated(unsafe) var phase = 0.0
    let step = 2 * Double.pi * 440 / sr
    let node = AVAudioSourceNode { _, _, frameCount, abl -> OSStatus in
        let l = UnsafeMutableAudioBufferListPointer(abl)
        for f in 0..<Int(frameCount) {
            let v = amplitude * Float(sin(phase))
            phase += step
            for b in l { b.mData!.assumingMemoryBound(to: Float.self)[f] = v }
        }
        return noErr
    }
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: mono)
    do { try engine.start() } catch { fail("tone: \(error)") }
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
}
