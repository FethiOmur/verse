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
        case audio(AudioChunk)
        /// Clock tick from the silence pump.
        case tick(TimeInterval)
    }

    /// Starts the recognizer and the source. `onResult` gets results with session-time audio bounds.
    ///
    /// The recognizer's input is kept on session time, sample for sample: short gaps between chunks are filled
    /// with zeros, and when no chunk arrives for `pumpAfter` (a tap stops calling back when its app goes quiet
    /// or away) the pipeline feeds zeros itself at real-time pace. Without that, the last words before a pause
    /// stay unrecognized until audio resumes (measured: the volatile "budget" waited out a 3 s gap). Audio that
    /// arrives for a stretch already filled with zeros is trimmed so the timeline never shifts.
    func start(clock: SessionClock, onResult: @escaping @Sendable (EngineResult, TimeInterval) -> Void) async throws {
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
            var fedUntil: TimeInterval?        // session time up to which samples went to the recognizer
            func feed(_ samples: [Float]) {
                guard !samples.isEmpty else { return }
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
                    guard let f = fedUntil, rate > 0, now - f > pumpAfter else { continue }
                    let until = now - pumpAfter / 2
                    let n = Int((until - f) * rate)
                    if n > 0 {
                        feed([Float](repeating: 0, count: n))
                        fedUntil = f + Double(n) / rate
                    }
                case .audio(let chunk):
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
                    if let f = fedUntil {
                        let offset = chunk.startTime - f
                        if offset > 0.002 {
                            samples = [Float](repeating: 0, count: Int(offset * rate)) + samples
                        } else if offset < -0.002 {
                            let drop = min(samples.count, Int(-offset * rate))
                            samples.removeFirst(drop)
                        }
                    }
                    feed(samples)
                    fedUntil = max(fedUntil ?? chunk.endTime, chunk.endTime)
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
        try source.start(clock: clock,
                         onChunk: { itemCont.yield(.audio($0)) },
                         onEnd: { [weak self] in
                             self?.lock.withLockUnchecked { self?.ended = true }
                             self?.finishFeed()
                         })
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
