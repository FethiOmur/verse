@preconcurrency import AVFoundation
import Foundation
@preconcurrency import FluidAudio
import os
@preconcurrency import Speech

/// One SentencePiece token with its time (seconds from the first sample fed to the engine).
struct NemotronToken: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct NemotronWord: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var firstTok: Int
    var lastTok: Int
}

/// Turns the token stream of an RNN-T decoder (greedy: tokens are never revised) into the `EngineResult` contract:
/// volatile results as words arrive, one final per utterance at the end-of-speech boundary.
///
/// Why a boundary of our own: the model emits the trailing `?` / `.` only when the *next* speech starts (about 3 s
/// after the question in the bench), so waiting for punctuation makes finals ~3 s late. Words are final as soon as
/// they appear, so the boundary comes from the audio: `endSilence` of silence and the chunk containing the end of
/// speech (plus `settleMargin`) decoded. A punctuation-only token that arrives after a final belongs to that
/// utterance and is dropped, not turned into an utterance of its own.
struct NemotronUtteranceTracker {
    /// Silence that ends an utterance.
    var endSilence: TimeInterval = 0.5
    /// The decoded audio must reach this far past the last voiced sample before the final goes out.
    var settleMargin: TimeInterval = 0.3
    /// A longer utterance is split after this many seconds (everything but the last word becomes a final).
    var maxUtteranceSeconds: TimeInterval = 20

    private var startTok = 0
    private var seen = 0
    private(set) var words: [NemotronWord] = []

    var isOpen: Bool { !words.isEmpty }

    static func isPunctuationOnly(_ piece: String) -> Bool {
        !piece.contains { $0.isLetter || $0.isNumber }
    }

    static func group(_ tokens: ArraySlice<NemotronToken>, firstIndex: Int) -> [NemotronWord] {
        var out: [NemotronWord] = []
        var idx = firstIndex
        for t in tokens {
            let starts = t.text.hasPrefix("\u{2581}")
            let piece = t.text.replacingOccurrences(of: "\u{2581}", with: "")
            defer { idx += 1 }
            if piece.isEmpty { continue }
            if out.isEmpty || (starts && !isPunctuationOnly(piece)) {
                out.append(NemotronWord(text: piece, start: t.start, end: t.end, firstTok: idx, lastTok: idx))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = max(out[out.count - 1].end, t.end)
                out[out.count - 1].lastTok = idx
            }
        }
        return out
    }

    private func result(_ ws: [NemotronWord], final: Bool) -> EngineResult {
        let start = ws.first?.start ?? 0
        return EngineResult(text: ws.map(\.text).joined(separator: " "), isFinal: final,
                            start: start, end: max(ws.last?.end ?? start, start))
    }

    /// New tokens arrived (`tokens` is the whole list since the stream started). Returns the results to emit:
    /// a forced final for an over-long utterance, then the volatile text of the open utterance.
    mutating func ingest(_ tokens: [NemotronToken]) -> [EngineResult] {
        guard tokens.count > seen else { return [] }
        seen = tokens.count
        if words.isEmpty {
            // Late punctuation of the utterance that was just finalized.
            while startTok < tokens.count, Self.isPunctuationOnly(tokens[startTok].text) { startTok += 1 }
        }
        words = Self.group(tokens[startTok...], firstIndex: startTok)
        var out: [EngineResult] = []
        if words.count > 1, let first = words.first, let last = words.last, last.end - first.start > maxUtteranceSeconds {
            out.append(result(Array(words.dropLast()), final: true))
            startTok = last.firstTok
            words = [last]
        }
        if !words.isEmpty { out.append(result(words, final: false)) }
        return out
    }

    /// Final for the open utterance (everything decoded so far belongs to it).
    mutating func finalizeOpen() -> EngineResult? {
        guard !words.isEmpty else { return nil }
        let r = result(words, final: true)
        startTok = seen
        words = []
        return r
    }

    /// The end-of-speech boundary check, called after every decoded stretch.
    mutating func finalIfDue(silenceRun: TimeInterval, lastVoicedEnd: TimeInterval, decodedEnd: TimeInterval) -> EngineResult? {
        guard isOpen, silenceRun >= endSilence, decodedEnd >= lastVoicedEnd + settleMargin else { return nil }
        return finalizeOpen()
    }
}

/// Nemotron Speech Streaming 0.6B (CoreML, 560 ms chunk) through FluidAudio, as a `TranscriptionEngine`.
/// English only. Takes buffers of any PCM format; 16 kHz mono is what it decodes.
final class NemotronEngine: TranscriptionEngine, @unchecked Sendable {
    let lang = "en"
    var engineName: String { NemotronModel.engineName }

    static let sampleRate: Double = 16_000

    private let modelDir: URL
    private let pool: NemotronModelPool
    private let lock = OSAllocatedUnfairLock()
    private var lease: NemotronModelPool.Lease?
    private var loadStarted: ContinuousClock.Instant?
    private var loaded: StreamingNemotronAsrManager?
    private var runTask: Task<Void, Never>?
    private var released = false
    private var _loadSeconds: Double?
    private let errorSlot = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Seconds `prepare()` waited for the model (nil before it finished).
    var loadSeconds: Double? { lock.withLockUnchecked { _loadSeconds } }
    /// Decoding error that ended the run early, if any.
    var runError: String? { errorSlot.withLock { $0 } }

    init(modelDir: URL = NemotronModel.defaultDirectory, pool: NemotronModelPool = .shared) {
        self.modelDir = modelDir
        self.pool = pool
    }

    /// Starts the load without waiting for it (safe to call more than once).
    func beginLoading() async {
        let have = lock.withLockUnchecked { lease != nil }
        if have { return }
        let l = await pool.acquire(dir: modelDir)
        lock.withLockUnchecked {
            if lease == nil { lease = l; loadStarted = ContinuousClock.now }
        }
        let extra = lock.withLockUnchecked { lease?.id != l.id }
        if extra { await pool.release(l) }
    }

    @discardableResult
    func prepare() async throws -> AVAudioFormat {
        if let reason = Self.unavailableReason(modelDir) {
            throw ListenError.speechUnavailable(lang: lang, reason: reason)
        }
        await beginLoading()
        guard let l = lock.withLockUnchecked({ lease }) else {
            throw ListenError.speechUnavailable(lang: lang, reason: "Nemotron engine was cancelled")
        }
        do {
            let m = try await l.task.value
            lock.withLockUnchecked {
                loaded = m
                if _loadSeconds == nil, let t0 = loadStarted {
                    let d = ContinuousClock.now - t0
                    _loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                }
            }
        } catch {
            await releaseLease()
            throw ListenError.speechUnavailable(lang: lang, reason: "Nemotron model failed to load: \(error.localizedDescription)")
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
    }

    static func unavailableReason(_ dir: URL) -> String? {
        let missing = NemotronModel.missingEntries(at: dir)
        return missing.isEmpty ? nil : "Nemotron model files missing in \(dir.path): \(missing.joined(separator: ", "))"
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        guard let manager = lock.withLockUnchecked({ loaded }) else {
            throw ListenError.speechUnavailable(lang: lang, reason: "engine not prepared")
        }
        await manager.reset()
        let chunkSamples = await manager.config.chunkSamples
        let slot = errorSlot
        let task = Task<Void, Never>.detached(priority: .userInitiated) {
            await Self.run(manager: manager, chunkSamples: chunkSamples, input: input, onResult: onResult) { msg in
                slot.withLock { $0 = msg }
            }
        }
        lock.withLockUnchecked { runTask = task }
    }

    func finish() async throws {
        let t = lock.withLockUnchecked { runTask }
        await t?.value
        await releaseLease()
    }

    func cancel() async {
        let t = lock.withLockUnchecked { runTask }
        t?.cancel()
        await t?.value
        await releaseLease()
    }

    private func releaseLease() async {
        let l: NemotronModelPool.Lease? = lock.withLockUnchecked {
            if released { return nil }
            released = true
            loaded = nil
            return lease
        }
        if let l { await pool.release(l) }
    }

    // MARK: decode loop

    private struct BufBox: @unchecked Sendable { let buf: AVAudioPCMBuffer }

    private static func tokens(_ tt: [TokenTiming]) -> [NemotronToken] {
        tt.map { NemotronToken(text: $0.token, start: $0.startTime, end: $0.endTime) }
    }

    private static func run(manager: StreamingNemotronAsrManager, chunkSamples: Int, input: AsyncStream<AnalyzerInput>,
                            onResult: @Sendable (EngineResult) -> Void, fail: @Sendable (String) -> Void) async {
        var tracker = NemotronUtteranceTracker()
        var silence = SilenceTracker()
        var fed = 0                       // samples at 16 kHz handed to the decoder
        var chunksSeen = 0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        func emit(_ rs: [EngineResult]) { for r in rs { onResult(r) } }

        for await item in input {
            if Task.isCancelled { return }
            let raw = PCMSamples.mono(item.buffer)
            guard !raw.isEmpty else { continue }
            let rate = item.buffer.format.sampleRate
            let samples = PCMSamples.resample(raw, from: rate, to: sampleRate)
            let dur = Double(samples.count) / sampleRate
            let runBefore = silence.run
            let voiced = silence.add(rms: PCMSamples.rms(samples), duration: dur)
            // Speech resumed after a boundary whose final has not gone out yet (the decoder had not caught up):
            // settle the old utterance now, so it does not swallow the new one.
            if voiced, runBefore >= tracker.endSilence, let f = tracker.finalizeOpen() { emit([f]) }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            fed += samples.count
            do {
                _ = try await manager.process(audioBuffer: buf)
            } catch {
                fail("\(error)")
                return
            }
            let chunks = fed / chunkSamples
            if chunks > chunksSeen {
                chunksSeen = chunks
                let tt = await manager.getTokenTimings()
                emit(tracker.ingest(tokens(tt)))
            }
            let decodedEnd = Double(chunksSeen * chunkSamples) / sampleRate
            if let f = tracker.finalIfDue(silenceRun: silence.run, lastVoicedEnd: silence.lastVoicedEnd, decodedEnd: decodedEnd) {
                emit([f])
            }
        }
        if Task.isCancelled { return }
        // Input ended: decode the padded remainder and settle what is left.
        do {
            let (_, timings) = try await manager.finishWithTokenTimings()
            emit(tracker.ingest(tokens(timings)))
            if let f = tracker.finalizeOpen() { emit([f]) }
        } catch {
            fail("\(error)")
        }
    }
}
