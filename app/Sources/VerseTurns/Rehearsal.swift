@preconcurrency import AVFoundation
import Foundation
import os
import Speech
import VerseAudio
import VerseSpeech

// Rehearse a line: a sentence typed (or sent by a script) as "them" or "me" enters a running session exactly where recognised
// speech enters. The listen session is the real `ListenSession`, built from a `ListenEnvironment` whose sources deliver silence
// (no microphone, no process tap) and whose recognizers say the typed lines instead of transcribing audio. Everything after the
// recognizer is the real thing: the channel pipeline's time base, the `TurnEngine` (cue, kind, addressee, bank matcher, chips),
// the partial and turn lines to the real brain process, and the brain's events back to the island.

/// Who says a rehearsed line.
public enum RehearsalSpeaker: String, Sendable, CaseIterable, Equatable {
    /// The other side: the remote channel (the meeting app's audio in a real call).
    case them
    /// The owner: the `me` channel (the microphone in a real call).
    case me

    public var channel: Channel { self == .them ? .remote : .me }
}

/// The typed lines of one rehearsal and the stand-in recognizers that say them. One feed per rehearsal session; the listen
/// session's recognizers register with it as they start (a route switch starts new ones, which take over).
public final class RehearsalFeed: @unchecked Sendable {
    /// The pause between two growing partials of a line, and before its final, in seconds.
    public let stepSeconds: Double
    /// At most this many growing partials per line (long lines grow by several words at a time).
    public static let maxPartials = 6

    private let lock = OSAllocatedUnfairLock()
    private var engines: [Channel: RehearsalEngine] = [:]
    /// Lines said before the channel's recognizer was listening; they are spoken as soon as it is.
    private var pending: [Channel: [String]] = [:]
    private var sourcesMade_: [String] = []

    public init(stepSeconds: Double = 0.18) { self.stepSeconds = stepSeconds }

    /// What the rehearsal's listen sessions were built from (route descriptions), for tests and the log.
    public var sourcesMade: [String] { lock.withLockUnchecked { sourcesMade_ } }

    /// Whether a recognizer listens on the channel now (a line said before that is held, not lost).
    public func isListening(_ speaker: RehearsalSpeaker) -> Bool { lock.withLockUnchecked { engines[speaker.channel] != nil } }

    /// Says `text` as `speaker`: a few growing partials, then the final, as a streaming recognizer delivers a sentence. Before the
    /// channel listens the line is held and said when it does. Empty text is ignored.
    public func say(_ speaker: RehearsalSpeaker, _ text: String) {
        let line = Self.clean(text)
        guard !line.isEmpty else { return }
        let engine = lock.withLockUnchecked { () -> RehearsalEngine? in
            if let e = engines[speaker.channel] { return e }
            pending[speaker.channel, default: []].append(line)
            return nil
        }
        engine?.speak(line)
    }

    /// The text of a line as it is said: whitespace runs (newlines included) become one space.
    public static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The growing word prefixes a line is said in (the last one is the whole line), before its final.
    public static func partialPlan(_ text: String) -> [String] {
        let words = clean(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let n = min(words.count, maxPartials)
        var out: [String] = []
        for i in 1...n {
            let k = Int((Double(i * words.count) / Double(n)).rounded(.up))
            let prefix = words[..<min(k, words.count)].joined(separator: " ")
            if out.last != prefix { out.append(prefix) }
        }
        return out
    }

    /// The recognizer results a line becomes when it starts at recognizer time `start`: the partials of `partialPlan`, one every
    /// `step` seconds, then the final `step` later. A stand-in recognizer in a test can play these to compare a typed line with
    /// the same text recognised.
    public static func results(for text: String, start: Double, step: Double) -> [EngineResult] {
        let plan = partialPlan(text)
        guard let last = plan.last else { return [] }
        var out = plan.enumerated().map { i, p in EngineResult(text: p, isFinal: false, start: start, end: start + step * Double(i + 1)) }
        out.append(EngineResult(text: last, isFinal: true, start: start, end: start + step * Double(plan.count + 1)))
        return out
    }

    /// The listen environment of a rehearsal: silent sources on both channels, recognizers that say this feed's lines, and
    /// permissions that read as granted (nothing is captured, so no permission is asked for).
    public func environment() -> ListenEnvironment {
        ListenEnvironment(
            permissions: FixedPermissions(),
            makeRemoteSource: { [weak self] cfg in
                let s = RehearsalSilenceSource(label: cfg.micAsRemote ? "room" : "them")
                self?.noteSource(s.routeDescription)
                return s
            },
            makeMicSource: { [weak self] cfg in
                // The room route has one channel only, as with real audio.
                if cfg.micAsRemote { return nil }
                let s = RehearsalSilenceSource(label: "me")
                self?.noteSource(s.routeDescription)
                return s
            },
            makeEngine: { [weak self] cfg in RehearsalEngine(lang: cfg.lang, feed: self) })
    }

    /// Makes `options` a rehearsal run: this feed's environment instead of the microphone and the process tap, no interim AUTO
    /// language (a typed line has no audio to judge), and listening until stopped.
    public func apply(to options: inout RunOptions) {
        options.listenEnvironment = environment()
        options.source = .live
        options.file = nil
        options.micWithFile = false
        options.autoLanguage = false
        options.autoShadow = false
        options.waitForBrainBeforeListening = false
        if options.seconds == nil { options.seconds = 12 * 3600 }
    }

    private func noteSource(_ s: String) { lock.withLockUnchecked { sourcesMade_.append(s) } }

    fileprivate func register(_ engine: RehearsalEngine, channel: Channel) {
        let held = lock.withLockUnchecked { () -> [String] in
            engines[channel] = engine
            return pending.removeValue(forKey: channel) ?? []
        }
        for line in held { engine.speak(line) }
    }

    fileprivate func unregister(_ engine: RehearsalEngine, channel: Channel) {
        lock.withLockUnchecked { if engines[channel] === engine { engines[channel] = nil } }
    }
}

/// Exact silence at real-time pace (10 ms chunks at 48 kHz, a capture device's rate) until stopped: the channel pipeline keeps
/// its clock, its conversion and its time base as with real audio. Nothing is captured and nothing is written. It reports no app
/// output, so the silence reads as quiet, never as a dead stream.
final class RehearsalSilenceSource: AudioCaptureSource, @unchecked Sendable {
    /// A device rate, not the recognizer's: the pipeline converts as it does for a real source.
    static let sampleRate = 48000.0
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Never>?
    let label: String

    init(label: String) { self.label = label }

    var routeDescription: String { "rehearsal (\(label), silence)" }
    func targetIsProducingOutput() -> Bool? { false }

    func start(clock: SessionClock, onChunk: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable () -> Void) throws {
        let t0 = clock.now()
        let n = Int(Self.sampleRate / 100)
        let t = Task.detached(priority: .userInitiated) {
            let cc = ContinuousClock()
            let base = cc.now
            var i = 0
            while !Task.isCancelled {
                try? await cc.sleep(until: base + .seconds(Double(i + 1) * 0.01))
                if Task.isCancelled { break }
                onChunk(AudioChunk(samples: [Float](repeating: 0, count: n), sampleRate: Self.sampleRate, startTime: t0 + Double(i) * 0.01))
                i += 1
            }
        }
        lock.withLockUnchecked { task = t }
    }

    func stop() {
        let t = lock.withLockUnchecked { () -> Task<Void, Never>? in let t = task; task = nil; return t }
        t?.cancel()
    }
}

/// A recognizer that ignores its (silent) input except to keep the time base, and says the feed's lines on its channel. Results
/// carry recognizer times like a real one's: a line starts where the audio fed so far ends, and each partial ends at the audio
/// fed when it is said.
final class RehearsalEngine: TranscriptionEngine, @unchecked Sendable {
    let lang: String
    let engineName = "rehearsal"
    private weak var feed: RehearsalFeed?
    private let step: Double
    private let lock = OSAllocatedUnfairLock()
    private var channel: Channel?
    private var fed = 0.0
    private var onResult: (@Sendable (EngineResult) -> Void)?
    private var reader: Task<Void, Never>?
    private var speaker: Task<Void, Never>?
    private let lines: AsyncStream<String>
    private let linesCont: AsyncStream<String>.Continuation

    init(lang: String, feed: RehearsalFeed?) {
        self.lang = lang
        self.feed = feed
        step = feed?.stepSeconds ?? 0.18
        (lines, linesCont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    func attach(channel: Channel, status: @escaping @Sendable (ListenStatus) -> Void) {
        lock.withLockUnchecked { self.channel = channel }
    }

    /// 16 kHz 16-bit mono, the format Apple's analyzer asks for. Not Float32: on macOS 27 `AnalyzerInput(buffer:)` traps on a
    /// Float32 buffer (measured with a probe binary: Int16 passes, Float32 ends in SIGTRAP).
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    func prepare() async throws -> AVAudioFormat { Self.format }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        lock.withLockUnchecked { self.onResult = onResult }
        reader = Task.detached { [weak self] in
            for await item in input {
                let seconds = Double(item.buffer.frameLength) / item.buffer.format.sampleRate
                self?.lock.withLockUnchecked { self?.fed += seconds }
            }
        }
        let lines = self.lines, step = self.step
        speaker = Task.detached { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.say(line, step: step)
            }
        }
        if let ch = lock.withLockUnchecked({ channel }) { feed?.register(self, channel: ch) }
    }

    func speak(_ line: String) { linesCont.yield(line) }

    private var fedNow: Double { lock.withLockUnchecked { fed } }

    private func emit(_ r: EngineResult) {
        let cb = lock.withLockUnchecked { onResult }
        cb?(r)
    }

    /// One line: the growing partials, then the final. Not cut short by the end of input, so a line that is being said when the
    /// call stops still arrives whole.
    private func say(_ line: String, step: Double) async {
        let plan = RehearsalFeed.partialPlan(line)
        guard let last = plan.last else { return }
        let start = fedNow
        for p in plan {
            try? await Task.sleep(for: .seconds(step))
            emit(EngineResult(text: p, isFinal: false, start: start, end: max(fedNow, start + 0.05)))
        }
        try? await Task.sleep(for: .seconds(step))
        emit(EngineResult(text: last, isFinal: true, start: start, end: max(fedNow, start + 0.05)))
    }

    func finish() async throws {
        if let ch = lock.withLockUnchecked({ channel }) { feed?.unregister(self, channel: ch) }
        await reader?.value
        linesCont.finish()
        await speaker?.value
    }

    func cancel() async {
        if let ch = lock.withLockUnchecked({ channel }) { feed?.unregister(self, channel: ch) }
        linesCont.finish()
        reader?.cancel()
        speaker?.cancel()
    }
}

/// Where a rehearsal session runs: a copy of the prepared session folder in the temporary directory, so the brain's
/// `events.jsonl` and `summary.md` and the run's `transcript.jsonl` go there and the prepared folder is never written.
public enum RehearsalWorkspace {
    /// The name prefix of every workspace folder under the temporary directory.
    public static let prefix = "verse-rehearsal-"

    /// Copies `sessionDir` to `<tmp>/verse-rehearsal-<uuid>/<session name>/` and returns the copy (same folder name, so the
    /// session reads as itself). APFS clones the files, so the copy costs no space until something in it changes.
    public static func make(copying sessionDir: URL, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let fm = FileManager.default
        let holder = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: holder, withIntermediateDirectories: true)
        let copy = holder.appendingPathComponent(sessionDir.lastPathComponent, isDirectory: true)
        do {
            try fm.copyItem(at: sessionDir, to: copy)
        } catch {
            try? fm.removeItem(at: holder)
            throw error
        }
        return copy
    }

    /// Removes a workspace made by `make` (the copy's holder folder). Refuses anything that is not one.
    @discardableResult
    public static func remove(_ copy: URL) -> Bool {
        let holder = copy.deletingLastPathComponent()
        guard holder.lastPathComponent.hasPrefix(prefix) else { return false }
        try? FileManager.default.removeItem(at: holder)
        return !FileManager.default.fileExists(atPath: holder.path)
    }

    /// Removes workspaces left behind by a rehearsal that never ended normally (the app was killed), except `keeping`.
    /// Returns how many were removed.
    @discardableResult
    public static func sweep(root: URL = FileManager.default.temporaryDirectory, keeping: URL? = nil) -> Int {
        let fm = FileManager.default
        let keep = keeping?.deletingLastPathComponent().standardizedFileURL.path
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if url.standardizedFileURL.path == keep { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
