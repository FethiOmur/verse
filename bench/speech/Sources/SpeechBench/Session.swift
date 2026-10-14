import Foundation
import AVFoundation
import CoreMedia
import Speech

struct RunRef: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// One result as it arrived. `t` is the arrival time on the stream clock (seconds since the first buffer's start).
struct Event: Codable, Sendable {
    let t: Double
    let isFinal: Bool
    let start: Double
    let end: Double
    let text: String
    let runs: [RunRef]
}

struct RawResult: Sendable {
    let text: AttributedString
    let range: CMTimeRange
    let isFinal: Bool
}

enum ModuleKind: Sendable {
    case speech(fast: Bool)
    case dictation(frequentFinalization: Bool)

    var name: String {
        switch self {
        case .speech(let f): return f ? "SpeechTranscriber+fastResults" : "SpeechTranscriber"
        case .dictation(let f): return f ? "DictationTranscriber+frequentFinalization" : "DictationTranscriber"
        }
    }
}

struct SessionOutput: Sendable {
    var events: [Event]
    var audioFormat: String
    var prepareSec: Double
    var feedEndSec: Double        // stream clock when the last buffer was delivered
    var feederLateP50Ms: Double
    var feederLateMaxMs: Double
    var chunks: Int
}

enum Session {
    static let chunkMs = 50

    static func run(lang: LangSpec, timeline: Timeline, kind: ModuleKind) async throws -> SessionOutput {
        let locale = Locale(identifier: lang.localeID)
        switch kind {
        case .speech(let fast):
            var rep: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if fast { rep.insert(.fastResults) }
            let m = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: rep, attributeOptions: [.audioTimeRange])
            return try await drive(module: m, timeline: timeline) { (r: SpeechTranscriber.Result) in
                RawResult(text: r.text, range: r.range, isFinal: r.isFinal)
            }
        case .dictation(let freq):
            var rep: Set<DictationTranscriber.ReportingOption> = [.volatileResults]
            if freq { rep.insert(.frequentFinalization) }
            let m = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: rep, attributeOptions: [.audioTimeRange])
            return try await drive(module: m, timeline: timeline) { (r: DictationTranscriber.Result) in
                RawResult(text: r.text, range: r.range, isFinal: r.isFinal)
            }
        }
    }

    static func toEvent(_ r: RawResult, t: Double) -> Event {
        var runs: [RunRef] = []
        for (tr, rr) in r.text.runs[\.audioTimeRange] {
            let s = String(r.text[rr].characters)
            if let tr {
                runs.append(RunRef(text: s, start: tr.start.seconds, end: tr.end.seconds))
            } else {
                runs.append(RunRef(text: s, start: r.range.start.seconds, end: r.range.end.seconds))
            }
        }
        return Event(t: t, isFinal: r.isFinal, start: r.range.start.seconds, end: r.range.end.seconds,
                     text: String(r.text.characters), runs: runs)
    }

    static func drive<M: SpeechModule>(module: M, timeline: Timeline,
                                       extract: @escaping @Sendable (M.Result) -> RawResult) async throws -> SessionOutput
    where M.Results.Element == M.Result {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Synth.Failure(description: "bestAvailableAudioFormat returned nil")
        }
        let inputs = try Synth.makeInputs(timeline, format: format, chunkMs: chunkMs)
        let analyzer = SpeechAnalyzer(modules: [module])

        let clock = ContinuousClock()
        let p0 = clock.now
        try await analyzer.prepareToAnalyze(in: format)
        let prepareSec = secs(clock.now - p0)

        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        let t0 = clock.now
        let consumer = Task { () -> [Event] in
            var out: [Event] = []
            for try await r in module.results {
                let t = secs(clock.now - t0)
                out.append(toEvent(extract(r), t: t))
            }
            return out
        }

        // Real-time feeder: buffer i is delivered when its last sample would exist live.
        let dt = Double(chunkMs) / 1000.0
        var lates: [Double] = []
        lates.reserveCapacity(inputs.count)
        for (i, inp) in inputs.enumerated() {
            let due = t0 + .seconds(Double(i + 1) * dt)
            try await clock.sleep(until: due)
            lates.append(secs(clock.now - due) * 1000.0)
            cont.yield(inp)
        }
        let feedEnd = secs(clock.now - t0)
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let events = try await consumer.value

        lates.sort()
        return SessionOutput(events: events, audioFormat: "\(format.sampleRate) Hz, \(format.channelCount) ch, \(format.commonFormat)",
                             prepareSec: prepareSec, feedEndSec: feedEnd,
                             feederLateP50Ms: lates[lates.count / 2], feederLateMaxMs: lates.last ?? 0, chunks: inputs.count)
    }
}

func secs(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}
