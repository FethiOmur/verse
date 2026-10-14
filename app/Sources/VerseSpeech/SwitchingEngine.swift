@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import Speech

/// English `.auto` engine for one channel: Apple `SpeechTranscriber` from the first sample, the local Nemotron
/// model loading in the background, and a one-way switch to Nemotron at the first turn boundary after it is ready.
///
/// Rules:
/// - A turn boundary is `turnGap` (0.6 s) of silence in this channel's audio. The switch never happens
///   mid-utterance.
/// - At the boundary the Apple input is closed and Apple flushes its pending results (they cover audio before the
///   boundary); Nemotron starts on a fresh stream at the boundary and its results are shifted by the boundary time
///   so both engines share one audio timeline. No audio is fed to both, so no word is transcribed twice, and the
///   silence between them means none falls in the cut.
/// - If the model is missing or fails to load, Apple simply keeps running (`engine_fallback` status).
final class SwitchingEngine: TranscriptionEngine, @unchecked Sendable {
    let lang: String
    /// Silence that makes a turn boundary.
    var turnGap: TimeInterval = 0.6

    private let apple: any TranscriptionEngine
    /// Returns a prepared (model loaded) Nemotron-class engine, or throws. nil: no local engine available.
    private let makeLocal: (@Sendable () async throws -> any TranscriptionEngine)?
    private let unavailableReason: String?

    private let lock = OSAllocatedUnfairLock()
    private var channel: Channel = .remote
    private var status: @Sendable (ListenStatus) -> Void = { _ in }
    private var activeName: String
    private var local: (any TranscriptionEngine)?
    private var localLoadSec: Double?
    private var loadFailed = false
    private var abandoned = false
    private var loadTask: Task<Void, Never>?
    private var router: Task<Void, Never>?
    private var appleFlush: Task<Void, Never>?
    private var switched = false

    init(lang: String, apple: any TranscriptionEngine,
         makeLocal: (@Sendable () async throws -> any TranscriptionEngine)?, unavailableReason: String? = nil) {
        self.lang = lang
        self.apple = apple
        self.makeLocal = makeLocal
        self.unavailableReason = unavailableReason
        self.activeName = apple.engineName
    }

    /// The production wiring: local engine = `NemotronEngine` on `modelDir`; missing folder -> Apple only.
    static func auto(lang: String, apple: any TranscriptionEngine, modelDir: URL) -> SwitchingEngine {
        if let reason = NemotronEngine.unavailableReason(modelDir) {
            return SwitchingEngine(lang: lang, apple: apple, makeLocal: nil, unavailableReason: reason)
        }
        return SwitchingEngine(lang: lang, apple: apple, makeLocal: {
            let e = NemotronEngine(modelDir: modelDir)
            try await e.prepare()
            return e
        })
    }

    var engineName: String { lock.withLockUnchecked { activeName } }
    var hasSwitched: Bool { lock.withLockUnchecked { switched } }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) {
        lock.withLockUnchecked {
            self.channel = channel
            self.status = status
        }
        apple.attach(channel: channel, status: status)
    }

    private func report(_ s: ListenStatus) {
        let (sink, ch) = lock.withLockUnchecked { (status, channel) }
        var s = s
        s.channel = ch
        sink(s)
    }

    func prepare() async throws -> AVAudioFormat {
        let format = try await apple.prepare()
        if let makeLocal {
            let clock = ContinuousClock()
            let t0 = clock.now
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    let e = try await makeLocal()
                    let d = clock.now - t0
                    let sec = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                    guard let self else { await e.cancel(); return }
                    let drop = self.lock.withLockUnchecked { () -> Bool in
                        if self.abandoned { return true }
                        self.local = e
                        self.localLoadSec = sec
                        return false
                    }
                    if drop { await e.cancel() }
                } catch {
                    self?.lock.withLockUnchecked { self?.loadFailed = true }
                    self?.report(ListenStatus(state: "engine_fallback", engine: self?.apple.engineName,
                                              reason: "Nemotron failed to load: \(error)"))
                }
            }
            lock.withLockUnchecked { loadTask = task }
        } else if let unavailableReason {
            report(ListenStatus(state: "engine_fallback", engine: apple.engineName, reason: unavailableReason))
        }
        return format
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        let (appleIn, appleCont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await apple.start(input: appleIn, onResult: onResult)
        let turnGap = self.turnGap
        let task = Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.route(input: input, appleCont: appleCont, turnGap: turnGap, onResult: onResult)
        }
        lock.withLockUnchecked { router = task }
    }

    /// Feeds Apple until the switch, then the local engine. Runs until the input ends.
    private func route(input: AsyncStream<AnalyzerInput>, appleCont: AsyncStream<AnalyzerInput>.Continuation,
                       turnGap: TimeInterval, onResult: @escaping @Sendable (EngineResult) -> Void) async {
        var silence = SilenceTracker()
        var readyAt: TimeInterval?
        var localCont: AsyncStream<AnalyzerInput>.Continuation?
        var appleOpen = true

        for await item in input {
            let samples = PCMSamples.mono(item.buffer)
            let rate = item.buffer.format.sampleRate
            guard rate > 0 else { continue }
            silence.add(rms: PCMSamples.rms(samples), duration: Double(samples.count) / rate)

            if let lc = localCont {
                lc.yield(item)
                continue
            }
            appleCont.yield(item)
            let ready = lock.withLockUnchecked { local != nil && !abandoned }
            guard ready else { continue }
            if readyAt == nil {
                readyAt = silence.time
                report(ListenStatus(state: "engine_ready", engine: lock.withLockUnchecked { local?.engineName },
                                    loadSec: lock.withLockUnchecked { localLoadSec }, readyAtSec: silence.time))
            }
            guard silence.run >= turnGap, appleOpen, let engine = lock.withLockUnchecked({ local }) else { continue }

            // Turn boundary: start the local engine on a fresh stream at this sample, then let Apple flush.
            let boundary = silence.time
            let (localIn, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            do {
                try await engine.start(input: localIn) { r in
                    var r = r
                    r.start += boundary
                    r.end += boundary
                    onResult(r)
                }
            } catch {
                cont.finish()
                lock.withLockUnchecked { loadFailed = true; local = nil }
                report(ListenStatus(state: "engine_fallback", engine: apple.engineName,
                                    reason: "Nemotron could not start: \(error)"))
                await engine.cancel()
                continue
            }
            localCont = cont
            appleCont.finish()
            appleOpen = false
            let apple = self.apple
            let flush = Task<Void, Never>.detached { _ = try? await apple.finish() }
            let from = lock.withLockUnchecked { () -> String in
                appleFlush = flush
                switched = true
                let old = activeName
                activeName = engine.engineName
                return old
            }
            report(ListenStatus(state: "engine_switch", engine: engine.engineName, from: from,
                                loadSec: lock.withLockUnchecked { localLoadSec }, readyAtSec: readyAt,
                                switchAtSec: boundary, waitedSec: readyAt.map { boundary - $0 }))
        }
        if appleOpen { appleCont.finish() }
        localCont?.finish()
    }

    func finish() async throws {
        let r = lock.withLockUnchecked { router }
        await r?.value
        let (did, flush, engine) = lock.withLockUnchecked { (switched, appleFlush, local) }
        if did {
            await flush?.value
            try await engine?.finish()
        } else {
            try await apple.finish()
            abandonLoad()
        }
    }

    func cancel() async {
        let (r, engine) = lock.withLockUnchecked { (router, local) }
        r?.cancel()
        await apple.cancel()
        await engine?.cancel()
        abandonLoad()
    }

    /// The session is over without a switch: a local engine that is loaded (or still loading) is released, but the
    /// caller never waits for a load.
    private func abandonLoad() {
        let e = lock.withLockUnchecked { () -> (any TranscriptionEngine)? in
            abandoned = true
            let e = switched ? nil : local
            if !switched { local = nil }
            return e
        }
        if let e { Task { await e.cancel() } }
    }
}
