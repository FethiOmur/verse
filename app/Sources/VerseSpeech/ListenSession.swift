import Foundation
import os
import VerseAudio

/// Live (or replayed) two-channel transcription: remote = the meeting app's process tap, me = the microphone.
/// No audio is written anywhere; only text and timings leave this type.
public actor ListenSession {
    public let config: ListenConfig
    private let environment: ListenEnvironment
    private var pipelines: [Channel: ChannelPipeline] = [:]
    private var clock = SessionClock()
    private var started = false
    private var prepared = false
    private var watchdog: Task<Void, Never>?
    private var lifecycle: Task<Void, Never>?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private let counters = Counters()

    /// Runtime problems (dead stream, permission revoked). Startup problems are thrown by `start()` instead.
    public nonisolated let issues: AsyncStream<ListenError>
    private let issueContinuation: AsyncStream<ListenError>.Continuation

    public init(config: ListenConfig) {
        self.init(config: config, environment: .system)
    }

    public init(config: ListenConfig, environment: ListenEnvironment) {
        self.config = config
        self.environment = environment
        (issues, issueContinuation) = AsyncStream.makeStream(of: ListenError.self, bufferingPolicy: .unbounded)
    }

    /// Session time of the first sample of each channel (recognizer time 0 maps to this).
    public func channelOrigin(_ channel: Channel) -> TimeInterval? { pipelines[channel]?.originTime }

    /// Route used per channel, for logs.
    public func routes() -> [Channel: String] { pipelines.mapValues { $0.source.routeDescription } }

    public func engineNames() -> [Channel: String] { pipelines.mapValues { $0.engine.engineName } }

    /// Loudness numbers for the last `window` seconds per channel (no audio): RMS in dBFS (nil = no signal or
    /// exact silence) and the total chunk count so far (a count that stops growing means no callbacks).
    public struct Level: Sendable {
        public var rmsDbfs: Double?
        public var peakBinDbfs: Double?
        public var chunksTotal: Int
    }

    public func levels(window: TimeInterval = 1.0) -> [Channel: Level] {
        let now = clock.now()
        let b1 = EnvelopeTrack.bin(now), b0 = EnvelopeTrack.bin(now - window)
        return pipelines.mapValues { p in
            let bins = p.envelope.rms(fromBin: b0, toBin: b1)
            let ms = bins.isEmpty ? 0 : bins.map { $0 * $0 }.reduce(0, +) / Double(bins.count)
            let peak = bins.max() ?? 0
            func db(_ x: Double) -> Double? { x > 0 ? ((20 * log10(x)) * 10).rounded() / 10 : nil }
            return Level(rmsDbfs: db(ms.squareRoot()), peakBinDbfs: db(peak), chunksTotal: p.chunksReceived)
        }
    }

    /// `.me` results discarded by the bleed gate so far.
    public nonisolated var droppedEchoEvents: Int { counters.dropped }

    /// What the bleed gate discarded (text and times only), oldest first.
    public nonisolated var droppedEchoLog: [DroppedEcho] { counters.log }

    /// Every `.me` result the gate measured (kept or dropped), oldest first. Numbers and text only; for tuning the gate.
    public nonisolated var gateDecisions: [GateDecision] { counters.decisions }

    /// The session clock's "now" (seconds since `start()`).
    public func now() -> TimeInterval { clock.now() }

    /// Everything `start()` needs that takes time and opens no audio: the permissions, the sources (made, not started) and the
    /// recognizers (model loaded). Idempotent. A mid-call route or language switch calls it while the old session still
    /// listens, so the gap between the two is the old one's flush and the new sources' start, not a model load; a failure
    /// here leaves the old session untouched.
    public func prepare() async throws {
        guard !prepared else { return }
        // Permissions first, so "denied" is never confused with silence.
        let perms = environment.permissions
        let remoteSource = try environment.makeRemoteSource(config)
        let micSource = try environment.makeMicSource(config)
        if config.remoteIsTap, remoteSource != nil, perms.status(.audioCapture) == .denied {
            throw ListenError.permissionDenied(.audioCapture)
        }
        // The room route's microphone is the remote source; every other route's is the `me` source.
        if config.usesRealMic, micSource != nil || (config.micAsRemote && remoteSource != nil) {
            var s = perms.status(.microphone)
            if s == .notDetermined { s = await perms.request(.microphone) }
            if s == .denied { throw ListenError.permissionDenied(.microphone) }
        }

        var built: [Channel: ChannelPipeline] = [:]
        let sink = config.statusSink
        let issueCont = issueContinuation
        let env = environment, base = config
        // Review H8: every channel's recognizer is wrapped so a mid-call failure is reported and the language's Apple engine
        // takes over from that point instead of the channel going silent.
        func makeEngine(for channel: Channel) throws -> any TranscriptionEngine {
            let primary = try environment.makeEngine(config)
            let engine = RecoveringEngine(primary: primary, channel: channel, makeFallback: {
                var c = base
                c.engineKind = EngineFactory.defaultKind(for: base.lang)
                return try env.makeEngine(c)
            }, report: { issueCont.yield($0) })
            engine.attach(channel: channel, status: { sink?($0) })
            return engine
        }
        if let s = remoteSource {
            built[.remote] = ChannelPipeline(channel: .remote, source: s, engine: try makeEngine(for: .remote))
        }
        if let s = micSource {
            built[.me] = ChannelPipeline(channel: .me, source: s, engine: try makeEngine(for: .me))
        }
        do {
            for p in built.values { try await p.prepare() }
        } catch {
            for p in built.values { await p.engine.cancel() }
            throw error
        }
        pipelines = built
        prepared = true
    }

    /// Drops a session that was prepared and never started (a switch that was given up): the recognizers are released.
    public func discardPrepared() async {
        guard prepared, !started else { return }
        prepared = false
        for p in pipelines.values { await p.engine.cancel() }
        pipelines = [:]
    }

    public func start() async throws -> AsyncStream<TranscriptEvent> {
        guard !started else { throw ListenError.alreadyStarted }
        try await prepare()
        started = true
        let built = pipelines
        let perms = environment.permissions

        let (stream, cont) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
        eventContinuation = cont
        clock = SessionClock()
        let clock = self.clock
        let lang = config.lang
        let gate = config.bleedGate
        let counters = self.counters
        let remoteEnvelope = built[.remote]?.envelope
        let roomRoute = config.micAsRemote
        let issueCont = issueContinuation

        for (channel, p) in built {
            let micEnvelope = p.envelope
            do {
                try await p.start(clock: clock, onIssue: { issueCont.yield($0) }) { r, origin in
                    let event = TranscriptEvent(channel: channel, text: r.text, isFinal: r.isFinal,
                                                audioStart: origin + r.start, audioEnd: origin + r.end,
                                                emittedAt: clock.now(), lang: lang, confidence: r.confidence)
                    if channel == .me, let remoteEnvelope,
                       let f = gate.features(mic: micEnvelope, remote: remoteEnvelope, start: event.audioStart, end: event.audioEnd) {
                        let verdict = gate.verdict(f)
                        counters.addDecision(GateDecision(text: event.text, isFinal: event.isFinal, audioStart: event.audioStart,
                                                          audioEnd: event.audioEnd, emittedAt: event.emittedAt, features: f, verdict: verdict))
                        if verdict == .drop {
                            counters.addDropped(DroppedEcho(text: event.text, isFinal: event.isFinal, audioStart: event.audioStart,
                                                            audioEnd: event.audioEnd, emittedAt: event.emittedAt, score: f.score))
                            return
                        }
                    }
                    cont.yield(event)
                }
            } catch {
                for q in built.values { q.stopSource() }
                // Review S1: the recognizers are released too. `discardPrepared()` cannot do it (the session counts as
                // started) and nothing else would: each failed start used to keep a Nemotron model (~600 MB) claimed.
                for q in built.values { await q.engine.cancel() }
                cont.finish()
                throw error
            }
        }

        let pipelinesList = Array(built.values)
        watchdog = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { break }
                for p in pipelinesList where p.checkHealth(now: clock.now()) == .dead {
                    let kind: PermissionKind = p.channel == .remote && !roomRoute ? .audioCapture : .microphone
                    issueCont.yield(perms.status(kind) == .denied ? .permissionDenied(kind) : .deadStream(p.channel))
                }
            }
        }
        lifecycle = Task.detached {
            await withTaskGroup(of: Void.self) { g in
                for p in pipelinesList { g.addTask { await p.waitUntilDone() } }
            }
            cont.finish()
        }
        return stream
    }

    /// Starts (or, with nil, stops) the shadow recognizer of the remote channel: a lightweight recognizer for a candidate
    /// language on the same audio, whose finals go to `config.onResult` (interim AUTO language, spec 2.5). The room route's
    /// microphone is the remote channel, so it is shadowed too. Safe to call at any time after `start()`.
    public func setShadow(_ shadow: ShadowConfig?) async {
        guard let p = pipelines[.remote] else { return }
        if let old = p.takeShadow() { await old.stop() }
        guard let shadow else { return }
        let base = config, env = environment
        p.setShadow(ShadowRecognizer(channel: .remote, config: shadow, makeEngine: { lang in
            var c = base
            c.lang = lang
            c.engineKind = EngineFactory.defaultKind(for: lang)    // the Apple engine: no model load, no extra GB
            return try env.makeEngine(c)
        }))
    }

    /// The main recognizer's text looks like `lang`: the shadow recognizer looks at it next.
    public func preferShadow(_ lang: String) {
        pipelines[.remote]?.shadowRecognizer()?.prefer(lang)
    }

    /// Stops capture, flushes the recognizers (pending finals are still delivered), then ends the event stream.
    public func stop() async {
        await setShadow(nil)
        for p in pipelines.values { p.stopSource() }
        await lifecycle?.value
        watchdog?.cancel()
        await watchdog?.value
        watchdog = nil
        eventContinuation?.finish()
        issueContinuation.finish()
        // Review S5: this session's recognizers gave their models back above. In the background (stop() never waits on it):
        // after a swap the new session holds its own, so only the old ones go; at the end of a call, all of them.
        if config.releaseIdleModelsOnStop {
            Task.detached(priority: .utility) { await NemotronModel.unloadIdle() }
        }
    }

    /// Waits for finite sources (file, memory) to finish and the recognizers to flush.
    public func waitUntilFinished() async {
        await lifecycle?.value
        watchdog?.cancel()
        issueContinuation.finish()
    }
}

/// One `.me` result the bleed gate discarded as an echo of the remote channel.
public struct DroppedEcho: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var audioStart: TimeInterval
    public var audioEnd: TimeInterval
    public var emittedAt: TimeInterval
    /// Envelope correlation with the remote channel that made the gate drop it.
    public var score: Double
}

/// One `.me` result the gate measured, and what it decided.
public struct GateDecision: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var audioStart: TimeInterval
    public var audioEnd: TimeInterval
    public var emittedAt: TimeInterval
    public var features: GateFeatures
    public var verdict: BleedGate.Verdict
}

/// Review S10: the gate logs keep the newest `maxLog` entries each (every volatile `me` result is a decision, so a long call
/// used to grow them without bound). The drop count stays the total.
final class Counters: @unchecked Sendable {
    let maxLog: Int
    private let lock = OSAllocatedUnfairLock()
    private var dropped_: [DroppedEcho] = []
    private var droppedTotal = 0
    private var decisions_: [GateDecision] = []

    init(maxLog: Int = 4000) { self.maxLog = max(1, maxLog) }

    var decisions: [GateDecision] { lock.withLockUnchecked { Array(decisions_.suffix(maxLog)) } }
    func addDecision(_ d: GateDecision) { lock.withLockUnchecked { decisions_.append(d); Self.trim(&decisions_, to: maxLog) } }
    var dropped: Int { lock.withLockUnchecked { droppedTotal } }
    var log: [DroppedEcho] { lock.withLockUnchecked { Array(dropped_.suffix(maxLog)) } }
    func addDropped(_ d: DroppedEcho) {
        lock.withLockUnchecked { droppedTotal += 1; dropped_.append(d); Self.trim(&dropped_, to: maxLog) }
    }

    /// What is held in memory (tests): never more than the cap plus one batch.
    var storedCounts: (decisions: Int, dropped: Int) { lock.withLockUnchecked { (decisions_.count, dropped_.count) } }

    /// Drops the oldest entries in batches (a quarter of the cap at a time), so appending stays cheap.
    private static func trim<T>(_ a: inout [T], to cap: Int) {
        if a.count > cap + max(1, cap / 4) { a.removeFirst(a.count - cap) }
    }
}
