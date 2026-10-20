import Foundation
import os
import VerseSpeech
import VerseVoice

// Interview simulation, app side (plan S4): drives the brain's sim protocol (S2, `brain/verse_brain/runtime/sim.py`)
// over the same JSON lines as meetings, plays the interviewer through a `VoiceEngine` and listens on the mic channel
// only, half-duplex.
//
// Turn-taking rules:
// - `say{id,text,final}` sentences are queued and played in order; after the `final` sentence of line `id` has
//   played, `{"type":"spoken","id":id}` goes back. Line ids come from the brain and are never computed here.
// - The mic opens only once a `listen{q_id}` has arrived AND the last line has been reported `spoken` AND nothing is
//   queued or playing. While a line plays the mic is closed: its transcript is dropped (no self-transcription of the
//   interviewer through the speakers). Results whose audio started clearly before the mic opened are dropped too
//   (the recognizer lags behind the audio).
// - While the user answers, `partial` lines keep the brain's 20 s silence prompt from firing mid-answer.
// - The answer ends after `answerSilence` (2.0 s) with no new words, or on `doneAnswering()` (⌥Space); then exactly
//   one `answer{q_id,text,t_start,t_end,words,fillers}` is sent and the mic closes.
// Nothing here writes audio.

/// The brain child process as the sim runner sees it. `BrainProcess` is the real one; tests use a fake.
public protocol SimBrainTransport: AnyObject, Sendable {
    var lines: AsyncStream<String> { get }
    func send(_ line: String)
    /// Ends the brain (stop, close stdin, escalate). Returns when it is gone.
    func close() async
}

extension BrainProcess: SimBrainTransport {
    public func close() async { await shutdown() }
}

/// The microphone as the sim runner sees it: mic-channel transcript events on the session clock.
public protocol SimMic: Sendable {
    func start() async throws -> AsyncStream<TranscriptEvent>
    /// Seconds on the same clock as the events' `audioStart`/`audioEnd`.
    func now() async -> TimeInterval
    func stop() async
}

/// The real mic: a `ListenSession` with the microphone only (no process tap, so no meeting-app audio and no
/// System Audio Recording permission).
public final class ListenSimMic: SimMic {
    private let session: ListenSession

    public init(lang: String) {
        var cfg = ListenConfig(lang: lang, remoteBundleIDs: [], micEnabled: true, source: .live)
        cfg.voiceProcessing = false
        let sys = ListenEnvironment.system
        let env = ListenEnvironment(permissions: sys.permissions, makeRemoteSource: { _ in nil },
                                    makeMicSource: sys.makeMicSource, makeEngine: sys.makeEngine)
        session = ListenSession(config: cfg, environment: env)
    }

    public func start() async throws -> AsyncStream<TranscriptEvent> { try await session.start() }
    public func now() async -> TimeInterval { await session.now() }
    public func stop() async { await session.stop() }
}

/// What the runner tells the app. Everything is keyed on the ids the brain sent.
public enum SimEvent: Sendable, Equatable {
    /// A brain `status` (`warming`, `ready`, `error`, ...), or one the runner makes itself (`permission_denied`
    /// with message `microphone`, `listen_failed`, `error`).
    case status(state: String, message: String)
    /// `sim_progress`: question `index` (1-based) of `total`.
    case progress(index: Int, total: Int)
    /// One interviewer sentence as it arrived (before it plays).
    case say(lineID: String, text: String, final: Bool)
    /// Playback state: the line being played, or nil when nothing plays.
    case speaking(lineID: String?)
    /// The final sentence of `lineID` has played and `spoken` went to the brain.
    case spoken(lineID: String)
    /// The mic is open for `qID`.
    case listening(qID: String)
    /// The answer as heard so far (finals plus the current volatile text).
    case answerText(String)
    /// The answer went to the brain; the mic is closed.
    case answerSent(qID: String, text: String)
    /// A coach note (`coach` mode), citations already stripped.
    case coach(qID: String, lines: [String])
    /// A cloud voice failed for one sentence; the Apple voice spoke it.
    case voiceFallback(VoiceKind)
    /// `sim_report`: the report is at `path` (`report.html`).
    case report(path: String)
    /// The brain is gone. 0: after a report or a requested stop.
    case ended(code: Int32)
}

public enum SimControl: String, Sendable {
    case skip, `repeat`, end
}

public enum SimMode: String, Sendable, CaseIterable {
    case coach, realistic
}

/// Pure helpers shared by the runner and the app.
public enum SimText {
    /// The disclosure rule (OpenAI usage policy): a synthetic cloud voice is labelled as AI-generated while it speaks.
    public static func needsAIDisclosure(_ voice: VoiceKind) -> Bool {
        voice == .elevenlabs || voice == .openai
    }

    nonisolated(unsafe) private static let citation = /\s*\[\s*e\d+(?:\s*[,;]\s*e\d+)*\s*\]/

    /// Drops `[e1]` / `[e1, e3]` evidence citations from a coach line and tidies the spacing they leave.
    public static func stripCitations(_ s: String) -> String {
        var t = s.replacing(citation, with: "")
        for p in [" .", " ,", " ;", " :", " !", " ?", " )"] { t = t.replacingOccurrences(of: p, with: String(p.dropFirst())) }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    /// English filler words and phrases (the list S5's `delivery.py` counts), word-boundary, case-insensitive.
    static let fillersEN = ["you know", "sort of", "kind of", "um", "uh", "like", "basically", "actually"]

    public static func fillerCount(_ s: String, lang: String = "en") -> Int {
        guard lang == "en" else { return 0 }
        let words = s.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        var n = 0, i = 0
        while i < words.count {
            if i + 1 < words.count, fillersEN.contains(words[i] + " " + words[i + 1]) { n += 1; i += 2; continue }
            if fillersEN.contains(words[i]) { n += 1 }
            i += 1
        }
        return n
    }

    /// One compact JSON object line.
    static func line(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}

/// Drives one practice interview. Create, `start()`, then feed `control` / `doneAnswering` from the UI.
public actor SimRunner {
    public struct Config: Sendable {
        /// Mic silence that ends an answer.
        public var answerSilence: TimeInterval = 2.0
        /// At most one `partial` per this many seconds while the user answers.
        public var partialInterval: TimeInterval = 0.5
        /// How often the silence clock is checked.
        public var tickInterval: TimeInterval = 0.1
        /// Results whose audio began more than this before the mic opened are the interviewer's tail, not an answer.
        public var echoGuard: TimeInterval = 0.3
        /// After ⌥Space, words already spoken still arrive from the recognizer for this long.
        public var doneGrace: TimeInterval = 0.4
        public var lang = "en"
        /// The app's interface language (`en|it|tr`): the report page's headings follow it. The interview stays in `lang`.
        public var uiLang = "en"
        public init() {}
    }

    private struct Sentence { var lineID: String; var text: String; var final: Bool }

    /// The answer being heard: settled finals plus the latest volatile text.
    private struct Answer {
        var finals: [String] = []
        var volatile = ""
        var tStart: TimeInterval?
        var tEnd: TimeInterval = 0
        var text: String { (finals + [volatile]).filter { !$0.isEmpty }.joined(separator: " ") }
        var started: Bool { tStart != nil }
    }

    private let transport: any SimBrainTransport
    private let voice: any VoiceEngine
    private let mic: any SimMic
    private let config: Config
    private let sink: @Sendable (SimEvent) -> Void
    /// Synthesized sentences held in memory only: every `say` / `say_prefetch` sentence starts synthesizing at once.
    private let cache: PrefetchCache

    private var queue: [Sentence] = []
    private var playing = false
    private var generation = 0
    private var lastLineID: String?
    private var spokenSent: Set<String> = []
    private var pendingListen: String?
    private var micOpen = false
    private var openedAt: TimeInterval = 0
    private var now: TimeInterval = 0
    private var answer = Answer()
    private var lastPartialAt: TimeInterval = -.infinity
    private var doneDeadline: TimeInterval?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false
    private var stopRequested = false
    private var reported = false
    /// Mic results dropped because the mic was closed or they were the interviewer's tail (tests, logs).
    public private(set) var droppedMicEvents = 0

    /// One `tts_gap_ms` measurement.
    public struct TTSGap: Sendable, Equatable {
        public enum Kind: String, Sendable { case line, sentence }
        public let lineID: String
        public let kind: Kind
        /// `line`: from the first `say` sentence of the line arriving to its audio starting (a prefetched question is
        /// ready, so this is the wait after JUDGE). `sentence`: silence between the end of one sentence and the start
        /// of the next within a line.
        public let ms: Int
        /// The sentence was already in the cache when its turn came.
        public let prefetched: Bool
    }
    /// The measurements so far (also logged as `tts_gap_ms`).
    public private(set) var ttsGaps: [TTSGap] = []
    private var arrivedAt: [String: Date] = [:]
    private var lastPlayEnd: (lineID: String, at: Date)?
    private static let log = Logger(subsystem: "dev.fethiverse.verse", category: "sim")

    public init(transport: any SimBrainTransport, voice: any VoiceEngine, mic: any SimMic, config: Config = Config(),
                sink: @escaping @Sendable (SimEvent) -> Void) {
        self.transport = transport
        self.voice = voice
        self.mic = mic
        self.config = config
        self.sink = sink
        self.cache = PrefetchCache(engine: voice)
    }

    // MARK: lifecycle

    /// Opens the mic (asking for permission), starts reading the brain, and sends `sim_start`.
    public func start(sessionDir: URL, mode: SimMode, voice kind: VoiceKind) async {
        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await mic.start()
        } catch let e as ListenError {
            if case .permissionDenied(let k) = e {
                sink(.status(state: "permission_denied", message: k.rawValue))
            } else {
                sink(.status(state: "listen_failed", message: e.description))
            }
            await finish(code: 3)
            return
        } catch {
            sink(.status(state: "listen_failed", message: "\(error)"))
            await finish(code: 1)
            return
        }
        let t = transport
        tasks.append(Task { [weak self] in
            for await line in t.lines { await self?.brainLine(line) }
            await self?.brainEnded()
        })
        tasks.append(Task { [weak self] in
            for await e in events { await self?.micEvent(e) }
        })
        let m = mic, interval = config.tickInterval
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.tick(now: await m.now())
            }
        })
        send(["type": "sim_start", "session_dir": sessionDir.path, "mode": mode.rawValue, "voice": kind.rawValue, "ui_lang": config.uiLang])
    }

    /// Ends at once without a report (Quit, Abort): the brain writes the transcript so far and exits.
    public func stop() async {
        stopRequested = true
        await flushPlayback()
        closeMic()
        await transport.close()
        await finish(code: 0)
    }

    private func finish(code: Int32) async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks = []
        await voice.stop()
        await cache.clear()       // the audio never outlives the interview
        await mic.stop()
        await transport.close()   // a no-op when the brain is already gone
        sink(.ended(code: code))
    }

    private func brainEnded() async {
        let ok = stopRequested || reported
        if !ok { sink(.status(state: "error", message: "The interview brain stopped unexpectedly.")) }
        await finish(code: ok ? 0 : 1)
    }

    // MARK: UI input

    /// skip / repeat / end. Skip and end stop the line that is playing and drop the answer in progress.
    public func control(_ c: SimControl) async {
        guard !finished else { return }
        send(["type": "control", "action": c.rawValue])
        if c != .repeat {
            await flushPlayback()
            closeMic()
            answer = Answer()
        }
    }

    /// ⌥Space: the user is done answering. Words already spoken are still collected for `doneGrace`.
    public func doneAnswering() {
        guard micOpen else { return }
        if config.doneGrace <= 0 { endAnswer() } else { doneDeadline = now + config.doneGrace }
    }

    // MARK: brain output

    private func brainLine(_ raw: String) async {
        guard let o = JSONValue.decodeObject(raw) else { return }
        switch o.type {
        case "say":
            guard let id = o[string: "id"] else { return }
            let text = o[string: "text"] ?? ""
            let final = o[bool: "final"] ?? false
            lastLineID = id
            if micOpen {
                // The interviewer talks again (the silence prompt): the mic closes until the next listen. What was
                // heard so far stays and continues after it.
                micOpen = false
                pendingListen = nil
            }
            sink(.say(lineID: id, text: text, final: final))
            if arrivedAt[id] == nil { arrivedAt[id] = Date() }
            await cache.prefetch(text)
            queue.append(Sentence(lineID: id, text: text, final: final))
            pump()
        case "say_prefetch":
            // The next question's line, ahead of time. Only synthesis is started here; the `say` lines that follow
            // (same text) hit the cache. Nothing is shown or played.
            for t in o["sentences"]?.array ?? [] {
                if let text = t.string { await cache.prefetch(text) }
            }
        case "listen":
            guard let q = o[string: "q_id"] else { return }
            pendingListen = q
            maybeOpenMic()
        case "coach":
            let lines = (o["lines"]?.array ?? []).compactMap(\.string).map(SimText.stripCitations).filter { !$0.isEmpty }
            sink(.coach(qID: o[string: "q_id"] ?? "", lines: lines))
        case "sim_progress":
            sink(.progress(index: Int(o[double: "q_index"] ?? 0), total: Int(o[double: "q_total"] ?? 0)))
        case "sim_report":
            reported = true
            sink(.report(path: o[string: "path"] ?? ""))
            // The interview is over; the brain process has nothing left to do.
            await transport.close()
        case "status":
            sink(.status(state: o[string: "state"] ?? "", message: o[string: "message"] ?? ""))
        default:
            break   // metric and anything newer
        }
    }

    // MARK: playback

    private func pump() {
        guard !playing, !queue.isEmpty, !finished else { return }
        playing = true
        let s = queue.removeFirst()
        let gen = generation
        sink(.speaking(lineID: s.lineID))
        let v = voice, cache = self.cache
        tasks.append(Task { [weak self] in
            do {
                let hit = await cache.take(s.text)
                let speech: SynthesizedSpeech
                if let hit { speech = hit } else { speech = try await v.synthesize(s.text) }
                guard await self?.isCurrent(gen) == true else { return }   // skipped or ended while it was being made
                await self?.playStarted(s, prefetched: hit != nil)
                try await v.play(speech)
            } catch is CancellationError {
            } catch {
                // Only the fallback voice itself failed: the line is still shown, the interview goes on.
                await self?.emit(.status(state: "voice_error", message: "\(error)"))
            }
            await self?.played(s, generation: gen)
        })
    }

    private func emit(_ e: SimEvent) { sink(e) }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !finished }

    /// Records the `tts_gap_ms` figures for the sentence that is about to play.
    private func playStarted(_ s: Sentence, prefetched: Bool) {
        let now = Date()
        if let last = lastPlayEnd, last.lineID == s.lineID {
            record(TTSGap(lineID: s.lineID, kind: .sentence, ms: Int(now.timeIntervalSince(last.at) * 1000), prefetched: prefetched))
        } else if let at = arrivedAt[s.lineID] {
            record(TTSGap(lineID: s.lineID, kind: .line, ms: Int(now.timeIntervalSince(at) * 1000), prefetched: prefetched))
        }
        lastPlayEnd = nil
    }

    private func record(_ g: TTSGap) {
        ttsGaps.append(g)
        Self.log.info("tts_gap_ms \(g.ms) kind=\(g.kind.rawValue, privacy: .public) line=\(g.lineID, privacy: .public) prefetched=\(g.prefetched)")
    }

    private func played(_ s: Sentence, generation gen: Int) {
        guard gen == generation else { return }   // flushed by skip/end
        playing = false
        lastPlayEnd = (s.lineID, Date())
        if s.final, !spokenSent.contains(s.lineID) {
            spokenSent.insert(s.lineID)
            send(["type": "spoken", "id": s.lineID])
            sink(.spoken(lineID: s.lineID))
        }
        if queue.isEmpty { sink(.speaking(lineID: nil)) }
        pump()
        maybeOpenMic()
    }

    private func flushPlayback() async {
        generation += 1
        queue.removeAll()
        let was = playing
        playing = false
        if was { sink(.speaking(lineID: nil)) }
        await voice.stop()
    }

    // MARK: mic

    private func maybeOpenMic() {
        guard let q = pendingListen, !micOpen, !playing, queue.isEmpty, !finished else { return }
        if let last = lastLineID, !spokenSent.contains(last) { return }
        micOpen = true
        openedAt = now
        sink(.listening(qID: q))
    }

    private func closeMic() {
        micOpen = false
        pendingListen = nil
        doneDeadline = nil
    }

    private func micEvent(_ e: TranscriptEvent) {
        guard e.channel == .me else { return }
        guard micOpen, let q = pendingListen, e.audioStart >= openedAt - config.echoGuard else {
            droppedMicEvents += 1
            return
        }
        let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isFinal {
            if !text.isEmpty { answer.finals.append(text) }
            answer.volatile = ""
        } else {
            answer.volatile = text
        }
        guard !text.isEmpty else { return }
        if answer.tStart == nil { answer.tStart = max(e.audioStart, openedAt) }
        answer.tEnd = max(answer.tEnd, e.audioEnd)
        let current = answer.text
        sink(.answerText(current))
        if now - lastPartialAt >= config.partialInterval {
            lastPartialAt = now
            let p = OutboundEvent.partial(turnID: "sim-\(q)", speaker: .me, text: current, cue: false, tAudioEnd: answer.tEnd)
            transport.send(p.jsonLine())
        }
    }

    /// The silence clock. Public for tests that drive time themselves.
    public func tick(now t: TimeInterval) {
        now = max(now, t)
        guard micOpen else { return }
        if let d = doneDeadline, now >= d {
            endAnswer()
            return
        }
        if answer.started, now - answer.tEnd >= config.answerSilence { endAnswer() }
    }

    private func endAnswer() {
        guard micOpen, let q = pendingListen else { return }
        let text = answer.text
        let tStart = answer.tStart ?? openedAt
        let tEnd = max(answer.tEnd, tStart)
        send(["type": "answer", "q_id": q, "text": text, "t_start": Text.ms(tStart), "t_end": Text.ms(tEnd),
              "words": SimText.wordCount(text), "fillers": SimText.fillerCount(text, lang: config.lang)])
        closeMic()
        answer = Answer()
        lastPartialAt = -.infinity
        sink(.answerSent(qID: q, text: text))
    }

    private func send(_ obj: [String: Any]) {
        transport.send(SimText.line(obj))
    }
}
