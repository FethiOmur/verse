import Foundation

/// Control: Apple SpeechTranscriber + fastResults, via the unchanged Session code of bench/speech.
struct AppleEngine: Engine {
    let name = "apple"
    let variant = "SpeechTranscriber+fastResults"
    func load() async throws -> Double? { nil }
    func shutdown() async {}
    func run(lang: LangSpec, timeline: Timeline) async throws -> EngineOutput {
        let c0 = cpuSeconds()
        let o = try await Session.run(lang: lang, timeline: timeline, kind: .speech(fast: true))
        return EngineOutput(events: o.events, loadSec: o.prepareSec, feedEndSec: o.feedEndSec,
                            feederLateP50Ms: o.feederLateP50Ms, feederLateMaxMs: o.feederLateMaxMs, chunks: o.chunks,
                            cpuSec: cpuSeconds() - c0, computeSec: nil, peakRssMB: peakRssMB(),
                            extra: [:])
    }
}
