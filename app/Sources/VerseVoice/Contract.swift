import Foundation

/// Which voice speaks the interviewer's lines. `text` means no audio: the line only appears in the overlay.
public enum VoiceKind: String, Codable, Sendable { case apple, elevenlabs, openai, text }

public protocol VoiceEngine: Sendable {
    var kind: VoiceKind { get }
    /// Speaks one sentence; returns when playback ends. Throws VoiceError on failure.
    /// `stop()` makes an in-flight `speak` return normally (it is not an error).
    func speak(_ sentence: String) async throws
    func stop() async
    /// Prepares one sentence without playing it (cloud engines fetch the audio; local ones return `.live`).
    /// The result lives in memory only. Throws VoiceError on failure.
    func synthesize(_ sentence: String) async throws -> SynthesizedSpeech
    /// Plays what `synthesize` returned; returns when playback ends. `stop()` makes it return normally.
    func play(_ speech: SynthesizedSpeech) async throws
}

/// One sentence prepared by a `VoiceEngine`. Audio stays in memory; nothing here is ever written to disk.
public struct SynthesizedSpeech: Sendable {
    public enum Payload: Sendable {
        /// Audio clips (one per request chunk) in `format`.
        case clips([Data], AudioFormat)
        /// Nothing to prepare: `play` speaks the text through the engine's own path (Apple voice, text-only).
        case live
    }
    public let text: String
    /// The engine that made it (a `FallbackVoice` uses this to route `play`).
    public let engine: VoiceKind
    public let payload: Payload
    public init(text: String, engine: VoiceKind, payload: Payload) { self.text = text; self.engine = engine; self.payload = payload }
    public static func live(_ text: String, engine: VoiceKind) -> SynthesizedSpeech {
        SynthesizedSpeech(text: text, engine: engine, payload: .live)
    }
    /// Memory held by the audio (0 for `.live`).
    public var byteCount: Int {
        if case .clips(let parts, _) = payload { return parts.reduce(0) { $0 + $1.count } }
        return 0
    }
}

extension VoiceEngine {
    /// Default: nothing to prepare.
    public func synthesize(_ sentence: String) async throws -> SynthesizedSpeech { .live(sentence, engine: kind) }
    /// Default: speak the text (right for `.live`; engines with clips override).
    public func play(_ speech: SynthesizedSpeech) async throws { try await speak(speech.text) }
}

public enum VoiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey
    case network(String)
    case audio(String)

    public var description: String {
        switch self {
        case .missingKey: return "No API key for this voice."
        case .network(let m): return "Voice service error: \(m)"
        case .audio(let m): return "Audio error: \(m)"
        }
    }

    /// Any error as a VoiceError (the engines only ever throw VoiceError; this is for foreign errors in a fallback).
    static func wrapping(_ error: any Error) -> VoiceError {
        if let e = error as? VoiceError { return e }
        if error is URLError { return .network((error as? URLError).map { "network error \($0.code.rawValue)" } ?? "network error") }
        return .audio(String(describing: type(of: error)))
    }
}

/// One selectable voice, for the Settings pickers (any engine).
public struct VoiceOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String = "") { self.id = id; self.name = name; self.detail = detail }
}

public struct VoiceFactory {
    /// `voiceID` is engine-specific: an AVSpeechSynthesisVoice identifier (Apple), an ElevenLabs voice id, an OpenAI voice name.
    /// nil picks the engine's default. Keys are read from the Keychain at speak time (`VoiceKeys`).
    public static func make(_ kind: VoiceKind, voiceID: String?) -> any VoiceEngine {
        switch kind {
        case .apple: return AppleVoice(voiceID: voiceID)
        case .elevenlabs: return ElevenLabsVoice(voiceID: voiceID ?? ElevenLabsVoice.defaultVoiceID)
        case .openai: return OpenAIVoice(voiceID: voiceID ?? OpenAIVoice.defaultVoice)
        case .text: return TextVoice()
        }
    }
}
