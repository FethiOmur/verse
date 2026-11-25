import Foundation
import os
import VerseSpeech

/// What dictation records and transcribes with. One instance per dictation: `begin`, then `finish` (or `cancel`).
///
/// The on-device Apple engine (`AppleDictationTranscriber`), and the Groq Whisper engine (`GroqDictationTranscriber`): the
/// Apple one plus an upload in `finish`, with the Apple text as its fallback (`DictationEngine`).
@MainActor
public protocol DictationTranscribing: AnyObject {
    /// Opens the microphone and starts transcribing in `lang` ("en", "it" or "tr"), with `vocabulary` as the engine's hints
    /// (see `AppleDictationTranscriber.config`). Throws when it cannot start (permission, engine). `onFailure` is called when
    /// transcription stops by itself while recording (the controller reports it once).
    func begin(lang: String, vocabulary: [String], onFailure: @escaping @MainActor (String) -> Void) async throws
    /// What the microphone delivered since `begin`: peak, seconds of audio and callbacks. The silent-microphone check.
    var inputLevel: DictationInputLevel { get }
    /// The RMS of the microphone samples since the previous call (nil: none arrived). One release-tail frame.
    func takeFrameRMS() -> Float?
    /// Stops the microphone, lets the engine settle the last words and returns the whole transcript. `onCaptureClosed` is
    /// called (on the main actor) once the microphone's capture has stopped, before the engine has settled: no sound played
    /// from then on can reach the transcript.
    func finish(onCaptureClosed: @escaping @MainActor @Sendable () -> Void) async throws -> String
    /// Stops the microphone at once and drops everything. Safe at any time, also while `begin` is still under way.
    func cancel() async
    /// The synchronous first step of a cancel: the controller calls it on Esc or a run start, before `cancel` runs in a task
    /// of its own, so work the engine has not started yet (the Groq upload) never starts. Nothing for the Apple engine.
    func cancelPending()
    /// What has been recognised so far (finals plus the volatile tail): the recording indicator's live text (gap G5).
    var liveText: String { get }
    /// The microphone's RMS since the previous call (nil: no audio arrived): the recording indicator's level (gap G5).
    func takeMeterLevel() -> Float?
    /// A notice for the controller to show once `finish` has returned (a cloud engine fell back to the on-device text).
    /// nil for the Apple engine.
    var finishNotice: DictationNotice? { get }
}

public extension DictationTranscribing {
    var liveText: String { "" }
    func takeMeterLevel() -> Float? { nil }
    var finishNotice: DictationNotice? { nil }
    func cancelPending() {}
}

/// The live transcript, written by the event collector off the main actor and read by the indicator.
final class DictationLiveText: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var text = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
    func set(_ s: String) { lock.lock(); text = s; lock.unlock() }
}

/// Builds the transcript of one dictation from the engine's events: settled (final) text in order, plus a volatile tail that
/// no final has covered yet.
struct DictationTranscript: Sendable, Equatable {
    private var finals: [String] = []
    private var lastFinalEnd: TimeInterval = -.infinity
    private var volatile: (text: String, start: TimeInterval)?

    static func == (a: Self, b: Self) -> Bool { a.text == b.text }

    mutating func add(text: String, isFinal: Bool, start: TimeInterval, end: TimeInterval) {
        if isFinal {
            finals.append(text)
            lastFinalEnd = max(lastFinalEnd, end)
            volatile = nil
        } else {
            volatile = (text, start)
        }
    }

    mutating func add(_ e: TranscriptEvent) {
        add(text: e.text, isFinal: e.isFinal, start: e.audioStart, end: e.audioEnd)
    }

    var text: String {
        var parts = finals
        // A volatile result for audio a final already covers is an older guess of the same words.
        if let v = volatile, v.start >= lastFinalEnd - 0.05 { parts.append(v.text) }
        return Self.clean(parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// What gets inserted: the text without leading or trailing whitespace. Line breaks inside are kept.
    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The session issues that end a dictation. Recoveries and a silent microphone do not: a silent microphone just gives an
    /// empty transcript.
    static func isFatal(_ issue: ListenError) -> Bool {
        switch issue {
        case .captureRecovered, .speechRecovered, .deadStream: return false
        default: return true
        }
    }
}

/// The on-device Apple engine on the microphone alone, through the same `ListenSession` the meeting uses (the shape the
/// teleprompter's script mode already uses: no remote source, the microphone as the `me` channel). The engine is the
/// language's Apple engine (`SpeechTranscriber` for en/it, `DictationTranscriber` for tr): never Nemotron, so dictation
/// loads no large model and never unloads the meeting's. The microphone source is wrapped (`MeteredCaptureSource`) so the
/// controller can read its level and learn when its capture has stopped.
@MainActor
final class AppleDictationTranscriber: DictationTranscribing {
    private let meter = DictationInputMeter()
    private let live = DictationLiveText()
    /// The Groq engine's in-memory copy of the audio; nil for the Apple engine (the capture is then exactly as before).
    let recorder: DictationAudioRecorder?
    private var session: ListenSession?
    private var collector: Task<String, Never>?
    private var issueWatch: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var cancelled = false

    /// The listen configuration of a dictation in `lang`.
    ///
    /// The vocabulary (gap G3) goes to the engine as the analyzer's contextual strings only where it has an effect: measured
    /// 2026-11-12 on macOS 26.6 (`ListenConfig.contextualStrings`), `DictationTranscriber` (the Turkish engine) uses them and
    /// `SpeechTranscriber` (English and Italian) ignores them. So it is passed for Turkish only; for English and Italian the
    /// field has no effect (Settings says so). No accuracy gain was measured for dictation itself.
    nonisolated static func config(lang: String, vocabulary: [String] = []) -> ListenConfig {
        var c = ListenConfig(lang: lang, remoteBundleIDs: [], micEnabled: true, source: .live)
        let kind = EngineFactory.defaultKind(for: lang)
        c.engineKind = kind
        c.statusSink = nil
        c.releaseIdleModelsOnStop = false
        if vocabularyTakesEffect(kind) {
            c.contextualStrings = Array(vocabulary.prefix(DictationSettings.vocabularyCap))
        }
        return c
    }

    /// Whether an engine honours contextual strings (see `config`).
    nonisolated static func vocabularyTakesEffect(_ kind: EngineKind) -> Bool { kind == .dictationTranscriber }

    /// Whether the vocabulary reaches the engine of a dictation in `lang`.
    nonisolated static func vocabularyTakesEffect(lang: String) -> Bool {
        vocabularyTakesEffect(EngineFactory.defaultKind(for: lang))
    }

    init(recorder: DictationAudioRecorder? = nil) {
        self.recorder = recorder
    }

    /// The system environment without a remote source: only the microphone opens, metered by `meter` (and kept by
    /// `recorder`, when there is one).
    nonisolated static func environment(meter: DictationInputMeter, recorder: DictationAudioRecorder? = nil) -> ListenEnvironment {
        let base = ListenEnvironment.system
        var e = base
        e.makeRemoteSource = { _ in nil }
        e.makeMicSource = { cfg in try base.makeMicSource(cfg).map { MeteredCaptureSource(inner: $0, meter: meter, recorder: recorder) } }
        return e
    }

    var inputLevel: DictationInputLevel { meter.level }

    var liveText: String { live.value }

    func takeMeterLevel() -> Float? { meter.takeMeterRMS() }

    func takeFrameRMS() -> Float? { meter.takeFrameRMS() }

    func begin(lang: String, vocabulary: [String], onFailure: @escaping @MainActor (String) -> Void) async throws {
        let s = ListenSession(config: Self.config(lang: lang, vocabulary: vocabulary), environment: Self.environment(meter: meter, recorder: recorder))
        session = s
        let stream = try await s.start()
        // Cancelled while the engine loaded: a stop() issued then found nothing open yet, so close what has opened since.
        if cancelled {
            await s.stop()
            throw CancellationError()
        }
        let live = self.live
        collector = Task.detached {
            var t = DictationTranscript()
            for await e in stream {
                t.add(e)
                live.set(t.text)
            }
            return t.text
        }
        issueWatch = Task {
            for await issue in s.issues where DictationTranscript.isFatal(issue) {
                onFailure(issue.description)
                break
            }
        }
    }

    func finish(onCaptureClosed: @escaping @MainActor @Sendable () -> Void) async throws -> String {
        guard let s = session else {
            onCaptureClosed()
            return ""
        }
        meter.whenCaptureCloses {
            DispatchQueue.main.async { MainActor.assumeIsolated { onCaptureClosed() } }
        }
        await stop(s)
        let text = await collector?.value ?? ""
        issueWatch?.cancel()
        return text
    }

    func cancel() async {
        cancelled = true
        issueWatch?.cancel()
        collector?.cancel()
        if let s = session { await stop(s) }
    }

    /// One stop per session, whichever of finish and cancel comes first.
    private func stop(_ s: ListenSession) async {
        if stopTask == nil { stopTask = Task { await s.stop() } }
        await stopTask?.value
    }
}
