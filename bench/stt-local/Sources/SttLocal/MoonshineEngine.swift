import Foundation

struct WorkerMsg: @unchecked Sendable {
    let at: ContinuousClock.Instant
    let obj: [String: Any]
    var type: String { obj["type"] as? String ?? "" }
}

/// Moonshine Medium Streaming (quantized ORT, moonshine-voice 0.1.5) in a Python sidecar.
/// Audio goes in over a pipe at real-time pace; each worker message is stamped on arrival here, so the numbers include the IPC hop.
final class MoonshineEngine: Engine {
    let name = "moonshine"
    var variant: String { "moonshine-medium-streaming (moonshine-voice 0.1.5, quantized ORT, update_interval \(interval) s)" }
    let python: URL
    let worker: URL
    let modelDir: URL
    let interval: Double
    let clock = ContinuousClock()

    var proc: Process!
    var stdinH: FileHandle!
    var msgs: AsyncStream<WorkerMsg>!
    var iter: AsyncStream<WorkerMsg>.Iterator!
    var readerTask: Task<Void, Never>?
    var spawnToReadySec = 0.0
    var workerLoadSec = 0.0

    init(python: URL, worker: URL, modelDir: URL, interval: Double) {
        self.python = python; self.worker = worker; self.modelDir = modelDir; self.interval = interval
    }

    func next() async -> WorkerMsg? { await iter.next() }

    func load() async throws -> Double? {
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", worker.path, modelDir.path, String(interval)]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        let (stream, cont) = AsyncStream.makeStream(of: WorkerMsg.self)
        msgs = stream
        iter = stream.makeAsyncIterator()
        let t = clock.now
        try p.run()
        proc = p
        stdinH = inPipe.fileHandleForWriting
        let clk = clock
        readerTask = Task.detached {
            do {
                for try await line in outPipe.fileHandleForReading.bytes.lines {
                    let at = clk.now
                    guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    cont.yield(WorkerMsg(at: at, obj: o))
                }
            } catch {}
            cont.finish()
        }
        while let m = await next() {
            if m.type == "ready" {
                spawnToReadySec = secs(m.at - t)
                workerLoadSec = m.obj["load_s"] as? Double ?? 0
                return spawnToReadySec
            }
        }
        throw Synth.Failure(description: "moonshine worker exited before ready")
    }

    func send(_ type: UInt8, _ payload: Data = Data()) throws {
        var h = Data([type])
        var len = UInt32(payload.count).littleEndian
        h.append(Data(bytes: &len, count: 4))
        try stdinH.write(contentsOf: h + payload)
    }

    func shutdown() async {
        try? send(UInt8(ascii: "Q"))
        try? stdinH?.close()
        if let p = proc {
            for _ in 0..<50 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if p.isRunning { p.terminate() }
        }
        readerTask?.cancel()
    }

    func run(lang: LangSpec, timeline: Timeline) async throws -> EngineOutput {
        try send(UInt8(ascii: "S"))
        while let m = await next() { if m.type == "started" { break } }
        let slices = sliceSamples(timeline, chunkMs: Session.chunkMs)
        let frames: [Data] = slices.map { s in s.withUnsafeBufferPointer { Data(buffer: $0) } }
        let t0 = clock.now
        let collector = Task { () -> ([WorkerMsg], WorkerMsg?) in
            var evs: [WorkerMsg] = []
            while let m = await self.next() {
                if m.type == "event" { evs.append(m) }
                else if m.type == "session_end" { return (evs, m) }
            }
            return (evs, nil)
        }
        let feed = try await realtimeFeed(count: frames.count, chunkMs: Session.chunkMs, clock: clock, t0: t0) { i in
            try self.send(UInt8(ascii: "A"), frames[i])
        }
        try send(UInt8(ascii: "E"))
        let (evMsgs, end) = await collector.value
        guard let end else { throw Synth.Failure(description: "worker ended without session_end") }
        var events: [Event] = []
        var latMax = 0.0
        for m in evMsgs {
            let o = m.obj
            let text = (o["text"] as? String) ?? ""
            let start = (o["start"] as? Double) ?? 0
            let dur = (o["dur"] as? Double) ?? 0
            latMax = max(latMax, (o["lat_ms"] as? Double) ?? 0)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let kind = (o["kind"] as? String) ?? ""
            events.append(Event(t: secs(m.at - t0), isFinal: kind == "LineCompleted", start: start, end: start + dur,
                                text: text, runs: [RunRef(text: text, start: start, end: start + dur)]))
        }
        let addS = end.obj["add_audio_s"] as? Double ?? 0
        let stopS = end.obj["stop_s"] as? Double ?? 0
        return EngineOutput(events: events, loadSec: nil, feedEndSec: feed.feedEndSec,
                            feederLateP50Ms: feed.lateP50Ms, feederLateMaxMs: feed.lateMaxMs, chunks: feed.chunks,
                            cpuSec: end.obj["cpu_s"] as? Double ?? 0, computeSec: addS + stopS,
                            peakRssMB: end.obj["maxrss_mb"] as? Double ?? 0,
                            extra: ["addAudioMaxMs": (end.obj["add_audio_max_s"] as? Double ?? 0) * 1000,
                                    "lastTranscriptionLatencyMaxMs": latMax,
                                    "workerLoadSec": workerLoadSec,
                                    "events": Double(evMsgs.count)])
    }
}
