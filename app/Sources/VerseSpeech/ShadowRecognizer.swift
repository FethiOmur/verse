@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import VerseAudio

/// A final or volatile result of the shadow recognizer, with run-session times (like `TranscriptEvent`).
public struct ShadowResult: Sendable, Equatable {
    public var channel: Channel
    /// The candidate language the shadow recognizer ran in.
    public var lang: String
    public var text: String
    public var isFinal: Bool
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double?

    public init(channel: Channel, lang: String, text: String, isFinal: Bool, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
        self.channel = channel
        self.lang = lang
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// What a shadow recognizer needs: which languages to try and where its results go.
public struct ShadowConfig: Sendable {
    /// Candidate languages, most likely first. One recognizer runs at a time and the list is rotated.
    public var candidates: [String]
    /// A candidate listens to this much audio before the next one takes over (when there is a next one).
    public var slotSeconds: Double = 12
    /// A hinted candidate (see `ShadowRecognizer.prefer`) takes over once the current one has listened this long.
    public var preferAfterSeconds: Double = 3
    /// Review S7: a candidate whose recognizer could not be prepared or started waits this many seconds of audio before it is
    /// tried again...
    public var retryAfterSeconds: Double = 30
    /// ...and is left out for the rest of the call after this many failures in a row (or at once when no engine can even be
    /// made for it).
    public var maxStartFailures: Int = 3
    public var onResult: @Sendable (ShadowResult) -> Void
    /// Diagnostics (a candidate that cannot be loaded, a rotation). nil: dropped.
    public var log: (@Sendable (String) -> Void)?

    public init(candidates: [String], onResult: @escaping @Sendable (ShadowResult) -> Void) {
        self.candidates = candidates
        self.onResult = onResult
    }
}

/// One lightweight recognizer for a candidate language, running on the same audio as a channel's main recognizer. Its text is
/// only evidence for the language detector (`AutoLanguageDetector`); nothing it hears reaches the turn engine or the brain.
///
/// One candidate listens at a time (the Apple engines run out of process, one analyzer each) and the candidates take turns
/// every `slotSeconds`: a hint from the main recognizer's garbled text can bring one forward. The pipeline calls `feed` with the
/// same samples it gives the main recognizer; the audio is converted for the candidate's own format here.
final class ShadowRecognizer: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let lang: String
        let engine: any TranscriptionEngine
        let format: AVAudioFormat
        let input: AsyncStream<AnalyzerInput>.Continuation
        var converter: AVAudioConverter?
        var rate: Double = 0
        var origin: TimeInterval?
        var seconds = 0.0
        init(lang: String, engine: any TranscriptionEngine, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
            self.lang = lang
            self.engine = engine
            self.format = format
            self.input = input
        }
    }

    private enum Phase { case idle, preparing, active(Slot), stopped }

    private let channel: Channel
    private let config: ShadowConfig
    private let makeEngine: @Sendable (String) throws -> any TranscriptionEngine
    private let lock = OSAllocatedUnfairLock()
    private var phase = Phase.idle
    private var order: [String]
    private var cursor = 0
    private var preferred: String?
    /// Left out for the rest of the call.
    private var excluded: Set<String> = []
    /// Failures in a row per candidate, and the session time before which a failed one is not tried again.
    private var failures: [String: Int] = [:]
    private var retryAt: [String: TimeInterval] = [:]
    /// Session time of the newest sample fed (the clock the retry delay runs on).
    private var lastFeedEnd: TimeInterval = 0
    /// Audio seconds fed to candidates in total, for diagnostics.
    private(set) var audioSeconds = 0.0
    private(set) var slotsStarted = 0

    init(channel: Channel, config: ShadowConfig, makeEngine: @escaping @Sendable (String) throws -> any TranscriptionEngine) {
        self.channel = channel
        self.config = config
        self.makeEngine = makeEngine
        self.order = config.candidates
    }

    /// Candidates that may listen at session time `now`: not left out and not waiting out a failure.
    private func usable(now: TimeInterval) -> [String] {
        order.filter { !excluded.contains($0) && (retryAt[$0].map { $0 <= now } ?? true) }
    }

    /// The candidate to listen to next: a hinted one, else the next in the rotation.
    private func nextLang(now: TimeInterval) -> String? {
        let usable = usable(now: now)
        guard !usable.isEmpty else { return nil }
        if let p = preferred, usable.contains(p) { preferred = nil; return p }
        preferred = nil
        let l = usable[cursor % usable.count]
        cursor += 1
        return l
    }

    /// The main recognizer's text looks like `lang`: look at it next (soon, when another candidate is listening).
    func prefer(_ lang: String) {
        lock.withLockUnchecked {
            guard order.contains(lang), !excluded.contains(lang) else { return }
            preferred = lang
        }
    }

    /// Called from the pipeline's feeder for every stretch of samples it gives the main recognizer. `endTime` is the session
    /// time just after the last sample.
    func feed(_ samples: [Float], rate: Double, endTime: TimeInterval) {
        guard !samples.isEmpty, rate > 0 else { return }
        enum Action { case none, start(String), rotate(Slot) }
        let action: Action = lock.withLockUnchecked {
            lastFeedEnd = endTime
            switch phase {
            case .stopped, .preparing: return .none
            case .idle:
                guard let l = nextLang(now: endTime) else { return .none }
                phase = .preparing
                return .start(l)
            case .active(let slot):
                if slot.origin == nil { slot.origin = endTime - Double(samples.count) / rate }
                if slot.converter == nil || slot.rate != rate {
                    slot.converter = try? ChannelPipeline.makeConverter(from: rate, to: slot.format)
                    slot.rate = rate
                }
                if let buf = try? ChannelPipeline.convert(samples, sampleRate: rate, to: slot.format, with: slot.converter) {
                    slot.input.yield(AnalyzerInput(buffer: buf))
                }
                let dt = Double(samples.count) / rate
                slot.seconds += dt
                audioSeconds += dt
                let others = usable(now: endTime).filter { $0 != slot.lang }
                let due = slot.seconds >= config.slotSeconds
                let hinted = preferred.map { $0 != slot.lang && slot.seconds >= config.preferAfterSeconds } ?? false
                if !others.isEmpty, due || hinted {
                    phase = .idle
                    return .rotate(slot)
                }
                return .none
            }
        }
        switch action {
        case .none: break
        case .start(let lang): startSlot(lang)
        case .rotate(let slot): retire(slot)
        }
    }

    private func startSlot(_ lang: String) {
        let channel = self.channel, cfg = self.config
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let engine: any TranscriptionEngine
            do {
                engine = try self.makeEngine(lang)
            } catch {
                // No engine can be made for this language (not supported here): trying again would fail the same way.
                cfg.log?("shadow \(lang) unavailable: \(error)")
                self.slotFailed(lang, permanent: true)
                return
            }
            var input: AsyncStream<AnalyzerInput>.Continuation?
            do {
                let format = try await engine.prepare()
                let (inputs, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
                input = cont
                let slot = Slot(lang: lang, engine: engine, format: format, input: cont)
                try await engine.start(input: inputs) { [weak slot] r in
                    guard let slot else { return }
                    let origin = self.lock.withLockUnchecked { slot.origin } ?? 0
                    cfg.onResult(ShadowResult(channel: channel, lang: lang, text: r.text, isFinal: r.isFinal,
                                              start: origin + r.start, end: origin + r.end, confidence: r.confidence))
                }
                let stopped = self.lock.withLockUnchecked { () -> Bool in
                    self.failures[lang] = nil
                    self.retryAt[lang] = nil
                    if case .stopped = self.phase { return true }
                    self.phase = .active(slot)
                    self.slotsStarted += 1
                    return false
                }
                if stopped { cont.finish(); await engine.cancel() }
            } catch {
                // Review S7: a recognizer that was made (and maybe prepared) but did not start is released, and one failure
                // only benches the language for a while.
                input?.finish()
                await engine.cancel()
                cfg.log?("shadow \(lang) failed to start: \(error)")
                self.slotFailed(lang, permanent: false)
            }
        }
    }

    /// A candidate could not listen: left out for good (`permanent`, or too many failures in a row), else benched for
    /// `retryAfterSeconds` of audio. The shadow goes back to idle, so the next feed picks a candidate.
    private func slotFailed(_ lang: String, permanent: Bool) {
        lock.withLockUnchecked {
            let n = (failures[lang] ?? 0) + 1
            failures[lang] = n
            if permanent || n >= config.maxStartFailures {
                excluded.insert(lang)
                retryAt[lang] = nil
            } else {
                retryAt[lang] = lastFeedEnd + config.retryAfterSeconds
            }
            if case .stopped = phase {} else { phase = .idle }
        }
    }

    /// For tests: candidates left out for the rest of the call.
    var excludedLanguages: Set<String> { lock.withLockUnchecked { excluded } }

    /// Ends a slot: its input finishes, the engine flushes (its last finals are still delivered), then it is released.
    private func retire(_ slot: Slot) {
        Task.detached(priority: .utility) {
            slot.input.finish()
            try? await slot.engine.finish()
        }
    }

    func stop() async {
        let slot: Slot? = lock.withLockUnchecked {
            defer { phase = .stopped }
            if case .active(let s) = phase { return s }
            return nil
        }
        guard let slot else { return }
        slot.input.finish()
        await slot.engine.cancel()
    }
}
