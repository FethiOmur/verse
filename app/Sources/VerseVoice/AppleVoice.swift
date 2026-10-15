import AVFoundation
import Foundation

/// A voice installed on this Mac, reduced to what the choice needs (and testable without AVFoundation).
public struct AppleVoiceInfo: Sendable, Equatable {
    public enum Quality: Int, Sendable, Comparable {
        case `default` = 0, enhanced, premium
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var label: String { self == .premium ? "premium" : self == .enhanced ? "enhanced" : "standard" }
    }
    public let id: String
    public let name: String
    public let language: String
    public let quality: Quality
    public let isNovelty: Bool
    public init(id: String, name: String, language: String, quality: Quality, isNovelty: Bool) {
        self.id = id; self.name = name; self.language = language; self.quality = quality; self.isNovelty = isNovelty
    }
}

/// The local voice: `AVSpeechSynthesizer`, free, offline. By default the best installed voice for the language
/// (premium, then enhanced, then standard; novelty voices never). Settings links to System Settings to download better ones.
public struct AppleVoice: VoiceEngine {
    public var kind: VoiceKind { .apple }
    public let voiceID: String?
    public let lang: String
    private let box = RunnerBox()

    /// - Parameters:
    ///   - voiceID: an `AVSpeechSynthesisVoice` identifier from `availableVoices`; nil picks the best for `lang`.
    ///   - lang: "en", "it", "tr" or a full locale such as "en-GB".
    public init(voiceID: String? = nil, lang: String = "en") {
        self.voiceID = voiceID
        self.lang = lang
    }

    public func speak(_ sentence: String) async throws {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let runner = await box.runner()
        let voice = await MainActor.run { Self.resolve(voiceID: voiceID, lang: lang) }
        try await withTaskCancellationHandler {
            try await runner.speak(text, voice: voice)
        } onCancel: {
            Task { @MainActor in runner.stop() }
        }
        try Task.checkCancellation()
    }

    public func stop() async { await box.runner().stop() }

    // MARK: selection

    /// The best voice for `lang`: highest quality, then an exact locale match, then the smallest id (deterministic).
    public static func best(of voices: [AppleVoiceInfo], lang: String) -> AppleVoiceInfo? {
        let want = normalized(lang)
        let wantPrimary = primary(want)
        return voices
            .filter { !$0.isNovelty && primary(normalized($0.language)) == wantPrimary }
            .sorted {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                let a = normalized($0.language) == want, b = normalized($1.language) == want
                if a != b { return a }
                return $0.id < $1.id
            }
            .first
    }

    /// The installed voices for the language, best first, for the Settings picker.
    public static func availableVoices(lang: String) -> [VoiceOption] {
        let want = primary(normalized(lang))
        return installed()
            .filter { !$0.isNovelty && primary(normalized($0.language)) == want }
            .sorted { $0.quality != $1.quality ? $0.quality > $1.quality : ($0.name, $0.id) < ($1.name, $1.id) }
            .map { VoiceOption(id: $0.id, name: $0.name, detail: "\($0.quality.label), \($0.language)") }
    }

    private static func normalized(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
    private static func primary(_ s: String) -> String { String(s.split(separator: "-").first ?? "") }

    private static func installed() -> [AppleVoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let q: AppleVoiceInfo.Quality = v.quality == .premium ? .premium : v.quality == .enhanced ? .enhanced : .default
            return AppleVoiceInfo(id: v.identifier, name: v.name, language: v.language, quality: q,
                                  isNovelty: v.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    @MainActor
    private static func resolve(voiceID: String?, lang: String) -> AVSpeechSynthesisVoice? {
        if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        guard let b = best(of: installed(), lang: lang) else { return nil }
        return AVSpeechSynthesisVoice(identifier: b.id)
    }
}

/// Creates the main-actor synthesizer on first use (the engine itself is a plain Sendable value).
private final class RunnerBox: @unchecked Sendable {
    @MainActor private var made: SpeechRunner?
    @MainActor func runner() -> SpeechRunner {
        if let r = made { return r }
        let r = SpeechRunner()
        made = r
        return r
    }
}

@MainActor
private final class SpeechRunner: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var waiter: CheckedContinuation<Void, any Error>?
    private var watchdog: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async throws {
        stop()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        // A synthesizer that never reports back (no output device, a broken voice) must not hang the interview.
        let limit = max(15.0, Double(text.count) * 0.25 + 10)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            waiter = c
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.synth.stopSpeaking(at: .immediate)
                self?.finish(.failure(VoiceError.audio("speech did not finish")))
            }
            synth.speak(u)
        }
    }

    /// Ends speech; a waiting `speak` returns normally.
    func stop() {
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        finish(.success(()))
    }

    private func finish(_ r: Swift.Result<Void, any Error>) {
        watchdog?.cancel()
        watchdog = nil
        guard let w = waiter else { return }
        waiter = nil
        w.resume(with: r)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(.success(())) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(.success(())) }
    }
}
