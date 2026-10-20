import Darwin
import Foundation
import VerseSpeech
import VerseTurns

// verse-run: the headless end-to-end run. Listens (remote audio + mic, or a file), finds questions, talks to the
// Python brain and prints what the brain suggests as JSON lines on stdout. No window, no audio written; the API key
// stays in the brain (Keychain). Logs and problems go to stderr.

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func usage() -> Never {
    stderr("""
    usage: verse-run --session DIR --lang auto|en|it|tr [--seconds N] [--file PATH] [options]
      --session DIR       a P1-1 session folder (pack.md, bank.jsonl, facts.jsonl, glossary.jsonl)
      --lang L            meeting language (default en); auto starts in en and follows the spoken language (en, it, tr)
      --seconds N         stop listening after N s (live default 60; a file plays to its end)
      --file PATH         play an audio file as the remote channel instead of listening live
      --me-file PATH      play an audio file as the "me" channel (the microphone) next to --file, both at real-time
                          pace from the same start; the owner's speech must land as "me" turns
      --no-bleed-gate     switch the envelope echo gate of the "me" channel off (bleed measurements)
      --gate-corr-only    envelope gate by correlation alone, as before the level rule (the "before" arm of the gate-fix measurements)
      --no-echo-guard     switch the text echo guard of the turn engine off (bleed measurements)
      --me-hold-ms N      longest a me result that may be speaker bleed keeps the open remote turn open (default 1200; 0 = close it at
                          once, the "before" arm of the me-turn-split measurements)
      --no-mic            live: remote audio only
      --bundle-ids a,b    apps whose audio is the remote channel (default Brave, Comet, Zoom, Teams)
      --owner NAME        your name for the addressee check (default Alex); --alias a,b adds spellings the
                          recognizer produces; --others a,b names other participants
      --cue-ms N          endpoint wait after a finished question (default 300)
      --plain-ms N        endpoint wait otherwise (default 600)
      --format json|text  JSON lines (default) or short readable lines
      --echo              also print the partial/turn/bank_hit lines sent to the brain
      --trace             log every transcript event and the remote audio level to stderr
      --drain N           wait at most N s for the brain after the audio ends (default 15)
      --follow            "follow my answer": send follow:true in start and the me partials (default off, as the brain's)
      --brain-dir DIR     the brain/ folder (default: found next to the repo, or VERSE_BRAIN_DIR)
      --fake-brain        brain with canned replies (no network, no key)
      --budget-usd N      optional spend cap passed to the brain (default: none)
    """)
    exit(2)
}

func parse(_ args: [String]) -> RunOptions {
    var session: String?
    var o: RunOptions?
    var lang = "en", seconds: Double?, file: String?, meFile: String?, noBleedGate = false, gateCorrOnly = false, noEchoGuard = false, mic = true, follow = false
    var bundles: [String]?, brainDir: String?, fake = false, budget: Double?
    var turn = TurnConfig()
    var drain: Double?, format = OutputFormat.json, echo = false, trace = false
    var it = args.dropFirst().makeIterator()
    func value(_ k: String) -> String {
        guard let v = it.next() else { stderr("verse-run: missing value for \(k)"); usage() }
        return v
    }
    func list(_ s: String) -> [String] { s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    while let k = it.next() {
        switch k {
        case "--session": session = value(k)
        case "--lang": lang = value(k)
        case "--seconds": seconds = Double(value(k))
        case "--file": file = value(k)
        case "--me-file": meFile = value(k)
        case "--no-bleed-gate": noBleedGate = true
        case "--gate-corr-only": gateCorrOnly = true
        case "--no-echo-guard": noEchoGuard = true
        case "--me-hold-ms": turn.meCloseHoldMs = Int(value(k)) ?? turn.meCloseHoldMs
        case "--no-mic": mic = false
        case "--follow": follow = true
        case "--bundle-ids": bundles = list(value(k))
        case "--owner": turn.ownerName = value(k)
        case "--alias": turn.ownerAliases = list(value(k))
        case "--others": turn.otherNames = list(value(k))
        case "--cue-ms": turn.cueEndpointMs = Int(value(k)) ?? turn.cueEndpointMs
        case "--plain-ms": turn.plainEndpointMs = Int(value(k)) ?? turn.plainEndpointMs
        case "--format":
            guard let f = OutputFormat(rawValue: value(k)) else { stderr("verse-run: --format must be json or text"); usage() }
            format = f
        case "--echo": echo = true
        case "--trace": trace = true
        case "--drain": drain = Double(value(k))
        case "--brain-dir": brainDir = value(k)
        case "--fake-brain": fake = true
        case "--budget-usd": budget = Double(value(k))
        case "-h", "--help": usage()
        default: stderr("verse-run: unknown argument \(k)"); usage()
        }
    }
    guard let session else { stderr("verse-run: --session is required"); usage() }
    guard ["auto", "en", "it", "tr"].contains(lang) else { stderr("verse-run: --lang must be auto, en, it or tr"); usage() }
    var opts = RunOptions(sessionDir: URL(fileURLWithPath: (session as NSString).expandingTildeInPath))
    opts.lang = lang == "auto" ? "en" : lang
    opts.autoLanguage = lang == "auto"
    opts.seconds = seconds
    opts.file = file.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    opts.micEnabled = mic
    if noBleedGate { opts.bleedGate.threshold = 2.0 }   // a Pearson correlation never reaches it
    if gateCorrOnly { opts.bleedGate.maxEchoRatioDb = .infinity }   // the gate as it was before the level rule: correlation alone drops
    if let meFile {
        func clip(_ path: String) -> PCMClip {
            do { return try PCMClip.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) } catch {
                stderr("verse-run: \(error)"); exit(2)
            }
        }
        opts.source = .memory(remote: file.map(clip), me: clip(meFile))
    }
    if let bundles { opts.bundleIDs = bundles }
    opts.brainDir = brainDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    opts.fakeBrain = fake
    opts.budgetUSD = budget
    opts.turn = turn
    if noEchoGuard { opts.turn.echoGuardEnabled = false }
    opts.follow = follow
    if let drain { opts.drainSeconds = drain }
    opts.format = format
    opts.echoOutbound = echo
    opts.trace = trace
    o = opts
    return o!
}

signal(SIGPIPE, SIG_IGN)
let options = parse(CommandLine.arguments)
// Once, off the main thread, before any model load: removes compile bundles that killed runs left in the Core ML cache.
E5BundleCacheCleaner.startOnce { stderr("verse-run: " + $0) }
let runner = VerseRunner(options: options, log: { stderr("verse-run: " + $0) })

// SIGINT / SIGTERM / SIGHUP: stop listening, then the run shuts the brain down. A second signal, or a run that does
// not end within 6 s, kills the brain outright.
let signalCount = LockedCounter()
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        let n = signalCount.increment()
        stderr("verse-run: stopping (signal \(sig))")
        if n == 1 {
            runner.requestStop()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                BrainProcess.killAll()
                exit(130)
            }
        } else {
            BrainProcess.killAll()
            exit(130)
        }
    }
    src.resume()
    signalSources.append(src)
}

let code = await runner.run()
BrainProcess.killAll()   // no-op when the run shut the brain down itself
// Core ML renames its `.tmp.<pid>_` compile bundle to the final name only when the model is released; exit() with the
// pooled models alive left one 100 MB tmp bundle per run (measured: 125 s replay, 0 committed; with this line, 4 committed, 0 tmp).
await NemotronModel.unloadIdle()
exit(code)

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
