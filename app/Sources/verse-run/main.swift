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
    usage: verse-run --session DIR --lang en|it|tr [--seconds N] [--file PATH] [options]
      --session DIR       a P1-1 session folder (pack.md, bank.jsonl, facts.jsonl, glossary.jsonl)
      --lang L            meeting language (default en)
      --seconds N         stop listening after N s (live default 60; a file plays to its end)
      --file PATH         play an audio file as the remote channel instead of listening live
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
      --brain-dir DIR     the brain/ folder (default: found next to the repo, or VERSE_BRAIN_DIR)
      --fake-brain        brain with canned replies (no network, no key)
      --budget-usd N      optional spend cap passed to the brain (default: none)
    """)
    exit(2)
}

func parse(_ args: [String]) -> RunOptions {
    var session: String?
    var o: RunOptions?
    var lang = "en", seconds: Double?, file: String?, mic = true
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
        case "--no-mic": mic = false
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
    guard ["en", "it", "tr"].contains(lang) else { stderr("verse-run: --lang must be en, it or tr"); usage() }
    var opts = RunOptions(sessionDir: URL(fileURLWithPath: (session as NSString).expandingTildeInPath))
    opts.lang = lang
    opts.seconds = seconds
    opts.file = file.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    opts.micEnabled = mic
    if let bundles { opts.bundleIDs = bundles }
    opts.brainDir = brainDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    opts.fakeBrain = fake
    opts.budgetUSD = budget
    opts.turn = turn
    if let drain { opts.drainSeconds = drain }
    opts.format = format
    opts.echoOutbound = echo
    opts.trace = trace
    o = opts
    return o!
}

signal(SIGPIPE, SIG_IGN)
let options = parse(CommandLine.arguments)
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
exit(code)

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
