import Foundation
import AVFoundation

// Shared plumbing for the local-STT bench: report types, real-time feeder, resource probes.

struct FixtureRecord: Codable {
    var directory: String
    var filesCreated: Int
    var filesDeleted: Int
    var directoryAbsentAfterDelete: Bool
    var deletedAt: String
}

/// Output of one engine run over one timeline (events are in the same shape the Apple bench produces).
struct EngineOutput {
    var events: [Event]
    var loadSec: Double?           // model load / prepare time attributed to this run
    var feedEndSec: Double
    var feederLateP50Ms: Double
    var feederLateMaxMs: Double
    var chunks: Int
    var cpuSec: Double             // CPU seconds of the engine's own process during the stream (user+sys)
    var computeSec: Double?        // wall seconds spent inside engine calls (nil when not measurable)
    var peakRssMB: Double          // lifetime peak RSS of the engine's process at the end of the run
    var extra: [String: Double]
}

struct LangRun: Codable {
    let lang: String
    let voice: String
    let engine: String
    let status: String
    let error: String?
    let loadSec: Double?
    let streamSec: Double?
    let feedEndSec: Double?
    let feederLateP50Ms: Double?
    let feederLateMaxMs: Double?
    let chunks: Int?
    let cpuSec: Double?
    let cpuPct: Double?            // cpuSec / feedEndSec * 100 (100 = one core fully busy)
    let computeSec: Double?
    let rtf: Double?               // computeSec / audio seconds
    let peakRssMB: Double?
    let extra: [String: Double]?
    let summary: RunSummary?
    let questions: [QuestionMetrics]?
    let utterances: [Utterance]?
    let events: [Event]?
}

struct EngineReport: Codable {
    let engine: String
    let variant: String
    let tag: String
    let generatedAt: String
    let host: String
    let chunkMs: Int
    let leadSilenceSec: Double
    let gapSilenceSec: Double
    let tailSilenceSec: Double
    var runs: [LangRun]
    var fixtures: FixtureRecord?
    let notes: [String]
}

protocol Engine {
    var name: String { get }
    var variant: String { get }
    /// Loads the model; returns wall seconds (nil when the engine prepares per run).
    func load() async throws -> Double?
    func run(lang: LangSpec, timeline: Timeline) async throws -> EngineOutput
    func shutdown() async
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func logErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func ms(_ x: Double?) -> String {
    guard let x else { return "-" }
    return String(format: "%.0f", x * 1000)
}
func pair(_ s: Stat) -> String { "\(ms(s.p50)) / \(ms(s.p90))" }

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    func t(_ v: timeval) -> Double { Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
    return t(ru.ru_utime) + t(ru.ru_stime)
}

/// Peak resident set size of this process in MB (ru_maxrss is bytes on macOS).
func peakRssMB() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_maxrss) / 1_048_576.0
}

struct FeedStats { var lateP50Ms: Double; var lateMaxMs: Double; var feedEndSec: Double; var chunks: Int }

/// Real-time feeder, same scheme as the Apple bench: chunk i is delivered at t0 + (i+1) * chunkMs (absolute deadlines).
func realtimeFeed(count: Int, chunkMs: Int, clock: ContinuousClock, t0: ContinuousClock.Instant,
                  send: (Int) throws -> Void) async throws -> FeedStats {
    let dt = Double(chunkMs) / 1000.0
    var lates: [Double] = []
    lates.reserveCapacity(count)
    for i in 0..<count {
        let due = t0 + .seconds(Double(i + 1) * dt)
        try await clock.sleep(until: due)
        lates.append(secs(clock.now - due) * 1000.0)
        try send(i)
    }
    let feedEnd = secs(clock.now - t0)
    lates.sort()
    return FeedStats(lateP50Ms: lates.isEmpty ? 0 : lates[lates.count / 2], lateMaxMs: lates.last ?? 0, feedEndSec: feedEnd, chunks: count)
}

/// 16 kHz mono Float32 slices of `chunkMs` out of the timeline.
func sliceSamples(_ t: Timeline, chunkMs: Int) -> [ArraySlice<Float>] {
    let n = Int(Timeline.sampleRate * Double(chunkMs) / 1000.0)
    var out: [ArraySlice<Float>] = []
    var pos = 0
    while pos < t.samples.count {
        let e = min(pos + n, t.samples.count)
        out.append(t.samples[pos..<e])
        pos = e
    }
    return out
}
