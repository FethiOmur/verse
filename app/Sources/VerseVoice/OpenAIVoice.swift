import Foundation

// OpenAI text-to-speech over HTTPS with the user's own key (Keychain service `verse-openai`).
//
// Sources (official docs, read 2026-10-14):
// - Guide:     https://developers.openai.com/api/docs/guides/text-to-speech  (also https://platform.openai.com/docs/guides/text-to-speech)
// - Reference: https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create
//     POST https://api.openai.com/v1/audio/speech, header `Authorization: Bearer <key>`, JSON body
//     {model, input (max 4096 characters), voice, instructions (not for tts-1 / tts-1-hd), response_format (mp3|opus|aac|flac|wav|pcm),
//      speed (0.25 to 4.0), stream_format (sse|audio)}.
//     Models: gpt-4o-mini-tts (newest; steerable with `instructions`), gpt-4o-mini-tts-2025-12-15, tts-1, tts-1-hd.
//     Built-in voices: alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse, marin, cedar
//     ("for best quality, marin or cedar"); tts-1 and tts-1-hd support only alloy, ash, coral, echo, fable, onyx, nova, sage, shimmer.
//     A custom voice is sent as {"id": "voice_..."}.
//
// Choices:
// - Model `gpt-4o-mini-tts`, voice `marin` (the docs' recommendation).
// - `response_format: wav`: the docs recommend wav or pcm for the fastest response (no decode cost); AVAudioPlayer plays WAV from
//   memory. The reply is fetched whole per sentence; sentence-level pipelining is the caller's.
// - There is no endpoint to list voices: the names above are the list (`availableVoices`).
//
// Policy to surface in the UI (S4): OpenAI's usage policies require a clear disclosure to end users that the TTS voice is
// AI-generated (stated on the guide page above).
//
// NOT confirmed (no key was available; no live call was made):
// - The exact error body shape of failures (only the HTTP status is relied on).
// - Terms of service for desktop use with a user-supplied key were not read in full; the docs show no restriction on it.

public struct OpenAIVoice: VoiceEngine {
    public static let defaultModel = "gpt-4o-mini-tts"
    public static let defaultVoice = "marin"
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// The API accepts 4096 characters of input.
    static let maxChars = 4000

    public var kind: VoiceKind { .openai }
    public let voiceID: String
    public let model: String
    public let instructions: String?
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let player: any AudioPlaying
    private let log: @Sendable (String) -> Void
    private let gate = StopGate()

    /// - Parameters:
    ///   - instructions: optional delivery steering (e.g. "Calm, professional interviewer"); sent only for models that support it.
    ///   - keyProvider: the key at speak time; defaults to the Keychain. nil or blank gives `VoiceError.missingKey`.
    public init(voiceID: String = OpenAIVoice.defaultVoice,
                model: String = OpenAIVoice.defaultModel,
                instructions: String? = nil,
                keyProvider: @escaping @Sendable () -> String? = { VoiceKeys.read(.openai) },
                session: URLSession = .shared,
                player: any AudioPlaying = MemoryAudioPlayer(),
                log: @escaping @Sendable (String) -> Void = VoiceLog.default) {
        self.voiceID = voiceID
        self.model = model
        self.instructions = instructions
        self.keyProvider = keyProvider
        self.session = session
        self.player = player
        self.log = log
    }

    public func speak(_ sentence: String) async throws {
        let parts = VoiceText.chunks(sentence, maxLength: Self.maxChars)
        guard !parts.isEmpty else { return }
        guard let key = ElevenLabsVoice.usable(keyProvider()) else { log("openai: no key"); throw VoiceError.missingKey }
        let generation = gate.generation
        for part in parts {
            if gate.generation != generation { return }
            let request = try Self.request(key: key, model: model, voice: voiceID, instructions: instructions, text: part)
            log("openai: speaking \(part.count) characters, voice \(voiceID), model \(model)")
            let audio = try await VoiceHTTP.fetchAudio(request, session: session, secret: key, name: "openai", log: log)
            if gate.generation != generation { return }
            try await VoiceHTTP.play(audio, format: .wav, with: player)
        }
    }

    public func stop() async {
        gate.bump()
        await player.stop()
    }

    // MARK: voices for Settings

    private static let allVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"]
    private static let legacyVoices: Set<String> = ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]

    /// The model's built-in voice names (OpenAI has no list endpoint).
    public static func availableVoices(model: String = defaultModel) -> [VoiceOption] {
        let legacy = model.hasPrefix("tts-1")
        return allVoices.filter { !legacy || legacyVoices.contains($0) }.map {
            VoiceOption(id: $0, name: $0.capitalized, detail: ($0 == "marin" || $0 == "cedar") ? "recommended" : "")
        }
    }

    // MARK: request

    static func request(key: String, model: String, voice: String, instructions: String?, text: String) throws -> URLRequest {
        var body: [String: Any] = ["model": model, "input": text, "response_format": "wav"]
        body["voice"] = voice.hasPrefix("voice_") ? ["id": voice] : voice       // a custom voice is an object with an id
        if let instructions, !instructions.isEmpty, !model.hasPrefix("tts-1") { body["instructions"] = instructions }
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }
}
