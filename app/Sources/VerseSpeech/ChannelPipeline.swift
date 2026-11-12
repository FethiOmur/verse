@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import VerseAudio

/// source -> (envelope, dead-stream detector) -> format conversion -> recognizer, for one channel.
/// Each chunk goes to the recognizer as soon as it arrives (no batching).
final class ChannelPipeline: @unchecked Sendable {
    let channel: Channel
    let source: any AudioCaptureSource
    let engine: any TranscriptionEngine
    let envelope = EnvelopeTrack()
    private let lock = OSAllocatedUnfairLock()
    private var detector = DeadStreamDetector()
    private var origin: TimeInterval?
    private var feedContinuation: AsyncStream<FeedItem>.Continuation?
    private var tickerTask: Task<Void, Never>?
    private var feeder: Task<Void, Never>?
    private var format: AVAudioFormat?
    private(set) var startedAt: TimeInterval = 0
    private(set) var feedError: String?
    private var chunkCount = 0
    /// Chunks received so far (for the `--levels` readout).
    var chunksReceived: Int { lock.withLockUnchecked { chunkCount } }
    private var ended = false
    private var shadow: ShadowRecognizer?

    /// Interim AUTO language: a recognizer for a candidate language that gets the same samples as the main one.
    func setShadow(_ s: ShadowRecognizer?) { lock.withLockUnchecked { shadow = s } }
    func takeShadow() -> ShadowRecognizer? { lock.withLockUnchecked { let s = shadow; shadow = nil; return s } }
    func shadowRecognizer() -> ShadowRecognizer? { currentShadow() }
    private func currentShadow() -> ShadowRecognizer? { lock.withLockUnchecked { shadow } }

    /// Without a chunk for this long, the pipeline feeds silence itself.
    static let pumpAfter: TimeInterval = 0.15

    init(channel: Channel, source: any AudioCaptureSource, engine: any TranscriptionEngine) {
        self.channel = channel
        self.source = source
        self.engine = engine
    }

    var originTime: TimeInterval? { lock.withLockUnchecked { origin } }

    func prepare() async throws {
        format = try await engine.prepare()
    }

    enum FeedItem: Sendable {
        /// A chunk and the session time it reached the pipeline.
        case audio(AudioChunk, arrivedAt: TimeInterval)
        /// Clock tick from the silence pump.
        case tick(TimeInterval)
    }

    /// Starts the recognizer and the source. `onResult` gets results with session-time audio bounds.
    ///
    /// The recognizer's input is kept on session time, sample for sample: short gaps between chunks are filled
    /// with zeros, and when no chunk arrives for `pumpAfter` (a tap stops calling back when its app goes quiet
    /// or away) the pipeline feeds zeros itself at real-time pace. Without that, the last words before a pause
    /// stay unrecognized until audio resumes (measured: the volatile "budget" waited out a 3 s gap). Audio that
    /// arrives for a stretch already filled with zeros is trimmed so the timeline never shifts. The pump waits out the
    /// source's own delivery latency (`FeedTimeline`), so a slow input such as a Bluetooth headset does not get its real
    /// audio trimmed in place of silence (review S8).
    /// `onIssue` gets the source's runtime capture events (rebuilt after a device change, or failed for good; review H5).
    func start(clock: SessionClock, onIssue: @escaping @Sendable (ListenError) -> Void = { _ in },
               onResult: @escaping @Sendable (EngineResult, TimeInterval) -> Void) async throws {
        guard let format else { throw ListenError.speechUnavailable(lang: engine.lang, reason: "not prepared") }
        let (items, itemCont) = AsyncStream.makeStream(of: FeedItem.self, bufferingPolicy: .unbounded)
        let (inputs, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        lock.withLockUnchecked { feedContinuation = itemCont }

        try await engine.start(input: inputs) { [weak self] r in
            guard let self, let o = self.originTime else { return }
            onResult(r, o)
        }

        let envelope = self.envelope
        let pumpAfter = Self.pumpAfter
        feeder = Task.detached(priority: .userInitiated) { [weak self] in
            var converter: AVAudioConverter?
            var rate: Double = 0
            var timeline = FeedTimeline(pumpAfter: pumpAfter)
            func feed(_ samples: [Float], endTime: TimeInterval) {
                guard !samples.isEmpty else { return }
                self?.currentShadow()?.feed(samples, rate: rate, endTime: endTime)
                do {
                    if let buf = try ChannelPipeline.convert(samples, sampleRate: rate, to: format, with: converter) {
                        inputCont.yield(AnalyzerInput(buffer: buf))
                    }
                } catch {
                    self?.lock.withLockUnchecked { self?.feedError = "\(error)" }
                }
            }
            for await item in items {
                guard let self else { break }
                switch item {
                case .tick(let now):
                    if let (n, end) = timeline.pump(now: now, rate: rate) {
                        feed([Float](repeating: 0, count: n), endTime: end)
                    }
                case .audio(let chunk, let arrivedAt):
                    envelope.add(chunk)
                    self.lock.withLockUnchecked {
                        self.chunkCount += 1
                        self.detector.observe(chunk)
                        if self.origin == nil { self.origin = chunk.startTime }
                    }
                    if converter == nil || rate != chunk.sampleRate {
                        do { converter = try Self.makeConverter(from: chunk.sampleRate, to: format) } catch {
                            self.lock.withLockUnchecked { self.feedError = "\(error)" }
                            continue
                        }
                        rate = chunk.sampleRate
                    }
                    var samples = chunk.samples
                    let fit = timeline.place(start: chunk.startTime, end: chunk.endTime, count: samples.count,
                                             rate: rate, arrivedAt: arrivedAt)
                    if fit.pad > 0 {
                        samples = [Float](repeating: 0, count: fit.pad) + samples
                    } else if fit.drop > 0 {
                        samples.removeFirst(fit.drop)
                    }
                    feed(samples, endTime: chunk.endTime)
                }
            }
            inputCont.finish()
        }

        let ticker = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                itemCont.yield(.tick(clock.now()))
            }
        }
        lock.withLockUnchecked { tickerTask = ticker }

        startedAt = clock.now()
        let channel = self.channel
        source.setEventHandler { ev in onIssue(Self.issue(for: ev, channel: channel)) }
        try source.start(clock: clock,
                         onChunk: { itemCont.yield(.audio($0, arrivedAt: clock.now())) },
                         onEnd: { [weak self] in
                             self?.lock.withLockUnchecked { self?.ended = true }
                             self?.finishFeed()
                         })
    }

    static func issue(for event: CaptureEvent, channel: Channel) -> ListenError {
        switch event {
        case .rebuilt(let why): return .captureRecovered(channel, why)
        case .failed(let why): return .captureFailed(channel, why)
        }
    }

    private func finishFeed() {
        let (c, t) = lock.withLockUnchecked { () -> (AsyncStream<FeedItem>.Continuation?, Task<Void, Never>?) in
            let r = (feedContinuation, tickerTask)
            feedContinuation = nil
            tickerTask = nil
            return r
        }
        t?.cancel()
        c?.finish()
    }

    /// Dead-stream check (call periodically).
    func checkHealth(now: TimeInterval) -> DeadStreamDetector.Verdict {
        let src = source
        let started = startedAt
        return lock.withLockUnchecked { ended ? .ok : detector.check(now: now, startedAt: started, targetProducing: { src.targetIsProducingOutput() }) }
    }

    /// Waits until the source has ended (finite sources) or `stopSource()` was called, then flushes the recognizer.
    func waitUntilDone() async {
        await feeder?.value
        try? await engine.finish()
    }

    func stopSource() {
        source.stop()
        finishFeed()
    }

    // MARK: conversion

    static func makeConverter(from sampleRate: Double, to target: AVAudioFormat) throws -> AVAudioConverter? {
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw ListenError.sourceFailed("bad source format \(sampleRate) Hz")
        }
        if src == target { return nil }
        guard let c = AVAudioConverter(from: src, to: target) else {
            throw ListenError.sourceFailed("no converter \(src) -> \(target)")
        }
        return c
    }

    static func convert(_ samples: [Float], sampleRate: Double, to target: AVAudioFormat,
                        with converter: AVAudioConverter?) throws -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let src = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in src.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
        guard let converter else { return src }
        let cap = AVAudioFrameCount(Double(samples.count) * target.sampleRate / sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let srcRef = src
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, st in
            if supplied { st.pointee = .noDataNow; return nil }
            supplied = true
            st.pointee = .haveData
            return srcRef
        }
        if status == .error { throw ListenError.sourceFailed("convert: \(err?.localizedDescription ?? "?")") }
        return out.frameLength > 0 ? out : nil
    }
}

/// The recognizer's input timeline for one channel: which stretch of session time has been fed, how much silence the pump
/// adds when chunks stop, and how a chunk is fitted onto what was already fed.
///
/// Chunks are stamped with their capture time, and some inputs deliver them well after that (a Bluetooth headset: 100-300 ms
/// and bursty). A pump that only looked at the capture times would fill zeros for audio still on its way, and the real chunk
/// would then be trimmed to keep the timeline (review S8). So the timeline tracks how late chunks arrive (`lateness`: the
/// largest recent arrival minus capture end, decaying slowly) and pumps only past that.
struct FeedTimeline: Sendable {
    let pumpAfter: TimeInterval
    /// Session time up to which samples went to the recognizer.
    private(set) var fedUntil: TimeInterval?
    /// How long after its capture end a chunk reaches the pipeline (recent maximum).
    private(set) var lateness: TimeInterval = 0
    /// Real samples dropped because their stretch had been filled with silence already.
    private(set) var droppedSamples = 0

    /// Lateness above this is a stall (a frozen callback), not the input's latency: the pump must still answer within a second.
    static let maxLateness: TimeInterval = 0.5
    /// Seconds of lateness forgotten per second of audio, so a passing spike does not slow the pump for the rest of the call.
    static let latenessDecay: Double = 0.05

    init(pumpAfter: TimeInterval) { self.pumpAfter = pumpAfter }

    /// Silence to feed at clock time `now`, as (sample count, end time), or nil when the stream is not quiet long enough.
    mutating func pump(now: TimeInterval, rate: Double) -> (Int, TimeInterval)? {
        guard let f = fedUntil, rate > 0 else { return nil }
        let heard = now - lateness             // capture time up to which audio could have arrived by now
        guard heard - f > pumpAfter else { return nil }
        let n = Int((heard - pumpAfter / 2 - f) * rate)
        guard n > 0 else { return nil }
        let end = f + Double(n) / rate
        fedUntil = end
        return (n, end)
    }

    /// Fits a chunk of `count` samples captured over `start...end` onto the timeline: zeros to put in front for a gap, or
    /// samples to drop from its front where that stretch was fed already.
    mutating func place(start: TimeInterval, end: TimeInterval, count: Int, rate: Double,
                        arrivedAt: TimeInterval) -> (pad: Int, drop: Int) {
        let late = min(max(arrivedAt - end, 0), Self.maxLateness)
        lateness = max(late, lateness - Self.latenessDecay * max(end - start, 0))
        var pad = 0, drop = 0
        if let f = fedUntil {
            let offset = start - f
            if offset > 0.002 {
                pad = Int(offset * rate)
            } else if offset < -0.002 {
                drop = min(count, Int(-offset * rate))
                droppedSamples += drop
            }
        }
        fedUntil = max(fedUntil ?? end, end)
        return (pad, drop)
    }
}
