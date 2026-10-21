import Foundation

// The pre-meeting brief, app side (memory spec 2.4, 3.5): the request the app sends, the file the brain writes, and how the app reads it.
// A brief is a short list of cited points in five sections; the brain writes the file, the app only reads it. Nothing here calls a model.

// MARK: - Request

/// What `brief_start` carries (spec 3.5). `sessions` are the entity's past sessions, newest first; attendee emails never go here.
struct BriefRequest: Equatable, Sendable {
    struct Entity: Equatable, Sendable {
        var id: String
        /// `person` or `company`.
        var kind: String
        var name: String
        var company: String?
    }

    struct Upcoming: Equatable, Sendable {
        var title: String
        var start: Date
        /// Names only.
        var attendees: [String]
    }

    var entity: Entity
    var sessions: [String]
    var upcoming: Upcoming?
    var lang: String
    /// The prepared session's folder when the brief is for one: the brain also writes `brief.json` and `brief.md` there.
    var sessionOut: URL?
    var model = "sonnet"

    /// The first line the brain reads (its mode switch). Keys are sorted so the line is deterministic.
    func startLine(db: URL, out: URL, ownerName: String, timeZone: TimeZone = .current) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        var entityObj: [String: Any] = ["id": entity.id, "kind": entity.kind, "name": entity.name]
        entityObj["company"] = entity.company ?? NSNull()
        var obj: [String: Any] = [
            "type": "brief_start", "db": db.path, "owner_name": ownerName, "entity": entityObj, "sessions": sessions,
            "lang": lang, "out": out.path, "model": model,
        ]
        obj["session_out"] = sessionOut?.path ?? NSNull()
        if let upcoming {
            obj["upcoming"] = ["title": upcoming.title, "start": iso.string(from: upcoming.start), "attendees": upcoming.attendees] as [String: Any]
        } else {
            obj["upcoming"] = NSNull()
        }
        return AskWire.line(obj)
    }
}

// MARK: - File

/// `brief.json` (both locations, spec 3.5). Keys are snake_case on disk.
struct BriefFile: Codable, Equatable, Sendable {
    struct SessionRef: Codable, Equatable, Sendable {
        var name: String
        var key: String
        var title: String
        var date: String
    }

    /// One citation: `kind` is `turn`, `summary`, `prep` or `chat`; `stamp` is set for a turn.
    struct Cite: Codable, Equatable, Sendable {
        var key: String
        var session: String
        var kind: String
        var stamp: String?
    }

    struct Point: Codable, Equatable, Sendable {
        var text: String
        var cites: [Cite]
    }

    /// `id` is one of `discussed`, `promised_owner`, `promised_them`, `open`, `tone`.
    struct Section: Codable, Equatable, Sendable {
        var id: String
        var points: [Point]
    }

    var version: Int
    var entity: String
    var name: String
    var madeAt: Date
    var lang: String
    var model: String
    var newestSession: String
    var forSession: String?
    var sessions: [SessionRef]
    var sections: [Section]
    var costUSD: Double
    var droppedUncited: Int

    enum CodingKeys: String, CodingKey {
        case version, entity, name, lang, model, sessions, sections
        case madeAt = "made_at", newestSession = "newest_session", forSession = "for_session"
        case costUSD = "cost_usd", droppedUncited = "dropped_uncited"
    }

    /// True when the entity has a newer session than the one this brief was made from. `nil` (no session known) is never stale.
    func isStale(newestSession: String?) -> Bool {
        guard let newestSession else { return false }
        return newestSession != self.newestSession
    }
}

extension BriefFile {
    /// Tolerant of the optional fields: a brief without a cost or a drop count still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        entity = try c.decode(String.self, forKey: .entity)
        name = try c.decode(String.self, forKey: .name)
        madeAt = try c.decode(Date.self, forKey: .madeAt)
        lang = try c.decode(String.self, forKey: .lang)
        model = try c.decode(String.self, forKey: .model)
        newestSession = try c.decode(String.self, forKey: .newestSession)
        forSession = try c.decodeIfPresent(String.self, forKey: .forSession)
        sessions = try c.decode([SessionRef].self, forKey: .sessions)
        sections = try c.decode([Section].self, forKey: .sections)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        droppedUncited = try c.decodeIfPresent(Int.self, forKey: .droppedUncited) ?? 0
    }
}

// MARK: - Store

/// Reads briefs. A missing or unreadable file is `nil`; nothing here writes (the brain does).
enum BriefStore {
    static func load(entity id: String, paths: MemoryPaths) -> BriefFile? { load(url: paths.brief(entity: id)) }

    /// `<session>/brief.json`, written when the brief was made for that prepared session.
    static func load(sessionDir: URL) -> BriefFile? { load(url: sessionDir.appendingPathComponent("brief.json")) }

    static func load(url: URL) -> BriefFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return decode(d)
    }

    static func decode(_ data: Data) -> BriefFile? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = plain.date(from: s) ?? fractional.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        return try? dec.decode(BriefFile.self, from: data)
    }
}
