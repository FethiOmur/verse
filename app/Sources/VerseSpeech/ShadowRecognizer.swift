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
    private var failed: Set<String> = []
    /// Audio seconds fed to candidates in total, for diagnostics.
    private(set) var audioSeconds = 0.0
    private(set) var slotsStarted = 0

    init(channel: Channel, config: ShadowConfig, makeEngine: @escaping @Sendable (String) throws -> any TranscriptionEngine) {
        self.channel = channel
        self.config = config
        self.makeEngine = makeEngine
        self.order = config.candidates
    }

    /// The candidate to listen to next: a hinted one, else the next in the rotation.
    private func nextLang() -> String? {
        let usable = order.filter { !failed.contains($0) }
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
            guard order.contains(lang), !failed.contains(lang) else { return }
            preferred = lang
        }
    }

    /// Called from the pipeline's feeder for every stretch of samples it gives the main recognizer. `endTime` is the session
    /// time just after the last sample.
    func feed(_ samples: [Float], rate: Double, endTime: TimeInterval) {
        guard !samples.isEmpty, rate > 0 else { return }
        enum Action { case none, start(String), rotate(Slot) }
        let action: Action = lock.withLockUnchecked {
            switch phase {
            case .stopped, .preparing: return .none
            case .idle:
                guard let l = nextLang() else { return .none }
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
                let others = order.filter { !failed.contains($0) && $0 != slot.lang }
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
            do {
                let engine = try self.makeEngine(lang)
                let format = try await engine.prepare()
                let (inputs, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
                let slot = Slot(lang: lang, engine: engine, format: format, input: cont)
                try await engine.start(input: inputs) { [weak slot] r in
                    guard let slot else { return }
                    let origin = self.lock.withLockUnchecked { slot.origin } ?? 0
                    cfg.onResult(ShadowResult(channel: channel, lang: lang, text: r.text, isFinal: r.isFinal,
                                              start: origin + r.start, end: origin + r.end, confidence: r.confidence))
                }
                let stopped = self.lock.withLockUnchecked { () -> Bool in
                    if case .stopped = self.phase { return true }
                    self.phase = .active(slot)
                    self.slotsStarted += 1
                    return false
                }
                if stopped { cont.finish(); await engine.cancel() }
            } catch {
                cfg.log?("shadow \(lang) unavailable: \(error)")
                self.lock.withLockUnchecked {
                    self.failed.insert(lang)
                    if case .stopped = self.phase {} else { self.phase = .idle }
                }
            }
        }
    }

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
