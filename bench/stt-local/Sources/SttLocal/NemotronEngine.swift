import Foundation
import AVFoundation
import FluidAudio

struct BufBox: @unchecked Sendable { let buf: AVAudioPCMBuffer }

struct NWord { var text: String; var start: Double; var end: Double; var firstTok: Int; var lastTok: Int }
struct ChunkLog { var t: Double; var nTokens: Int }

/// Nemotron Speech Streaming 0.6B (CoreML, 560 ms chunk) through FluidAudio's StreamingNemotronAsrManager.
final class NemotronEngine: Engine {
    let name = "nemotron"
    let variant = "nemotron-560ms (FluidAudio 0.17.7, CoreML int8, cpuAndNeuralEngine)"
    let modelDir: URL
    var manager: StreamingNemotronAsrManager!

    init(modelDir: URL) { self.modelDir = modelDir }

    func load() async throws -> Double? {
        let clock = ContinuousClock()
        let t = clock.now
        manager = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
        try await manager.loadModels(from: modelDir)
        return secs(clock.now - t)
    }

    func shutdown() async { await manager?.cleanup() }

    /// Groups SentencePiece tokens (first `n`) into words. A word starts at a token with the boundary marker.
    static func words(_ tt: [TokenTiming], upTo n: Int) -> [NWord] {
        var out: [NWord] = []
        for i in 0..<min(n, tt.count) {
            let raw = tt[i].token
            let starts = raw.hasPrefix("\u{2581}")
            let piece = raw.replacingOccurrences(of: "\u{2581}", with: "")
            if out.isEmpty || (starts && !(out.last!.text.isEmpty)) {
                out.append(NWord(text: piece, start: tt[i].startTime, end: tt[i].endTime, firstTok: i, lastTok: i))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = tt[i].endTime
                out[out.count - 1].lastTok = i
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    func run(lang: LangSpec, timeline: Timeline) async throws -> EngineOutput {
        await manager.reset()
        let clock = ContinuousClock()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Timeline.sampleRate, channels: 1, interleaved: false)!
        let slices = sliceSamples(timeline, chunkMs: Session.chunkMs)
        var bufs: [BufBox] = []
        bufs.reserveCapacity(slices.count)
        for s in slices {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
            b.frameLength = AVAudioFrameCount(s.count)
            s.withUnsafeBufferPointer { p in b.floatChannelData![0].update(from: p.baseAddress!, count: s.count) }
            bufs.append(BufBox(buf: b))
        }
        let (stream, cont) = AsyncStream.makeStream(of: BufBox.self)
        let mgr = manager!
        let cpu0 = cpuSeconds()
        let t0 = clock.now
        let consumer = Task { () -> (logs: [ChunkLog], compute: Double, timings: [TokenTiming], text: String, finishT: Double) in
            var logs: [ChunkLog] = []
            var last = 0
            var compute = 0.0
            for await b in stream {
                let c0 = clock.now
                _ = try await mgr.process(audioBuffer: b.buf)
                compute += secs(clock.now - c0)
                let t = secs(clock.now - t0)
                let n = await mgr.getTokenTimings().count
                if n > last { logs.append(ChunkLog(t: t, nTokens: n)); last = n }
            }
            let c0 = clock.now
            let (text, timings) = try await mgr.finishWithTokenTimings()
            compute += secs(clock.now - c0)
            let t = secs(clock.now - t0)
            if timings.count > last { logs.append(ChunkLog(t: t, nTokens: timings.count)) }
            return (logs, compute, timings, text, t)
        }
        let feed = try await realtimeFeed(count: bufs.count, chunkMs: Session.chunkMs, clock: clock, t0: t0) { i in
            cont.yield(bufs[i])
        }
        cont.finish()
        let res = try await consumer.value
        let cpu = cpuSeconds() - cpu0
        let events = NemotronEngine.buildEvents(logs: res.logs, timings: res.timings, utts: timeline.utterances)
        return EngineOutput(events: events, loadSec: nil, feedEndSec: feed.feedEndSec,
                            feederLateP50Ms: feed.lateP50Ms, feederLateMaxMs: feed.lateMaxMs, chunks: feed.chunks,
                            cpuSec: cpu, computeSec: res.compute, peakRssMB: peakRssMB(),
                            extra: ["tokens": Double(res.timings.count), "finishAtSec": res.finishT])
    }

    /// Events in the Apple-bench shape.
    /// - Volatile: after every chunk that decoded new tokens, the words so far for questions that are not yet final
    ///   (the last word may be a partial word, as in a live display).
    /// - Final: RNN-T greedy output is never revised, so a question's text is final once its last token is out.
    ///   One final event per question, arriving at the chunk that emitted its last token (determined after the run).
    static func buildEvents(logs: [ChunkLog], timings: [TokenTiming], utts: [Utterance]) -> [Event] {
        let wins = Analyze.windows(utts)
        let allWords = words(timings, upTo: timings.count)
        func qIndex(_ w: NWord) -> Int? {
            // Window membership by the word's first-token time (a trailing '?' token would stretch the end).
            let m = w.start
            return wins.firstIndex { m >= $0.0 && m < $0.1 }
        }
        var finalT = [Int: Double]()
        var qWords = [Int: [NWord]]()
        for w in allWords {
            guard let q = qIndex(w) else { continue }
            qWords[q, default: []].append(w)
        }
        for (q, ws) in qWords {
            let lastTok = ws.map { $0.lastTok }.max() ?? 0
            if let l = logs.first(where: { $0.nTokens > lastTok }) { finalT[q] = l.t }
        }
        func ev(_ t: Double, final: Bool, _ ws: [NWord]) -> Event {
            let runs = ws.map { RunRef(text: $0.text + " ", start: $0.start, end: $0.end) }
            return Event(t: t, isFinal: final, start: ws.first?.start ?? 0, end: ws.last?.end ?? 0,
                         text: ws.map { $0.text }.joined(separator: " "), runs: runs)
        }
        var out: [Event] = []
        for l in logs {
            let ws = words(timings, upTo: l.nTokens).filter { w in
                guard let q = qIndex(w), let ft = finalT[q] else { return false }
                return ft >= l.t
            }
            if !ws.isEmpty { out.append(ev(l.t, final: false, ws)) }
        }
        for (q, ws) in qWords { if let ft = finalT[q] { out.append(ev(ft, final: true, ws)) } }
        out.sort { $0.t != $1.t ? $0.t < $1.t : (!$0.isFinal && $1.isFinal) }
        return out
    }
}
