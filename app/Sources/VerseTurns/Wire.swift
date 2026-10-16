import Foundation

public enum Speaker: String, Sendable, Codable, Equatable {
    case remote, me
    /// Room route (anytime calls, phase A): the one microphone feeds the remote pipeline, so the other person and the
    /// room are not told apart from Alex. The brain treats it like `remote` with the addressee always `unknown`.
    case room
}

/// How a session was started (`start.mode`). Absent on the wire = prepared.
public enum SessionMode: String, Sendable, Codable, Equatable {
    case prepared, unprepared
}

/// Where the audio comes from (`start.route`). Absent on the wire = meeting.
public enum AudioRoute: String, Sendable, Codable, Equatable, CaseIterable {
    /// A meeting app's output (process tap) plus the microphone as `me`.
    case meeting
    /// A Continuity phone call answered on the Mac (phase B; until then it is not picked).
    case phone
    /// The microphone only, as the `room` speaker (a phone call on speaker next to the Mac).
    case room
}

/// `start.room_auto` (room route only): which room turns get a card by themselves.
public enum RoomAuto: String, Sendable, Codable, Equatable {
    case questions, off
}

/// `start.me`: the files of the permanent "me" layer (`~/Library/Application Support/Verse/profile/`).
public struct MeProfilePaths: Sendable, Equatable {
    public var core: String
    public var library: String
    public var facts: String

    public init(core: String, library: String, facts: String) {
        self.core = core
        self.library = library
        self.facts = facts
    }

    /// The default profile folder.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verse/profile", isDirectory: true)
    }

    public init(directory: URL = MeProfilePaths.defaultDirectory) {
        core = directory.appendingPathComponent("me.md").path
        library = directory.appendingPathComponent("me.library.jsonl").path
        facts = directory.appendingPathComponent("me.facts.jsonl").path
    }
}

public enum Addressee: String, Sendable, Codable, Equatable {
    case me, other, unknown
}

/// What a finished turn is, for the brain to weigh: a question (cue or wh/auxiliary question form), a plain
/// statement, or a fragment (a cut-off clause or fewer than three words).
public enum TurnKind: String, Sendable, Codable, Equatable {
    case question, statement, fragment
}

/// What the turn engine tells the outside world. `partial`, `turn` and `bankHit` encode to exactly the JSON lines
/// the brain reads (plan P1-2, `brain/verse_brain/runtime/protocol.py`); `chip` is for the overlay and never goes to
/// the brain.
public enum OutboundEvent: Codable, Sendable, Equatable {
    case partial(turnID: String, speaker: Speaker, text: String, cue: Bool, tAudioEnd: Double)
    case turn(turnID: String, speaker: Speaker, text: String, addressee: Addressee, tAudioEnd: Double, kind: TurnKind = .statement)
    case bankHit(turnID: String, bankID: String, score: Double)
    case chip(turnID: String, kind: String, text: String, sourceRef: String, factID: String)

    private enum Key: String, CodingKey {
        case type, turn_id, speaker, text, cue, t_audio_end, addressee, bank_id, score, kind, source_ref, fact_id, lang
    }

    /// `JSONEncoder.userInfo` key: the language tag a `partial` or `turn` line carries (spec 2.5, per-turn `lang`).
    static let langInfoKey = CodingUserInfoKey(rawValue: "verse.lang")!

    public var turnID: String {
        switch self {
        case .partial(let id, _, _, _, _), .turn(let id, _, _, _, _, _), .bankHit(let id, _, _), .chip(let id, _, _, _, _): return id
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
            try encodeLang(&c, encoder)
        case .turn(let id, let speaker, let text, let addressee, let t, let kind):
            try c.encode(id, forKey: .turn_id)
            try c.encode(speaker, forKey: .speaker)
            try c.encode(text, forKey: .text)
            try c.encode(addressee, forKey: .addressee)
            try c.encode(Text.ms(t), forKey: .t_audio_end)
            try c.encode(kind, forKey: .kind)
            try encodeLang(&c, encoder)
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

    private func encodeLang(_ c: inout KeyedEncodingContainer<Key>, _ encoder: Encoder) throws {
        if let lang = encoder.userInfo[Self.langInfoKey] as? String { try c.encode(lang, forKey: .lang) }
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
                         addressee: try c.decode(Addressee.self, forKey: .addressee), tAudioEnd: try c.decode(Double.self, forKey: .t_audio_end),
                         kind: try c.decodeIfPresent(TurnKind.self, forKey: .kind) ?? .statement)
        case "bank_hit":
            self = .bankHit(turnID: id, bankID: try c.decode(String.self, forKey: .bank_id), score: try c.decode(Double.self, forKey: .score))
        case "chip":
            self = .chip(turnID: id, kind: try c.decode(String.self, forKey: .kind), text: try c.decode(String.self, forKey: .text),
                         sourceRef: try c.decode(String.self, forKey: .source_ref), factID: try c.decodeIfPresent(String.self, forKey: .fact_id) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type")
        }
    }

    /// Decodes one line, or nil when it is not a known event. Older and newer builds of the two sides can disagree about
    /// which event types exist; the unknown ones are skipped, never an error for the stream.
    public static func decodeLenient(_ line: String) -> OutboundEvent? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OutboundEvent.self, from: d)
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

    /// The same line with `"lang"` ("en" | "it" | "tr") on a `partial` or `turn`: the language of that turn's text, which the brain
    /// answers in. nil leaves the line as `jsonLine()` makes it.
    public func jsonLine(lang: String?) -> String {
        guard let lang else { return jsonLine() }
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        e.userInfo[Self.langInfoKey] = lang
        return String(decoding: (try? e.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// The messages Swift sends to the brain that are not turn events.
public enum BrainCommand: Sendable, Equatable {
    /// `follow`: the brain may watch the owner's own speech and send follow cards (spec "follow my answer"). Always sent
    /// explicitly, so the brain never has to guess a default.
    ///
    /// The anytime-calls fields (spec 3) are sent only when set; absent means today's behaviour (prepared, meeting,
    /// no me layer), so a session that sets none of them produces exactly the line it always did.
    case start(sessionDir: String, lang: String, follow: Bool = false, mode: SessionMode? = nil, route: AudioRoute? = nil,
               me: MeProfilePaths? = nil, roomAuto: RoomAuto? = nil)
    case stop
    case summarize
    /// Answer the latest remote/room turn now: the open partial, else the last final.
    case cardNow
    /// The session language from now on (the speech engines restart on the Swift side).
    case setLanguage(String)
    /// The audio route of the running call changed (the listen pipeline was swapped in place); the session goes on. `roomAuto`
    /// (room route only) and `follow` (the user's setting, not yet gated by the route) are sent when the brain cannot know
    /// them from `start`: a call that began in the meeting never got `room_auto`, one that began in the room got `follow:false`.
    case setRoute(AudioRoute, roomAuto: RoomAuto? = nil, follow: Bool? = nil)

    public func jsonLine() -> String {
        var obj: [String: Any]
        switch self {
        case .start(let dir, let lang, let follow, let mode, let route, let me, let roomAuto):
            obj = ["type": "start", "session_dir": dir, "lang": lang, "follow": follow]
            if let mode { obj["mode"] = mode.rawValue }
            if let route { obj["route"] = route.rawValue }
            if let me { obj["me"] = ["core": me.core, "library": me.library, "facts": me.facts] }
            if let roomAuto { obj["room_auto"] = roomAuto.rawValue }
        case .stop: obj = ["type": "control", "action": "stop"]
        case .summarize: obj = ["type": "control", "action": "summarize"]
        case .cardNow: obj = ["type": "control", "action": "card_now"]
        case .setLanguage(let lang): obj = ["type": "control", "action": "lang", "lang": lang]
        case .setRoute(let route, let roomAuto, let follow):
            obj = ["type": "control", "action": "route", "route": route.rawValue]
            if let roomAuto { obj["room_auto"] = roomAuto.rawValue }
            if let follow { obj["follow"] = follow }
        }
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}

/// One pair of the me layer and the meeting pack that disagree on a number (`notice{kind:"me_conflicts"}`).
public struct MeConflict: Sendable, Equatable {
    public var me: String
    public var pack: String
    public var topic: String
}

/// What the brain tells the front end beyond cards (`notice`, spec 3). Unknown kinds, and unknown event types, decode to
/// nil: an older build of the app must keep working when the brain learns a new notice.
public enum BrainNotice: Sendable, Equatable {
    case meConflicts([MeConflict])
    /// `start.me` named files that do not exist: the session runs without the layer.
    case meMissing

    public init?(_ o: [String: JSONValue]) {
        guard o.type == "notice" else { return nil }
        switch o[string: "kind"] {
        case "me_conflicts":
            let items = (o["items"]?.array ?? []).compactMap { v -> MeConflict? in
                guard case .object(let it) = v, let me = it[string: "me"], let pack = it[string: "pack"] else { return nil }
                return MeConflict(me: me, pack: pack, topic: it[string: "topic"] ?? "")
            }
            self = .meConflicts(items)
        case "me_missing":
            self = .meMissing
        default:
            return nil
        }
    }
}

/// The `me` field of the brain's `ready` status: how big the layer is and when it was built (nil: no layer).
public struct MeLayerInfo: Sendable, Equatable {
    public var tokens: Int
    public var builtAt: String

    public init?(readyStatus o: [String: JSONValue]) {
        guard o.type == "status", o[string: "state"] == "ready", case .object(let me)? = o["me"],
              let t = me["tokens"]?.double else { return nil }
        tokens = Int(t)
        builtAt = me[string: "built_at"] ?? ""
    }
}
