import Foundation

// ElevenLabs text-to-speech over HTTPS with the user's own key (Keychain service `verse-elevenlabs`).
//
// Sources (official docs, read 2026-10-14 through the .md versions of the pages):
// - Stream speech:   https://elevenlabs.io/docs/api-reference/text-to-speech/stream
//     POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream, header `xi-api-key`, JSON body {text (required),
//     model_id (default eleven_multilingual_v2), voice_settings, language_code, ...}, query `output_format` (default mp3_44100_128).
// - Create speech:   https://elevenlabs.io/docs/api-reference/text-to-speech/convert (same body, non-streaming response)
// - List voices:     https://elevenlabs.io/docs/api-reference/voices/search
//     GET https://api.elevenlabs.io/v2/voices?page_size=<=100&next_page_token=..., header `xi-api-key`;
//     response {voices:[{voice_id, name, category, labels{accent,gender,...}, ...}], has_more, next_page_token}.
// - Models:          https://elevenlabs.io/docs/overview/models
//     eleven_flash_v2_5 (~75 ms, 32 languages, 40,000-character limit), eleven_multilingual_v2 (10,000), eleven_v3 (5,000),
//     eleven_v4 / eleven_v4_turbo (new).
//
// Choices:
// - Model `eleven_flash_v2_5`: lowest latency, which matters for sentence-by-sentence turn-taking, and cheapest per character.
// - Output `mp3_44100_128`: the documented default; PCM at 44.1 kHz needs the Pro tier, so MP3 works on every plan. The reply is
//   fetched whole per sentence and played from memory (`AudioPlaying`); the "streaming" is sentence-level, done by the caller.
// - `/stream` endpoint rather than `/text-to-speech/{voice_id}`: same request, and the response may arrive chunked.
//
// NOT confirmed (no key was available; no live call was made):
// - Whether `eleven_v4` / `eleven_v4_turbo` are accepted by the plain text-to-speech endpoint: the models page says v4 is served
//   through the Text to Dialogue API. Not used here for that reason.
// - `defaultVoiceID` is the voice id from ElevenLabs' own code samples ("JBFqnCBsd6RMkjVDRZzb"); it is assumed to be available to
//   every account. A 404 falls back to Apple voice through `FallbackVoice`; Settings should let the user pick from `listVoices`.
// - Terms of service for desktop use with a user-supplied key were not read in full; the docs show no restriction on it.

public struct ElevenLabsVoice: VoiceEngine {
    public static let defaultModelID = "eleven_flash_v2_5"
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"
    static let outputFormat = "mp3_44100_128"
    static let host = URL(string: "https://api.elevenlabs.io")!
    /// Well under every model's limit (the smallest in use is 5,000 for eleven_v3).
    static let maxChars = 4500

    public var kind: VoiceKind { .elevenlabs }
    public let voiceID: String
    public let modelID: String
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let player: any AudioPlaying
    private let log: @Sendable (String) -> Void
    private let gate = StopGate()

    /// - Parameters:
    ///   - keyProvider: the key at speak time; defaults to the Keychain. nil or blank gives `VoiceError.missingKey`.
    ///   - session / player: injectable for tests (URLProtocol stub, fake player).
    public init(voiceID: String = ElevenLabsVoice.defaultVoiceID,
                modelID: String = ElevenLabsVoice.defaultModelID,
                keyProvider: @escaping @Sendable () -> String? = { VoiceKeys.read(.elevenlabs) },
                session: URLSession = .shared,
                player: any AudioPlaying = MemoryAudioPlayer(),
                log: @escaping @Sendable (String) -> Void = VoiceLog.default) {
        self.voiceID = voiceID
        self.modelID = modelID
        self.keyProvider = keyProvider
        self.session = session
        self.player = player
        self.log = log
    }

    public func speak(_ sentence: String) async throws {
        let parts = VoiceText.chunks(sentence, maxLength: Self.maxChars)
        guard !parts.isEmpty else { return }
        guard let key = Self.usable(keyProvider()) else { log("elevenlabs: no key"); throw VoiceError.missingKey }
        let request0 = try Self.request(voiceID: voiceID, modelID: modelID, key: key, text: parts[0])
        let generation = gate.generation
        for (i, part) in parts.enumerated() {
            if gate.generation != generation { return }
            var request = request0
            if i > 0 { request.httpBody = try Self.body(text: part, modelID: modelID) }
            log("elevenlabs: speaking \(part.count) characters, voice \(voiceID), model \(modelID)")
            let audio = try await VoiceHTTP.fetchAudio(request, session: session, secret: key, name: "elevenlabs", log: log)
            if gate.generation != generation { return }
            try await VoiceHTTP.play(audio, format: .mp3, with: player)
        }
    }

    public func synthesize(_ sentence: String) async throws -> SynthesizedSpeech {
        let parts = VoiceText.chunks(sentence, maxLength: Self.maxChars)
        guard !parts.isEmpty else { return .live(sentence, engine: kind) }
        guard let key = Self.usable(keyProvider()) else { log("elevenlabs: no key"); throw VoiceError.missingKey }
        let request0 = try Self.request(voiceID: voiceID, modelID: modelID, key: key, text: parts[0])
        var clips: [Data] = []
        for (i, part) in parts.enumerated() {
            var request = request0
            if i > 0 { request.httpBody = try Self.body(text: part, modelID: modelID) }
            log("elevenlabs: synthesizing \(part.count) characters, voice \(voiceID), model \(modelID)")
            clips.append(try await VoiceHTTP.fetchAudio(request, session: session, secret: key, name: "elevenlabs", log: log))
        }
        return SynthesizedSpeech(text: sentence, engine: kind, payload: .clips(clips, .mp3))
    }

    public func play(_ speech: SynthesizedSpeech) async throws {
        guard case .clips(let clips, let format) = speech.payload else { return try await speak(speech.text) }
        let generation = gate.generation
        for clip in clips {
            if gate.generation != generation { return }
            try await VoiceHTTP.play(clip, format: format, with: player)
        }
    }

    public func stop() async {
        gate.bump()
        await player.stop()
    }

    // MARK: voices for Settings

    /// The voices of the user's account (their own, saved and the default ones the API returns), all pages.
    public static func listVoices(keyProvider: @Sendable () -> String? = { VoiceKeys.read(.elevenlabs) },
                                  session: URLSession = .shared) async throws -> [VoiceOption] {
        guard let key = usable(keyProvider()) else { throw VoiceError.missingKey }
        var out: [VoiceOption] = []
        var token: String?
        for _ in 0..<10 {                                   // 10 pages of 100 is far more than any account has
            var c = URLComponents(url: host, resolvingAgainstBaseURL: false)!
            c.path = "/v2/voices"
            c.queryItems = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "include_total_count", value: "false")]
                + (token.map { [URLQueryItem(name: "next_page_token", value: $0)] } ?? [])
            var r = URLRequest(url: c.url!)
            r.httpMethod = "GET"
            r.timeoutInterval = 20
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await VoiceHTTP.fetchAudio(r, session: session, secret: key, name: "elevenlabs voices", log: { _ in })
            guard let page = try? JSONDecoder().decode(VoicePage.self, from: data) else { throw VoiceError.network("unexpected voice list") }
            out += page.voices.map { v in
                let detail = [v.category, v.labels?["accent"], v.labels?["gender"]].compactMap { $0 }.joined(separator: ", ")
                return VoiceOption(id: v.voice_id, name: v.name ?? v.voice_id, detail: detail)
            }
            guard page.has_more == true, let next = page.next_page_token, !next.isEmpty else { break }
            token = next
        }
        return out
    }

    private struct VoicePage: Decodable {
        struct Item: Decodable { let voice_id: String; let name: String?; let category: String?; let labels: [String: String]? }
        let voices: [Item]
        let has_more: Bool?
        let next_page_token: String?
    }

    // MARK: request

    static func request(voiceID: String, modelID: String, key: String, text: String) throws -> URLRequest {
        guard !voiceID.isEmpty, voiceID.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }) else {
            throw VoiceError.network("invalid voice id")
        }
        var c = URLComponents(url: host, resolvingAgainstBaseURL: false)!
        c.path = "/v1/text-to-speech/\(voiceID)/stream"
        c.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        r.httpBody = try body(text: text, modelID: modelID)
        return r
    }

    static func body(text: String, modelID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelID], options: [.sortedKeys])
    }

    static func usable(_ key: String?) -> String? {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }
}
