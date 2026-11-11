@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import Speech

/// Keeps one channel transcribing when its recognizer fails mid-call (review H8). Every session engine is wrapped in one.
///
/// Before: a Nemotron decode error ended its run and nothing read the error; Apple was already closed after the switch, and the
/// dead-stream watchdog watches audio chunks, which kept arriving. The channel went silent for the rest of the call.
///
/// Now: the active engine reports a mid-stream failure (`setFailureHandler`). At the next input buffer the wrapper retires it,
/// builds a fresh fallback engine (the Apple engine for the language, from `makeFallback`), starts it on the audio from that
/// point and shifts its results by the audio already fed, so the channel's timeline stays continuous. The audio the failed
/// engine had queued but not decoded is lost (a fraction of a second). At most `maxRecoveries` replacements per channel; after
/// that, or if the fallback cannot be built, the input is drained and the channel reports `speechFailed`.
///
/// Rejected: restarting the same engine. A Nemotron failure is likely to repeat on the same model; the Apple engine is the
/// fallback the app already relies on (`SwitchingEngine` before the switch, `engine_fallback`).
final class RecoveringEngine: TranscriptionEngine, @unchecked Sendable {
    let lang: String
    let channel: Channel
    let maxRecoveries: Int
    private let makeFallback: @Sendable () throws -> any TranscriptionEngine
    private let report: @Sendable (ListenError) -> Void

    private let lock = OSAllocatedUnfairLock()
    private var active: any TranscriptionEngine
    /// Bumped on every replacement; a failure callback from an older engine is ignored.
    private var activeGen = 0
    private var pendingFailure: String?
    private var status: @Sendable (ListenStatus) -> Void = { _ in }
    private var inputFormat: AVAudioFormat?
    private var router: Task<Void, Never>?
    private var retiring: [Task<Void, Never>] = []
    private var recoveries_ = 0
    private var gaveUp_ = false

    /// Replacements made (or attempted) so far.
    var recoveries: Int { lock.withLockUnchecked { recoveries_ } }
    /// The channel has no working recognizer left.
    var gaveUp: Bool { lock.withLockUnchecked { gaveUp_ } }

    init(primary: any TranscriptionEngine, channel: Channel, maxRecoveries: Int = 2,
         makeFallback: @escaping @Sendable () throws -> any TranscriptionEngine,
         report: @escaping @Sendable (ListenError) -> Void) {
        self.lang = primary.lang
        self.channel = channel
        self.maxRecoveries = maxRecoveries
        self.active = primary
        self.makeFallback = makeFallback
        self.report = report
    }

    var engineName: String { lock.withLockUnchecked { active.engineName } }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) {
        let e = lock.withLockUnchecked { () -> any TranscriptionEngine in self.status = status; return active }
        e.attach(channel: channel, status: status)
    }

    func prepare() async throws -> AVAudioFormat {
        let e = lock.withLockUnchecked { active }
        let f = try await e.prepare()
        lock.withLockUnchecked { inputFormat = f }
        return f
    }

    private func watch(_ e: any TranscriptionEngine, gen: Int) {
        e.setFailureHandler { [weak self] msg in
            guard let self else { return }
            self.lock.withLockUnchecked {
                if self.activeGen == gen, self.pendingFailure == nil { self.pendingFailure = msg }
            }
        }
    }

    private func takeFailure() -> String? {
        lock.withLockUnchecked { let f = pendingFailure; pendingFailure = nil; return f }
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        let e = lock.withLockUnchecked { active }
        watch(e, gen: 0)
        let (first, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await e.start(input: first, onResult: onResult)
        let task = Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { cont.finish(); return }
            await self.route(input: input, first: cont, onResult: onResult)
        }
        lock.withLockUnchecked { router = task }
    }

    private func route(input: AsyncStream<AnalyzerInput>, first: AsyncStream<AnalyzerInput>.Continuation,
                       onResult: @escaping @Sendable (EngineResult) -> Void) async {
        var cont: AsyncStream<AnalyzerInput>.Continuation? = first
        var fed: TimeInterval = 0                 // audio seconds handed on so far (the failure point's offset)
        var target: AVAudioFormat?                // the fallback's format, when it differs from the input's
        var converter: AVAudioConverter?
        var converterRate: Double = 0
        for await item in input {
            if let msg = takeFailure(), !lock.withLockUnchecked({ gaveUp_ }) {
                cont?.finish()
                cont = nil
                let next = await recover(from: msg, at: fed, onResult: onResult)
                cont = next?.cont
                target = next?.target
                converter = nil
                converterRate = 0
            }
            let rate = item.buffer.format.sampleRate
            guard rate > 0 else { continue }
            fed += Double(item.buffer.frameLength) / rate
            guard let c = cont else { continue }      // no recognizer left: drain
            guard let target else { c.yield(item); continue }
            let samples = PCMSamples.mono(item.buffer)
            if converterRate != rate {
                converter = try? ChannelPipeline.makeConverter(from: rate, to: target)
                converterRate = rate
            }
            if let buf = try? ChannelPipeline.convert(samples, sampleRate: rate, to: target, with: converter) {
                c.yield(AnalyzerInput(buffer: buf))
            }
        }
        cont?.finish()
    }

    private func retire(_ e: any TranscriptionEngine) {
        let t = Task.detached { await e.cancel() }
        lock.withLockUnchecked { retiring.append(t) }
    }

    /// Replaces the failed engine. nil: no recognizer left (gave up).
    private func recover(from msg: String, at shift: TimeInterval,
                         onResult: @escaping @Sendable (EngineResult) -> Void) async
        -> (cont: AsyncStream<AnalyzerInput>.Continuation, target: AVAudioFormat?)? {
        let (failed, sink, done, inFormat) = lock.withLockUnchecked { (active, status, recoveries_, inputFormat) }
        let failedName = failed.engineName
        retire(failed)
        func giveUp(_ why: String) {
            lock.withLockUnchecked { gaveUp_ = true }
            if Task.isCancelled { return }          // the session is shutting down: not a call problem
            report(.speechFailed(channel, why))
            sink(ListenStatus(state: "engine_failed", channel: channel, engine: failedName, reason: why, switchAtSec: shift))
        }
        guard done < maxRecoveries else {
            giveUp("\(msg); gave up after \(done) restart\(done == 1 ? "" : "s")")
            return nil
        }
        let gen = lock.withLockUnchecked { () -> Int in recoveries_ += 1; activeGen += 1; return activeGen }
        let fb: any TranscriptionEngine
        do { fb = try makeFallback() } catch {
            giveUp("\(msg); no fallback engine: \(error)")
            return nil
        }
        do {
            fb.attach(channel: channel, status: sink)
            let fmt = try await fb.prepare()
            watch(fb, gen: gen)
            let (fin, fcont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            try await fb.start(input: fin) { r in
                var r = r
                r.start += shift
                r.end += shift
                onResult(r)
            }
            lock.withLockUnchecked { active = fb }
            report(.speechRecovered(channel, "\(failedName) failed (\(msg)); \(fb.engineName) took over at \(String(format: "%.1f", shift)) s"))
            sink(ListenStatus(state: "engine_fallback", channel: channel, engine: fb.engineName, from: failedName,
                              reason: "recognizer failed mid-call: \(msg)", switchAtSec: shift))
            return (fcont, inFormat.map { $0 == fmt } ?? false ? nil : fmt)
        } catch {
            retire(fb)
            giveUp("\(msg); fallback \(fb.engineName) did not start: \(error)")
            return nil
        }
    }

    func finish() async throws {
        let r = lock.withLockUnchecked { router }
        await r?.value
        let (e, ts, dead) = lock.withLockUnchecked { (active, retiring, gaveUp_) }
        for t in ts { await t.value }
        if dead { return }                          // the active engine failed and was already retired
        try await e.finish()
    }

    func cancel() async {
        let r = lock.withLockUnchecked { router }
        r?.cancel()
        await r?.value                              // a replacement in progress lands in `active` before it is cancelled
        let (e, dead) = lock.withLockUnchecked { (active, gaveUp_) }
        if !dead { await e.cancel() }
        for t in lock.withLockUnchecked({ retiring }) { await t.value }
    }
}
