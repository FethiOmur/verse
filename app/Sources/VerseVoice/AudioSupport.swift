import AVFoundation
import Foundation
import os

public enum AudioFormat: Sendable { case mp3, wav }

/// Plays synthesized audio held in memory. Implementations must never write the audio to disk.
public protocol AudioPlaying: Sendable {
    /// Returns when playback ends (or `stop()` was called). Throws `VoiceError.audio` for audio it cannot decode or play.
    func play(_ audio: Data, format: AudioFormat) async throws
    func stop() async
}

/// AVAudioPlayer from `Data`: no temp file, no cache. The audio is discarded when playback ends.
public final class MemoryAudioPlayer: AudioPlaying, @unchecked Sendable {
    private let volume: Float
    @MainActor private var runner: PlaybackRunner?

    public init(volume: Float = 1) { self.volume = volume }

    @MainActor private func host() -> PlaybackRunner {
        if let r = runner { return r }
        let r = PlaybackRunner(volume: volume)
        runner = r
        return r
    }

    public func play(_ audio: Data, format: AudioFormat) async throws {
        let r = await host()
        try await withTaskCancellationHandler {
            try await r.play(audio, format: format)
        } onCancel: {
            Task { @MainActor in r.stop() }
        }
        try Task.checkCancellation()
    }

    public func stop() async { await host().stop() }
}

@MainActor
private final class PlaybackRunner: NSObject, AVAudioPlayerDelegate {
    private let volume: Float
    private var player: AVAudioPlayer?
    private var waiter: CheckedContinuation<Void, any Error>?

    init(volume: Float) { self.volume = volume }

    func play(_ audio: Data, format: AudioFormat) async throws {
        stop()
        let hint = (format == .mp3 ? AVFileType.mp3 : AVFileType.wav).rawValue
        let p: AVAudioPlayer
        do { p = try AVAudioPlayer(data: audio, fileTypeHint: hint) }
        catch { throw VoiceError.audio("could not decode the audio (\((error as NSError).code))") }
        p.delegate = self
        p.volume = volume
        guard p.prepareToPlay(), p.play() else { throw VoiceError.audio("playback did not start") }
        player = p
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in waiter = c }
    }

    /// Ends playback; a waiting `play` returns normally.
    func stop() {
        player?.stop()
        player = nil
        finish(.success(()))
    }

    private func finish(_ r: Swift.Result<Void, any Error>) {
        guard let w = waiter else { return }
        waiter = nil
        w.resume(with: r)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.finish(flag ? .success(()) : .failure(VoiceError.audio("playback ended with an error")))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.player = nil
            self.finish(.failure(VoiceError.audio("could not decode the audio")))
        }
    }
}

/// Default log sink: the unified log, public. Engines build their lines so that they never contain a key.
public enum VoiceLog {
    public static let `default`: @Sendable (String) -> Void = { line in
        Logger(subsystem: "dev.verse.voice", category: "voice").debug("\(line, privacy: .public)")
    }
}

/// Text helpers shared by the cloud engines.
public enum VoiceText {
    /// Splits `text` into pieces of at most `maxLength` characters, on sentence ends where possible, then on words, then hard.
    /// Whitespace runs become one space. Blank text gives no pieces.
    public static func chunks(_ text: String, maxLength: Int) -> [String] {
        precondition(maxLength > 0)
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        if whole.count <= maxLength { return [whole] }

        // sentences: runs of words up to one that ends with . ! ? (optionally followed by a closing quote or bracket)
        var sentences: [String] = []
        var cur: [String] = []
        for w in words {
            cur.append(w)
            if w.last(where: { !"\"')]”’".contains($0) }).map({ ".!?…".contains($0) }) == true {
                sentences.append(cur.joined(separator: " ")); cur = []
            }
        }
        if !cur.isEmpty { sentences.append(cur.joined(separator: " ")) }

        var out: [String] = []
        var line = ""
        func flush() { if !line.isEmpty { out.append(line); line = "" } }
        for s in sentences {
            if s.count > maxLength {
                flush()
                out.append(contentsOf: splitWords(s, maxLength: maxLength))
            } else if line.isEmpty {
                line = s
            } else if line.count + 1 + s.count <= maxLength {
                line += " " + s
            } else {
                flush(); line = s
            }
        }
        flush()
        return out
    }

    private static func splitWords(_ s: String, maxLength: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for w in s.split(separator: " ").map(String.init) {
            var word = w
            while word.count > maxLength {          // an unbreakable run: hard split
                if !line.isEmpty { out.append(line); line = "" }
                out.append(String(word.prefix(maxLength)))
                word = String(word.dropFirst(maxLength))
            }
            if word.isEmpty { continue }
            if line.isEmpty { line = word }
            else if line.count + 1 + word.count <= maxLength { line += " " + word }
            else { out.append(line); line = word }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}

/// Shared HTTP step of the cloud engines.
enum VoiceHTTP {
    /// A sentence-sized request, fetched whole. Maps every failure to a VoiceError that cannot contain `secret`.
    static func fetchAudio(_ request: URLRequest, session: URLSession, secret: String, name: String,
                           log: @Sendable (String) -> Void) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let code = (error as? URLError)?.code.rawValue
            log("\(name): transport failure (\(code.map { "URLError \($0)" } ?? String(describing: type(of: error))))")
            throw VoiceError.network(code.map { "network error \($0)" } ?? "network error")
        }
        guard let http = response as? HTTPURLResponse else {
            log("\(name): not an HTTP response")
            throw VoiceError.network("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = clean(String(decoding: data.prefix(400), as: UTF8.self), removing: secret)
            log("\(name): HTTP \(http.statusCode)")
            throw VoiceError.network("HTTP \(http.statusCode)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        guard !data.isEmpty else {
            log("\(name): HTTP \(http.statusCode) with no audio")
            throw VoiceError.audio("the service returned no audio")
        }
        log("\(name): HTTP \(http.statusCode), \(data.count) bytes")
        return data
    }

    /// Short single-line error text with the key (and anything shaped like a bearer token) removed.
    static func clean(_ s: String, removing secret: String) -> String {
        var t = s.replacingOccurrences(of: secret, with: "[key]")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(t.prefix(160))
    }

    /// Plays one fetched clip unless `stop()` came in meanwhile.
    static func play(_ audio: Data, format: AudioFormat, with player: any AudioPlaying) async throws {
        do { try await player.play(audio, format: format) }
        catch let e as VoiceError { throw e }
        catch let e as CancellationError { throw e }
        catch { throw VoiceError.audio("playback failed") }
    }
}

/// `stop()` bumps the generation; a `speak` that started earlier sees the change and drops its remaining work.
final class StopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var generation: Int { lock.lock(); defer { lock.unlock() }; return value }
    func bump() { lock.lock(); value += 1; lock.unlock() }
}
