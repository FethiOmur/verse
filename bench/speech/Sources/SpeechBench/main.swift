import Foundation
import Speech

// SpeechBench: Verse P0-B. CLI only. Synthetic `say` audio, real-time feed, numbers only.
let args = CommandLine.arguments
func flag(_ n: String) -> Bool { args.contains(n) }
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func localeStatuses() async -> [LocaleStatus] {
    let sup = await SpeechTranscriber.supportedLocales.map { $0.identifier }
    let ins = await SpeechTranscriber.installedLocales.map { $0.identifier }
    let dsup = await DictationTranscriber.supportedLocales.map { $0.identifier }
    let dins = await DictationTranscriber.installedLocales.map { $0.identifier }
    var out: [LocaleStatus] = []
    for l in Corpus.all {
        let loc = Locale(identifier: l.localeID)
        let eq = await SpeechTranscriber.supportedLocale(equivalentTo: loc)?.identifier
        let deq = await DictationTranscriber.supportedLocale(equivalentTo: loc)?.identifier
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let st = await AssetInventory.status(forModules: [t])
        let cls: String
        if ins.contains(l.localeID) { cls = "available (SpeechTranscriber model installed)" }
        else if sup.contains(l.localeID) { cls = "downloadable (SpeechTranscriber supported, not installed)" }
        else if dins.contains(l.localeID) { cls = "absent from SpeechTranscriber; DictationTranscriber model installed" }
        else if dsup.contains(l.localeID) { cls = "absent from SpeechTranscriber; DictationTranscriber downloadable" }
        else { cls = "absent" }
        out.append(LocaleStatus(locale: l.localeID,
                                speechTranscriberSupported: sup.contains(l.localeID), speechTranscriberInstalled: ins.contains(l.localeID),
                                speechTranscriberEquivalent: eq, speechTranscriberAssetStatus: String(describing: st),
                                dictationTranscriberSupported: dsup.contains(l.localeID), dictationTranscriberInstalled: dins.contains(l.localeID),
                                dictationTranscriberEquivalent: deq, classification: cls))
    }
    return out
}

func runOne(lang: LangSpec, timeline: Timeline, kind: ModuleKind, timeoutSec: Double) async -> RunReport {
    log("RUN \(lang.key) \(kind.name) (\(Int(timeline.durationSec)) s real time)")
    do {
        let out = try await withThrowingTaskGroup(of: SessionOutput.self) { group in
            group.addTask { try await Session.run(lang: lang, timeline: timeline, kind: kind) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSec))
                throw Synth.Failure(description: "timeout after \(Int(timeoutSec)) s with no completion")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let wins = Analyze.windows(timeline.utterances)
        var qs: [QuestionMetrics] = []
        for (i, u) in timeline.utterances.enumerated() {
            qs.append(Analyze.questionMetrics(utt: u, window: wins[i], events: out.events, localeID: lang.localeID, feedEnd: out.feedEndSec))
        }
        let sum = Analyze.summarize(qs, wer: Analyze.globalWER(events: out.events, utts: timeline.utterances, localeID: lang.localeID))
        return RunReport(lang: lang.key, locale: lang.localeID, module: kind.name, status: "ok", error: nil,
                         audioFormat: out.audioFormat, prepareSec: out.prepareSec, streamSec: out.feedEndSec,
                         feederLateP50Ms: out.feederLateP50Ms, feederLateMaxMs: out.feederLateMaxMs,
                         eventCount: out.events.count, volatileEventCount: out.events.filter { !$0.isFinal }.count,
                         finalEventCount: out.events.filter { $0.isFinal }.count,
                         summary: sum, questions: qs, utterances: timeline.utterances, events: out.events)
    } catch {
        log("  FAILED: \(error)")
        return RunReport(lang: lang.key, locale: lang.localeID, module: kind.name, status: "failed", error: "\(error)",
                         audioFormat: nil, prepareSec: nil, streamSec: nil, feederLateP50Ms: nil, feederLateMaxMs: nil,
                         eventCount: nil, volatileEventCount: nil, finalEventCount: nil, summary: nil, questions: nil, utterances: nil, events: nil)
    }
}

struct StoredRun: Decodable {
    let lang, locale, module, status: String
    let error: String?
    let audioFormat: String?
    let prepareSec, streamSec, feederLateP50Ms, feederLateMaxMs: Double?
    let eventCount, volatileEventCount, finalEventCount: Int?
    let utterances: [Utterance]?
    let events: [Event]?
}
struct StoredReport: Decodable {
    let generatedAt, host: String
    let chunkMs: Int
    let leadSilenceSec, gapSilenceSec, tailSilenceSec: Double
    let locales: [LocaleStatus]
    let runs: [StoredRun]
    let fixtures: FixtureRecord?
}

/// Recomputes metrics from the stored raw events of a previous run (same code path as a live run), writing a new JSON.
func reanalyze(_ path: String) -> Int32 {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let stored = try JSONDecoder().decode(StoredReport.self, from: data)
        var rep = Report(generatedAt: stored.generatedAt, host: stored.host, chunkMs: stored.chunkMs, leadSilenceSec: stored.leadSilenceSec,
                         gapSilenceSec: stored.gapSilenceSec, tailSilenceSec: stored.tailSilenceSec, locales: stored.locales, runs: [], fixtures: stored.fixtures)
        var newRuns: [RunReport] = []
        for r in stored.runs {
            guard r.status == "ok", let events = r.events, let utts = r.utterances else {
                newRuns.append(RunReport(lang: r.lang, locale: r.locale, module: r.module, status: r.status, error: r.error, audioFormat: nil, prepareSec: nil,
                                         streamSec: nil, feederLateP50Ms: nil, feederLateMaxMs: nil, eventCount: nil, volatileEventCount: nil, finalEventCount: nil,
                                         summary: nil, questions: nil, utterances: nil, events: nil))
                continue
            }
            let wins = Analyze.windows(utts)
            let feedEnd = r.streamSec ?? 0
            var qs: [QuestionMetrics] = []
            for (i, u) in utts.enumerated() {
                qs.append(Analyze.questionMetrics(utt: u, window: wins[i], events: events, localeID: r.locale, feedEnd: feedEnd))
            }
            let sum = Analyze.summarize(qs, wer: Analyze.globalWER(events: events, utts: utts, localeID: r.locale))
            newRuns.append(RunReport(lang: r.lang, locale: r.locale, module: r.module, status: r.status, error: r.error, audioFormat: r.audioFormat,
                                     prepareSec: r.prepareSec, streamSec: r.streamSec, feederLateP50Ms: r.feederLateP50Ms, feederLateMaxMs: r.feederLateMaxMs,
                                     eventCount: r.eventCount, volatileEventCount: r.volatileEventCount, finalEventCount: r.finalEventCount,
                                     summary: sum, questions: qs, utterances: utts, events: events))
        }
        rep.runs = newRuns
        let out = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("reanalyzed.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rep).write(to: out)
        print("wrote \(out.path)\n\n" + renderTable(rep.runs))
        print("\n--- markdown ---\n" + renderMarkdownTable(rep.runs) + "\n" + renderStrictMarkdown(rep.runs))
        return 0
    } catch {
        log("reanalyze failed: \(error)")
        return 1
    }
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

func main() async -> Int32 {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    guard flag("--all") || flag("--locales") || opt("--lang") != nil || opt("--reanalyze") != nil else {
        print("usage: SpeechBench --all | --locales | --lang en|it|tr [--questions N] [--fast-only]")
        return 2
    }
    if let path = opt("--reanalyze") { return reanalyze(path) }
    let locales = await localeStatuses()
    for l in locales {
        print("locale \(l.locale): \(l.classification); SpeechTranscriber equivalentTo=\(l.speechTranscriberEquivalent ?? "nil"), AssetInventory.status=\(l.speechTranscriberAssetStatus); Dictation supported=\(l.dictationTranscriberSupported) installed=\(l.dictationTranscriberInstalled)")
    }
    if flag("--locales") && !flag("--all") { return 0 }

    let count = Int(opt("--questions") ?? "") ?? 20
    let langs = (Corpus.all + [Corpus.enControl]).filter { opt("--lang") == nil ? ($0.key != "en-samantha" || flag("--all")) : $0.key == opt("--lang") }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let fixDir = root.appendingPathComponent("fixtures/run-\(stamp)")
    var fixtures = FixtureRecord(directory: fixDir.path, filesCreated: 0, filesDeleted: 0, directoryAbsentAfterDelete: false, deletedAt: "")
    var report = Report(generatedAt: isoNow(), host: ProcessInfo.processInfo.operatingSystemVersionString,
                        chunkMs: Session.chunkMs, leadSilenceSec: Timeline.leadSilence, gapSilenceSec: Timeline.gapSilence,
                        tailSilenceSec: Timeline.tailSilence, locales: locales, runs: [], fixtures: nil)

    // 1. Synthesize into temp fixtures, load into memory, delete the files immediately.
    var timelines: [String: Timeline] = [:]
    do {
        try fm.createDirectory(at: fixDir, withIntermediateDirectories: true)
        for l in langs {
            log("SYNTH \(l.key) (\(count) questions)")
            let (tl, files) = try Synth.buildTimeline(lang: l, count: count, dir: fixDir)
            timelines[l.key] = tl
            fixtures.filesCreated += files.count
        }
    } catch {
        log("synthesis failed: \(error)")
    }
    // Deletion of the run's own fixture directory (brief: delete after the run, record it).
    if let items = try? fm.contentsOfDirectory(atPath: fixDir.path) { fixtures.filesDeleted = items.count }
    try? fm.removeItem(at: fixDir)
    fixtures.directoryAbsentAfterDelete = !fm.fileExists(atPath: fixDir.path)
    fixtures.deletedAt = isoNow()
    log("FIXTURES deleted: \(fixtures.filesDeleted)/\(fixtures.filesCreated), dir absent: \(fixtures.directoryAbsentAfterDelete)")
    if timelines.count != langs.count { return 1 }

    // 2. Plan the runs.
    var plan: [(LangSpec, ModuleKind)] = []
    for l in langs {
        let loc = locales.first { $0.locale == l.localeID }!
        if !loc.speechTranscriberInstalled {
            plan.append((l, .speech(fast: false)))   // single attempt to capture the exact failure
        } else {
            if !flag("--fast-only") { plan.append((l, .speech(fast: false))) }
            plan.append((l, .speech(fast: true)))
        }
        if loc.dictationTranscriberInstalled && l.key != "en-samantha" {
            plan.append((l, .dictation(frequentFinalization: false)))
            plan.append((l, .dictation(frequentFinalization: true)))
        }
    }
    for (l, kind) in plan {
        let tl = timelines[l.key]!
        let loc = locales.first { $0.locale == l.localeID }!
        if case .speech = kind, !loc.speechTranscriberInstalled {
            // Not installed: attempt anyway to capture the exact failure (no model download is started by us).
            let r = await runOne(lang: l, timeline: tl, kind: kind, timeoutSec: 60)
            report.runs.append(r)
            continue
        }
        let r = await runOne(lang: l, timeline: tl, kind: kind, timeoutSec: tl.durationSec + 120)
        report.runs.append(r)
        if let s = r.summary { log("  done: word p50/p90 \(pair(s.wordLag)) ms, final \(pair(s.finalLag)) ms, WER \(String(format: "%.1f", s.wer * 100))%") }
    }
    report.fixtures = fixtures

    // 3. Write results and print the table.
    try? fm.createDirectory(at: root.appendingPathComponent("results"), withIntermediateDirectories: true)
    let out = root.appendingPathComponent("results/speech-\(stamp).json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try enc.encode(report).write(to: out)
        print("\nwrote \(out.path)")
    } catch { log("write failed: \(error)") }
    print("\n" + renderTable(report.runs))
    print("\n--- markdown ---\n" + renderMarkdownTable(report.runs) + "\n" + renderStrictMarkdown(report.runs))
    return 0
}

let code = await main()
exit(code)
