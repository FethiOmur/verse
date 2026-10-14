import Foundation

public enum Speaker: String, Sendable, Codable, Equatable {
    case remote, me
}

public enum Addressee: String, Sendable, Codable, Equatable {
    case me, other, unknown
}

/// What the turn engine tells the outside world. `partial`, `turn` and `bankHit` encode to exactly the JSON lines
/// the brain reads (plan P1-2, `brain/verse_brain/runtime/protocol.py`); `chip` is for the overlay and never goes to
/// the brain.
public enum OutboundEvent: Codable, Sendable, Equatable {
    case partial(turnID: String, speaker: Speaker, text: String, cue: Bool, tAudioEnd: Double)
    case turn(turnID: String, speaker: Speaker, text: String, addressee: Addressee, tAudioEnd: Double)
    case bankHit(turnID: String, bankID: String, score: Double)
    case chip(turnID: String, kind: String, text: String, sourceRef: String, factID: String)

    private enum Key: String, CodingKey {
        case type, turn_id, speaker, text, cue, t_audio_end, addressee, bank_id, score, kind, source_ref, fact_id
    }

    public var turnID: String {
        switch self {
        case .partial(let id, _, _, _, _), .turn(let id, _, _, _, _), .bankHit(let id, _, _), .chip(let id, _, _, _, _): return id
        }
    }

    public var typeName: String {
        switch self {
        case .partial: return "partial"
        case .turn: return "turn"
        case .bankHit: return "bank_hit"
        case .chip: return "chip"
        }
    }

    /// True for the events the brain consumes.
    public var isForBrain: Bool {
        if case .chip = self { return false }
        return true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .partial(let id, let speaker, let text, let cue, let t):
            try c.encode(id, forKey: .turn_id)
            try c.encode(speaker, forKey: .speaker)
            try c.encode(text, forKey: .text)
            try c.encode(cue, forKey: .cue)
            try c.encode(Text.ms(t), forKey: .t_audio_end)
        case .turn(let id, let speaker, let text, let addressee, let t):
            try c.encode(id, forKey: .turn_id)
            try c.encode(speaker, forKey: .speaker)
            try c.encode(text, forKey: .text)
            try c.encode(addressee, forKey: .addressee)
            try c.encode(Text.ms(t), forKey: .t_audio_end)
        case .bankHit(let id, let bank, let score):
            try c.encode(id, forKey: .turn_id)
            try c.encode(bank, forKey: .bank_id)
            try c.encode((score * 1000).rounded() / 1000, forKey: .score)
        case .chip(let id, let kind, let text, let ref, let factID):
            try c.encode(id, forKey: .turn_id)
            try c.encode(kind, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(ref, forKey: .source_ref)
            try c.encode(factID, forKey: .fact_id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let id = try c.decode(String.self, forKey: .turn_id)
        switch try c.decode(String.self, forKey: .type) {
        case "partial":
            self = .partial(turnID: id, speaker: try c.decode(Speaker.self, forKey: .speaker), text: try c.decode(String.self, forKey: .text),
                            cue: try c.decode(Bool.self, forKey: .cue), tAudioEnd: try c.decode(Double.self, forKey: .t_audio_end))
        case "turn":
            self = .turn(turnID: id, speaker: try c.decode(Speaker.self, forKey: .speaker), text: try c.decode(String.self, forKey: .text),
                         addressee: try c.decode(Addressee.self, forKey: .addressee), tAudioEnd: try c.decode(Double.self, forKey: .t_audio_end))
        case "bank_hit":
            self = .bankHit(turnID: id, bankID: try c.decode(String.self, forKey: .bank_id), score: try c.decode(Double.self, forKey: .score))
        case "chip":
            self = .chip(turnID: id, kind: try c.decode(String.self, forKey: .kind), text: try c.decode(String.self, forKey: .text),
                         sourceRef: try c.decode(String.self, forKey: .source_ref), factID: try c.decodeIfPresent(String.self, forKey: .fact_id) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// One compact JSON object, no trailing newline.
    public func jsonLine() -> String {
        String(decoding: (try? Self.encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// The two brain messages that are not turn events.
public enum BrainCommand: Sendable, Equatable {
    case start(sessionDir: String, lang: String)
    case stop
    case summarize

    public func jsonLine() -> String {
        let obj: [String: Any]
        switch self {
        case .start(let dir, let lang): obj = ["type": "start", "session_dir": dir, "lang": lang]
        case .stop: obj = ["type": "control", "action": "stop"]
        case .summarize: obj = ["type": "control", "action": "summarize"]
        }
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}
