import Foundation
import VerseMeet

/// Finds the prepared session for a calendar event. A session is "its prepared session" when
/// 1. the app prepared it from this very event before (`EventSessionMap`, the event id), or
/// 2. exactly one session folder is named like the event (letters and digits equal, one inside the other:
///    `mara-northwindlabs` for "Mara / Northwind Labs call").
/// Otherwise there is none and Start builds one from the invite.
public enum MeetingSessionResolver {
    public static func plan(for event: MeetingEvent?, sessions: [String], remembered: [String: String],
                            selected: String?) -> MeetingPrompt.SessionPlan {
        guard let event else { return .selected(selected.flatMap { sessions.contains($0) ? $0 : nil } ?? sessions.first) }
        if let name = remembered[event.id], sessions.contains(name) { return .prepared(name) }
        let title = squash(event.title)
        if title.count >= 4 {
            let named = sessions.filter { s in
                let n = squash(s)
                return n.count >= 4 && (title.contains(n) || n.contains(title))
            }
            if named.count == 1 { return .prepared(named[0]) }
        }
        return .fromInvite
    }

    /// Letters and digits only, lower case, accents folded.
    static func squash(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Event id -> session folder name, for sessions the app prepared from an event. A small JSON file in Application Support.
public struct EventSessionMap: Sendable {
    public var url: URL

    public init(url: URL = Self.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verse/event-sessions.json")
    }

    public func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    public func remember(eventID: String, session: String) {
        var m = load()
        m[eventID] = session
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Drops every event that points at `session` (the session is gone). Returns the event ids it removed, so an undo can put them
    /// back. Writes nothing when no event points there.
    @discardableResult
    public func forget(session: String) -> [String] {
        var m = load()
        let ids = m.filter { $0.value == session }.map(\.key).sorted()
        guard !ids.isEmpty else { return [] }
        for id in ids { m[id] = nil }
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
        return ids
    }

    /// Puts `eventID` -> `session` back, unless the event has been mapped to a session since.
    public func restore(eventID: String, session: String) {
        guard load()[eventID] == nil else { return }
        remember(eventID: eventID, session: session)
    }
}
