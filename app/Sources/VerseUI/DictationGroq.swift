import Foundation
import VerseVoice

// MARK: - Engine choice

/// Which engine writes a dictation's final text (setting `DictationSettings.engine`).
///
/// - `apple`: the on-device Apple engine, live preview and final text (the default; nothing leaves the Mac).
/// - `groq`: the Apple engine still runs for the live preview in the island; the audio is also kept in memory and, when the
///   dictation stops, sent to Groq's Whisper (`GroqDictationTranscriber`), whose text becomes the final transcript. Any
///   problem falls back to the Apple text (`DictationNotice.cloudUnavailable`, `.cloudNoKey`).
public enum DictationEngine: String, CaseIterable, Sendable {
    case apple
    case groq
}

/// Makes the transcriber of one dictation for the selected engine (`DictationController`'s default `makeTranscriber`).
@MainActor
enum DictationEngineFactory {
    static func make(_ engine: DictationEngine, client: any GroqTranscribing = URLSessionGroqClient(),
                     apiKey: @escaping @Sendable () -> String? = { GroqKey.read() },
                     log: @escaping (String) -> Void = { FileLog.shared.write($0) }) -> any DictationTranscribing {
        switch engine {
        case .apple:
            return AppleDictationTranscriber()
        case .groq:
            let audio = DictationAudioRecorder()
            return GroqDictationTranscriber(inner: AppleDictationTranscriber(recorder: audio), audio: audio, apiKey: apiKey,
                                            client: client, log: log)
        }
    }
}

// MARK: - Groq Whisper constants

/// Groq's OpenAI-compatible transcription endpoint (https://console.groq.com/docs/speech-to-text, read 2026-11-25):
/// multipart form with `file`, `model`, `language` (ISO-639-1), `prompt` (at most 224 tokens), `temperature`,
/// `response_format`; files up to 25 MB on the free tier; `json` answers `{"text": "..."}`.
public enum GroqWhisper {
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    /// The most accurate multilingual model Groq serves (WER 10.3% in Groq's table, against 12% for turbo).
    public static let accurateModel = "whisper-large-v3"
    /// Faster and cheaper, a little less accurate.
    public static let turboModel = "whisper-large-v3-turbo"
    /// Flip to use the turbo model.
    public static let useTurbo = false
    public static var model: String { useTurbo ? turboModel : accurateModel }

    /// Groq's prompt limit.
    public static let promptTokenLimit = 224
    /// What the prompt is built to, by `estimatedTokens`: a margin under the limit, since the real tokenizer is not here.
    public static let promptTokenBudget = 200

    /// Shorter audio is not sent (Groq's minimum is 0.01 s; anything this short has no words in it).
    public static let minimumSeconds: TimeInterval = 0.1

    /// How long the stop waits for the Keychain read started at `begin` (normally done long before): a `security` call stuck
    /// on a keychain prompt must not hold the dictation in "finishing".
    public static let keyReadTimeout: TimeInterval = 3

    /// How long the answer may take: 8 s for a short dictation, a little more for a long one, at most 20 s.
    public static func timeout(audioSeconds: TimeInterval) -> TimeInterval {
        min(20, 8 + max(0, audioSeconds) * 0.05)
    }

    /// A conservative token count for a Whisper prompt: one token per two UTF-8 bytes. Whisper's byte-level BPE averages
    /// about four characters a token on English and fewer on Turkish; two bytes a token over-counts both, so a prompt built
    /// to `promptTokenBudget` by this count stays under the real limit.
    public static func estimatedTokens(_ s: String) -> Int { (s.utf8.count + 1) / 2 }

    /// Whisper's subtitle-credit hallucination in Turkish ("Altyazı M.K."), which it writes over silence or a trailing
    /// pause: learned from subtitle files, never something the owner said. Any spelling, anywhere in the text.
    static let subtitleCredit = try! NSRegularExpression(
        pattern: #"[(\[]?\s*[Aa][Ll][Tt]\s?[Yy][Aa][Zz][ıiIİ]\s*:?\s*[Mm]\s*\.?\s*[Kk]\b\.?\s*[)\]]?"#)

    /// The transcript without that credit, with the spaces it left behind closed up.
    public static func strippingArtifacts(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = subtitleCredit.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The vocabulary as a short natural list ("Claude Code, Groq, Whisper."), the form Whisper takes as spelling and context
    /// bias. Terms are added in their order until the next one would pass the budget: a term is never cut in half. nil when
    /// there is no term (the field is then left out).
    public static func prompt(terms: [String], budget: Int = promptTokenBudget) -> String? {
        var kept: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let candidate = (kept + [term]).joined(separator: ", ") + "."
            if estimatedTokens(candidate) > budget { break }
            kept.append(term)
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ") + "."
    }
}

// MARK: - Key

/// The Groq key in the login Keychain: service `verse-groq`, account `$USER` (else the login name), created through
/// `/usr/bin/security` so the app and scripts read it without a prompt. The same pattern and code as the Anthropic key
/// (`KeychainStore`) and the voice keys (`VoiceKeys`, whose service-generic calls this uses): the key never appears on a
/// command line, in a file or in a log; `hasKey` and `last4` read only the item's attributes.
public enum GroqKey {
    public static let service = "verse-groq"

    public static var hasKey: Bool { VoiceKeys.hasKey(service: service) }
    public static var last4: String? { VoiceKeys.last4(service: service) }
    public static func save(_ key: String) throws { try VoiceKeys.save(key, service: service) }
    public static func remove() throws { try VoiceKeys.remove(service: service) }
    /// The key itself, for the request. nil when there is none.
    public static func read() -> String? { VoiceKeys.read(service: service) }

    /// The one-line Terminal command that saves the key the same way (`security` asks for it, so it is not in the history).
    public static let terminalCommand = "security add-generic-password -U -a \"$USER\" -s \(service) -l \(service) -w"
}

// MARK: - Request

/// One transcription request.
public struct GroqTranscriptionRequest: Sendable, Equatable {
    public var audio: Data
    public var language: String
    public var prompt: String?
    public var model: String

    public init(audio: Data, language: String, prompt: String?, model: String = GroqWhisper.model) {
        self.audio = audio
        self.language = language
        self.prompt = prompt
        self.model = model
    }
}

public enum GroqTranscriptionError: Error, Equatable, Sendable {
    /// The server answered with this HTTP status (the body is not kept: it may echo the request).
    case http(Int)
    /// No connection, DNS, TLS: anything URLSession reports that is not a timeout or a cancel.
    case network
    case timeout
    /// The answer was not the expected JSON.
    case badResponse
}

/// The multipart/form-data request, built apart from the network so tests can read it.
public enum GroqMultipart {
    public static let fileName = "dictation.wav"

    public static func body(_ r: GroqTranscriptionRequest, boundary: String) -> Data {
        var d = Data()
        func field(_ name: String, _ value: String) {
            d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", r.model)
        field("language", r.language)
        if let p = r.prompt, !p.isEmpty { field("prompt", p) }
        field("temperature", "0")
        field("response_format", "json")
        d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        d.append(r.audio)
        d.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return d
    }

    public static func urlRequest(_ r: GroqTranscriptionRequest, apiKey: String, boundary: String,
                                  timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: GroqWhisper.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body(r, boundary: boundary)
        return req
    }

    /// The text of a `response_format=json` answer.
    public static func text(fromJSON data: Data) throws -> String {
        struct Answer: Decodable { var text: String }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw GroqTranscriptionError.badResponse }
        return a.text
    }
}

/// Sends one transcription request. The app's is `URLSessionGroqClient`; tests stub it.
public protocol GroqTranscribing: Sendable {
    /// The transcript. Throws `GroqTranscriptionError`, or `CancellationError` when the task was cancelled.
    func transcribe(_ request: GroqTranscriptionRequest, apiKey: String, timeout: TimeInterval) async throws -> String
}

/// The real client: one POST on an ephemeral session (no cache, no cookies, nothing on disk).
public struct URLSessionGroqClient: GroqTranscribing {
    /// One ephemeral session for the app's life: a session made per dictation and never invalidated would leak.
    public static let sharedSession = URLSession(configuration: .ephemeral)

    let session: URLSession

    public init(session: URLSession = URLSessionGroqClient.sharedSession) { self.session = session }

    public func transcribe(_ request: GroqTranscriptionRequest, apiKey: String, timeout: TimeInterval) async throws -> String {
        let req = GroqMultipart.urlRequest(request, apiKey: apiKey, boundary: "verse-\(UUID().uuidString)", timeout: timeout)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw GroqTranscriptionError.timeout
            default: throw GroqTranscriptionError.network
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GroqTranscriptionError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GroqTranscriptionError.badResponse }
        guard http.statusCode == 200 else { throw GroqTranscriptionError.http(http.statusCode) }
        return try GroqMultipart.text(fromJSON: data)
    }
}

// MARK: - The transcriber

/// How a Groq dictation ended, for the log (numbers and enums only: never text, never the key).
public enum GroqDictationOutcome: String, Sendable, Equatable {
    case ok
    case noKey = "no_key"
    /// The Keychain read did not return within `GroqWhisper.keyReadTimeout`.
    case keyTimeout = "key_timeout"
    case tooLong = "too_long"
    case tooShort = "too_short"
    case http
    case network
    case timeout
    case badResponse = "bad_response"
    case empty
    case cancelled
}

/// The "Groq Whisper" engine: the Apple transcriber (`inner`) runs exactly as with the Apple engine (live text, level,
/// release tail, capture-closed report), while its capture also feeds `audio`. `finish` first lets the Apple engine finish,
/// then sends the audio to Groq and returns Groq's text; on no key, too long a recording, an HTTP or network error, an
/// empty answer or no answer within `GroqWhisper.timeout`, it returns the Apple text and sets `finishNotice`. The controller
/// shows the "finishing" state the whole time (its phase is `.finalising` until `finish` returns).
///
/// `cancel` (Esc, a run starting) cancels the request too; the controller drops whatever `finish` then returns.
@MainActor
final class GroqDictationTranscriber: DictationTranscribing {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let inner: any DictationTranscribing
    private let audio: DictationAudioRecorder
    private let apiKey: @Sendable () -> String?
    private let client: any GroqTranscribing
    private let model: String
    private let sleep: Sleep
    private let keySleep: Sleep
    private let now: @MainActor () -> TimeInterval
    private let log: (String) -> Void

    private var lang = "en"
    private var vocabulary: [String] = []
    /// The Keychain read (a `security` subprocess), started at `begin` off the main actor so it is done by the stop.
    private var keyRead: Task<String?, Never>?
    private var upload: Task<String, any Error>?
    private var cancelled = false
    private(set) var outcome: GroqDictationOutcome?
    private(set) var finishNotice: DictationNotice?

    init(inner: any DictationTranscribing, audio: DictationAudioRecorder, apiKey: @escaping @Sendable () -> String?,
         client: any GroqTranscribing, model: String = GroqWhisper.model,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
         keySleep: @escaping Sleep = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         log: @escaping (String) -> Void) {
        self.inner = inner
        self.audio = audio
        self.apiKey = apiKey
        self.client = client
        self.model = model
        self.sleep = sleep
        self.keySleep = keySleep
        self.now = now
        self.log = log
    }

    var inputLevel: DictationInputLevel { inner.inputLevel }
    var liveText: String { inner.liveText }
    func takeFrameRMS() -> Float? { inner.takeFrameRMS() }
    func takeMeterLevel() -> Float? { inner.takeMeterLevel() }

    func begin(lang: String, vocabulary: [String], onFailure: @escaping @MainActor (String) -> Void) async throws {
        self.lang = lang
        self.vocabulary = vocabulary
        let apiKey = self.apiKey
        keyRead = Task.detached(priority: .userInitiated) { apiKey() }
        try await inner.begin(lang: lang, vocabulary: vocabulary, onFailure: onFailure)
    }

    func finish(onCaptureClosed: @escaping @MainActor @Sendable () -> Void) async throws -> String {
        let appleText = try await inner.finish(onCaptureClosed: onCaptureClosed)
        guard !cancelled else { return appleText }
        let (samples, overflowed) = audio.snapshot
        let seconds = Double(samples.count) / DictationResampler.targetRate
        let audioMs = Int((seconds * 1000).rounded())
        if overflowed { return fallback(.tooLong, appleText, audioMs: audioMs) }
        if seconds < GroqWhisper.minimumSeconds {
            // Nothing to send: the Apple text (almost certainly empty) as it is, without a notice.
            record(.tooShort, audioMs: audioMs)
            return appleText
        }
        let key: String
        switch await waitForKey() {
        case .timedOut:
            guard !cancelled else { return appleText }
            return fallback(.keyTimeout, appleText, audioMs: audioMs)
        case .read(let k):
            guard !cancelled else { return appleText }
            guard let k, !k.isEmpty else { return fallback(.noKey, appleText, audioMs: audioMs) }
            key = k
        }
        let request = GroqTranscriptionRequest(audio: DictationWAV.encode(samples), language: lang,
                                               prompt: GroqWhisper.prompt(terms: vocabulary), model: model)
        let timeout = GroqWhisper.timeout(audioSeconds: seconds)
        let client = self.client, sleep = self.sleep
        let started = now()
        let task = Task<String, any Error> {
            try await Self.withDeadline(timeout, sleep: sleep) {
                try await client.transcribe(request, apiKey: key, timeout: timeout)
            }
        }
        upload = task
        let text: String
        do {
            text = try await task.value
        } catch {
            upload = nil
            let ms = Int(((now() - started) * 1000).rounded())
            if cancelled || error is CancellationError {
                record(.cancelled, audioMs: audioMs, ms: ms)
                return appleText
            }
            switch error as? GroqTranscriptionError {
            case .http(let status)?: return fallback(.http, appleText, audioMs: audioMs, ms: ms, status: status)
            case .timeout?: return fallback(.timeout, appleText, audioMs: audioMs, ms: ms)
            case .badResponse?: return fallback(.badResponse, appleText, audioMs: audioMs, ms: ms)
            case .network?, nil: return fallback(.network, appleText, audioMs: audioMs, ms: ms)
            }
        }
        upload = nil
        let ms = Int(((now() - started) * 1000).rounded())
        guard !cancelled else {
            record(.cancelled, audioMs: audioMs, ms: ms)
            return appleText
        }
        let clean = GroqWhisper.strippingArtifacts(text)
        guard !clean.isEmpty else { return fallback(.empty, appleText, audioMs: audioMs, ms: ms) }
        record(.ok, audioMs: audioMs, ms: ms)
        return clean
    }

    func cancelPending() {
        cancelled = true
        upload?.cancel()
        keyRead?.cancel()
    }

    func cancel() async {
        cancelPending()
        await inner.cancel()
    }

    // MARK: helpers

    private enum KeyWait: Sendable { case read(String?), timedOut }

    /// Resumes a continuation once; later calls do nothing.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<KeyWait, Never>?
        init(_ c: CheckedContinuation<KeyWait, Never>) { continuation = c }
        func resume(_ v: KeyWait) {
            let c: CheckedContinuation<KeyWait, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: v)
        }
    }

    /// The key from the read started at `begin`, or `.timedOut` after `GroqWhisper.keyReadTimeout`. Does not wait for a
    /// stuck read to end (the `security` subprocess cannot be interrupted from here; its late result is dropped).
    private func waitForKey() async -> KeyWait {
        guard let keyRead else { return .read(nil) }
        let keySleep = self.keySleep
        let ms = Int((GroqWhisper.keyReadTimeout * 1000).rounded())
        return await withCheckedContinuation { (c: CheckedContinuation<KeyWait, Never>) in
            let once = ResumeOnce(c)
            let timer = Task.detached {
                do { try await keySleep(.milliseconds(ms)) } catch { return }
                once.resume(.timedOut)
            }
            Task.detached {
                let k = await keyRead.value
                once.resume(.read(k))
                timer.cancel()
            }
        }
    }

    /// The Apple text, with the notice that says so. When the Apple text is empty too, the controller's "heard nothing"
    /// follows and replaces it.
    private func fallback(_ o: GroqDictationOutcome, _ appleText: String, audioMs: Int, ms: Int? = nil, status: Int? = nil) -> String {
        record(o, audioMs: audioMs, ms: ms, status: status)
        finishNotice = o == .noKey ? .cloudNoKey : .cloudUnavailable
        return appleText
    }

    private func record(_ o: GroqDictationOutcome, audioMs: Int, ms: Int? = nil, status: Int? = nil) {
        outcome = o
        var line = "dictation: groq outcome=\(o.rawValue) audio_ms=\(audioMs)"
        if let ms { line += " ms=\(ms)" }
        if let status { line += " status=\(status)" }
        log(line)
    }

    /// `op`, or `GroqTranscriptionError.timeout` once `seconds` have passed, whichever comes first; the other is cancelled.
    nonisolated static func withDeadline(_ seconds: TimeInterval, sleep: @escaping Sleep,
                                         _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await sleep(.milliseconds(Int((seconds * 1000).rounded())))
                throw GroqTranscriptionError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw GroqTranscriptionError.timeout }
            return first
        }
    }
}
