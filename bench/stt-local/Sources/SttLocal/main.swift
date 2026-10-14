import Foundation

// SttLocal: Verse local-STT bench. CLI only. Same corpus, voices, real-time feed and metric code as bench/speech.
let args = CommandLine.arguments
func flag(_ n: String) -> Bool { args.contains(n) }
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

guard let engineName = opt("--engine") else {
    print("usage: SttLocal --engine apple|nemotron|moonshine [--tag cold|warm] [--questions N] [--moon-interval 0.5] [--voices en,en-samantha]")
    exit(2)
}
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)         // run from bench/stt-local
let modelsRoot = root.deletingLastPathComponent().appendingPathComponent("stt-models")
let tag = opt("--tag") ?? "run"
let count = Int(opt("--questions") ?? "") ?? 20
let voiceKeys = (opt("--voices") ?? "en,en-samantha").split(separator: ",").map(String.init)
let langs = ([Corpus.en, Corpus.enControl]).filter { voiceKeys.contains($0.key) }

let engine: Engine
switch engineName {
case "apple": engine = AppleEngine()
case "nemotron": engine = NemotronEngine(modelDir: modelsRoot.appendingPathComponent("nemotron/nemotron_coreml_560ms"))
case "moonshine":
    engine = MoonshineEngine(python: root.appendingPathComponent(".venv/bin/python"),
                             worker: root.appendingPathComponent("moonshine_worker.py"),
                             modelDir: modelsRoot.appendingPathComponent("moonshine/download.moonshine.ai/model/medium-streaming-en/quantized_26_08_21"),
                             interval: Double(opt("--moon-interval") ?? "") ?? 0.5)
default: print("unknown engine"); exit(2)
}

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")

// 1. Synthesize into temp fixtures, load into memory, delete the files immediately.
let fixDir = root.appendingPathComponent("fixtures/run-\(stamp)")
var fixtures = FixtureRecord(directory: fixDir.path, filesCreated: 0, filesDeleted: 0, directoryAbsentAfterDelete: false, deletedAt: "")
var timelines: [String: Timeline] = [:]
do {
    try fm.createDirectory(at: fixDir, withIntermediateDirectories: true)
    for l in langs {
        logErr("SYNTH \(l.key) (\(count) questions)")
        let (tl, files) = try Synth.buildTimeline(lang: l, count: count, dir: fixDir)
        timelines[l.key] = tl
        fixtures.filesCreated += files.count
    }
} catch { logErr("synthesis failed: \(error)") }
if let items = try? fm.contentsOfDirectory(atPath: fixDir.path) { fixtures.filesDeleted = items.count }
try? fm.removeItem(at: fixDir)
fixtures.directoryAbsentAfterDelete = !fm.fileExists(atPath: fixDir.path)
fixtures.deletedAt = isoNow()
logErr("FIXTURES deleted: \(fixtures.filesDeleted)/\(fixtures.filesCreated), dir absent: \(fixtures.directoryAbsentAfterDelete)")
guard timelines.count == langs.count else { exit(1) }

var report = EngineReport(engine: engine.name, variant: engine.variant, tag: tag, generatedAt: isoNow(),
                          host: ProcessInfo.processInfo.operatingSystemVersionString, chunkMs: Session.chunkMs,
                          leadSilenceSec: Timeline.leadSilence, gapSilenceSec: Timeline.gapSilence, tailSilenceSec: Timeline.tailSilence,
                          runs: [], fixtures: fixtures,
                          notes: [])

// 2. Load, then run each timeline in real time.
var loadSec: Double?
do {
    let clk = ContinuousClock()
    let t = clk.now
    loadSec = try await engine.load()
    logErr("LOAD \(engine.name): \(loadSec.map { String(format: "%.2f s", $0) } ?? "per run") (wall \(String(format: "%.2f", secs(clk.now - t))) s)")
} catch {
    logErr("LOAD FAILED: \(error)")
    report.runs.append(LangRun(lang: "-", voice: "-", engine: engine.name, status: "failed", error: "load: \(error)", loadSec: nil, streamSec: nil, feedEndSec: nil,
                               feederLateP50Ms: nil, feederLateMaxMs: nil, chunks: nil, cpuSec: nil, cpuPct: nil, computeSec: nil, rtf: nil, peakRssMB: nil,
                               extra: nil, summary: nil, questions: nil, utterances: nil, events: nil))
}
if report.runs.isEmpty {
    for l in langs {
        let tl = timelines[l.key]!
        logErr("RUN \(engine.name) \(l.key) (\(Int(tl.durationSec)) s real time)")
        do {
            let out = try await engine.run(lang: l, timeline: tl)
            let wins = Analyze.windows(tl.utterances)
            var qs: [QuestionMetrics] = []
            for (i, u) in tl.utterances.enumerated() {
                qs.append(Analyze.questionMetrics(utt: u, window: wins[i], events: out.events, localeID: l.localeID, feedEnd: out.feedEndSec))
            }
            let sum = Analyze.summarize(qs, wer: Analyze.globalWER(events: out.events, utts: tl.utterances, localeID: l.localeID))
            let cpuPct = out.feedEndSec > 0 ? out.cpuSec / out.feedEndSec * 100 : nil
            let rtf = out.computeSec.map { $0 / tl.durationSec }
            report.runs.append(LangRun(lang: l.key, voice: l.voices.joined(separator: "+"), engine: engine.name, status: "ok", error: nil,
                                       loadSec: loadSec ?? out.loadSec, streamSec: tl.durationSec, feedEndSec: out.feedEndSec,
                                       feederLateP50Ms: out.feederLateP50Ms, feederLateMaxMs: out.feederLateMaxMs, chunks: out.chunks,
                                       cpuSec: out.cpuSec, cpuPct: cpuPct, computeSec: out.computeSec, rtf: rtf, peakRssMB: out.peakRssMB,
                                       extra: out.extra, summary: sum, questions: qs, utterances: tl.utterances, events: out.events))
            logErr(String(format: "  %@: last-word %@ ms, final %@ ms, WER %.1f%%, CPU %.0f%%, RTF %@, peak RSS %.0f MB",
                          l.key, pair(sum.lastWordLagLoose), pair(sum.finalLag), sum.wer * 100, cpuPct ?? 0,
                          rtf.map { String(format: "%.3f", $0) } ?? "n/a", out.peakRssMB))
        } catch {
            logErr("  FAILED: \(error)")
            report.runs.append(LangRun(lang: l.key, voice: l.voices.joined(separator: "+"), engine: engine.name, status: "failed", error: "\(error)", loadSec: loadSec,
                                       streamSec: nil, feedEndSec: nil, feederLateP50Ms: nil, feederLateMaxMs: nil, chunks: nil, cpuSec: nil, cpuPct: nil, computeSec: nil,
                                       rtf: nil, peakRssMB: nil, extra: nil, summary: nil, questions: nil, utterances: nil, events: nil))
        }
    }
}
await engine.shutdown()

try? fm.createDirectory(at: root.appendingPathComponent("results"), withIntermediateDirectories: true)
let outURL = root.appendingPathComponent("results/\(engine.name)-\(tag)-\(stamp).json")
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
do { try enc.encode(report).write(to: outURL); print("wrote \(outURL.path)") } catch { logErr("write failed: \(error)") }
exit(report.runs.contains { $0.status != "ok" } ? 1 : 0)
