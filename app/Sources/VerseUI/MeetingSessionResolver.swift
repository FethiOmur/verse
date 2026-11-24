import Foundation
import VerseMeet

/// Finds the prepared session for a calendar event (`match`, one rule for the prompt, Up next, Practice, Start now and the
/// session auto-select). The first that holds wins:
/// 1. a link to this occurrence (`EventSessionMap`, key `MeetingEvent.occurrenceKey`): the app prepared the session from it, or he
///    chose the session for it;
/// 2. a link to the series: the bare event id (links written before occurrences, and series linked on purpose); for an event known
///    not to repeat, also the one session every occurrence link of this id points to (a moved event keeps its session);
/// 3. a session folder whose `event.json` (`EventSidecar`) names this occurrence, else (only for an event known not to repeat) this
///    event id; exactly one folder;
/// 4. the folder name: every token of 3+ letters or digits in the folder name is a word of the title or of an attendee's name (two
///    neighbouring words count as one token: `northwindlabs` in "Northwind Labs"), in any order; exactly one folder.
/// Otherwise there is none ("not prepared"). Never a guess, an alphabetical pick or a recency pick.
public enum MeetingSessionResolver {
    public static func plan(for event: MeetingEvent?, sessions: [String], remembered: [String: String],
                            selected: String?, sidecars: [String: EventSidecar] = [:]) -> MeetingPrompt.SessionPlan {
        guard let event else { return .selected(selected.flatMap { sessions.contains($0) ? $0 : nil } ?? sessions.first) }
        if let m = match(event, sessions: sessions, links: remembered, sidecars: sidecars) { return .prepared(m.session) }
        return .unprepared
    }

    /// The prepared session of `event` among `sessions`, and which rule found it; nil when there is none.
    public static func match(_ event: MeetingEvent, sessions: [String], links: [String: String],
                             sidecars: [String: EventSidecar] = [:]) -> SessionMatch? {
        let exists = Set(sessions)
        // 1. this occurrence
        if let s = links[event.occurrenceKey], exists.contains(s) { return SessionMatch(session: s, source: .occurrenceLink) }
        // 2. the series
        if let s = links[event.id], exists.contains(s) { return SessionMatch(session: s, source: .seriesLink) }
        // Occurrences of a repeating event share the id: a link to last week's occurrence is not this week's session (G10, and
        // each occurrence gets its own prep). Only an event known to be a one-off may follow its id to a moved occurrence.
        let oneOff = event.isRecurring == false
        if oneOff {
            let sameSeries = Set(links.filter { MeetingEvent.eventID(fromLinkKey: $0.key) == event.id && $0.key != event.id }
                .map(\.value).filter(exists.contains))
            if sameSeries.count == 1, let s = sameSeries.first { return SessionMatch(session: s, source: .seriesLink) }
        }
        // 3. the folder's own event.json
        let carried = sessions.compactMap { name in sidecars[name].map { (name, $0) } }
        let byOccurrence = carried.filter { $0.1.occurrenceKey == event.occurrenceKey }
        if byOccurrence.count == 1 { return SessionMatch(session: byOccurrence[0].0, source: .sidecar) }
        if byOccurrence.isEmpty, oneOff {
            let byID = carried.filter { $0.1.eventID == event.id }
            if byID.count == 1 { return SessionMatch(session: byID[0].0, source: .sidecar) }
        }
        // 4. the folder name
        let words = tokens(event.title) + event.attendees.flatMap { tokens($0.name ?? "") }
        guard !words.isEmpty else { return nil }
        let named = sessions.filter { nameMatches(folder: $0, words: words) }
        return named.count == 1 ? SessionMatch(session: named[0], source: .name) : nil
    }

    /// Lower-case words of letters and digits, accents folded: "Mara / Northwind-Labs" -> ["mara", "northwind", "labs"].
    static func tokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")).lowercased()
        return folded.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
    }

    /// The folder name's tokens that count (3+ characters).
    static func folderTokens(_ folder: String) -> [String] { tokens(folder).filter { $0.count >= 3 } }

    /// Every counted token of `folder` is one of `words`, or two or more neighbouring words written together. A folder with no
    /// counted token never matches.
    static func nameMatches(folder: String, words: [String]) -> Bool {
        let need = folderTokens(folder)
        guard !need.isEmpty else { return false }
        return need.allSatisfy { t in
            for i in words.indices {
                var joined = ""
                for w in words[i...] {
                    joined += w
                    if joined == t { return true }
                    if joined.count >= t.count || !t.hasPrefix(joined) { break }
                }
            }
            return false
        }
    }

    /// Letters and digits only, lower case, accents folded.
    static func squash(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Which rule of `MeetingSessionResolver.match` found the session.
public struct SessionMatch: Equatable, Sendable {
    public enum Source: String, Sendable, Equatable {
        case occurrenceLink, seriesLink, sidecar, name
    }
    public var session: String
    public var source: Source

    public init(session: String, source: Source) {
        self.session = session
        self.source = source
    }
}

/// Everything `match` reads, loaded once: the session list, `event-sessions.json` and the folders' `event.json` files.
public struct SessionMatcher: Sendable, Equatable {
    public var sessions: [String]
    public var links: [String: String]
    public var sidecars: [String: EventSidecar]

    public init(sessions: [String], links: [String: String] = [:], sidecars: [String: EventSidecar] = [:]) {
        self.sessions = sessions
        self.links = links
        self.sidecars = sidecars
    }

    public static func load(sessions: [String], root: URL, eventMap: EventSessionMap) -> SessionMatcher {
        SessionMatcher(sessions: sessions, links: eventMap.load(), sidecars: EventSidecar.loadAll(sessions: sessions, root: root))
    }

    public func match(_ event: MeetingEvent) -> SessionMatch? {
        MeetingSessionResolver.match(event, sessions: sessions, links: links, sidecars: sidecars)
    }
}

/// `<session>/event.json`: the calendar event a session was prepared for. Swift writes it after a prep from an event (the brain's
/// own files are not changed); the matcher reads it and the session pickers label the session by its title and date. It holds the
/// occurrence key, the event id, title, start, end and the attendees' email addresses (G14); never the notes.
public struct EventSidecar: Codable, Sendable, Equatable {
    public static let fileName = "event.json"

    public var occurrenceKey: String?
    public var eventID: String?
    public var title: String?
    public var start: Date?
    public var end: Date?
    /// The invite's attendees by email address (lower case, owner included when he is on the list); nil in files written before.
    public var attendeeEmails: [String]?

    enum CodingKeys: String, CodingKey {
        case occurrenceKey = "occurrence_key", eventID = "event_id", title, start, end, attendeeEmails = "attendee_emails"
    }

    public init(occurrenceKey: String?, eventID: String?, title: String? = nil, start: Date? = nil, end: Date? = nil,
                attendeeEmails: [String]? = nil) {
        self.occurrenceKey = occurrenceKey
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.attendeeEmails = attendeeEmails
    }

    public init(event: MeetingEvent) {
        let emails = event.attendees.compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty }
        self.init(occurrenceKey: event.occurrenceKey, eventID: event.id, title: event.title, start: event.start, end: event.end,
                  attendeeEmails: emails)
    }

    public static func read(sessionDir: URL) -> EventSidecar? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent(fileName)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(EventSidecar.self, from: d)
    }

    public func write(sessionDir: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(self).write(to: sessionDir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Session name -> its sidecar, for the sessions that have one.
    public static func loadAll(sessions: [String], root: URL) -> [String: EventSidecar] {
        var out: [String: EventSidecar] = [:]
        for name in sessions {
            if let s = read(sessionDir: SessionCatalog.url(name, root: root)) { out[name] = s }
        }
        return out
    }
}

/// Link key -> session folder name, for sessions the app prepared from an event or he chose for one. A small JSON file in
/// Application Support. New keys are `MeetingEvent.occurrenceKey` (`id@start`); bare event ids from before stay valid and link the
/// whole series.
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

    /// Links this occurrence of `event` to `session`.
    public func link(_ event: MeetingEvent, session: String) {
        remember(eventID: event.occurrenceKey, session: session)
    }

    /// A session was prepared from `event` (Up next's Prepare, Practice's Upcoming, the background prep): this occurrence is linked
    /// to the folder and the folder gets its `event.json` (G14). When the sidecar cannot be written the link alone still matches;
    /// the pickers then show the folder name.
    public func recordPrep(_ event: MeetingEvent, sessionDir: URL) {
        link(event, session: sessionDir.lastPathComponent)
        try? EventSidecar(event: event).write(sessionDir: sessionDir)
    }

    /// Links every occurrence of `event` (its bare id) to `session`.
    public func linkSeries(_ event: MeetingEvent, session: String) {
        remember(eventID: event.id, session: session)
    }

    /// Writes one key (an occurrence key or a bare event id).
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
