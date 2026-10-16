import Combine
import Foundation
import VerseMeet

// Read-only models for the home window's Sessions list and Prepare's "Up next". They read what the app already writes
// (session folders, the calendar); nothing here changes how sessions are made.

// MARK: - Sessions

public struct HomeSession: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case meeting = "Meeting", practice = "Practice", prepared = "Prepared", call = "Call" }

    public var id: String { name }
    public var name: String
    public var dir: URL
    public var kind: Kind
    public var title: String
    public var date: Date
    public var summaryURL: URL?
    public var reportURL: URL?
    public var transcriptURL: URL?
    public var spend: Double
    /// An adhoc session (started with ⌥⌘V and no prepared session): no pack, the Unprepared tag.
    public var unprepared = false
    /// "Phone", "Room" or "Meeting" for an adhoc session; nil for the others.
    public var routeLabel: String?

    /// The second line of a Sessions row after the day: the route of an adhoc session, else the kind.
    public var kindText: String { routeLabel ?? kind.rawValue }

    /// `sim-20261015-0930-brightwave` -> "Practice · brightwave"; `conv-20261015-1857-northwind-labs` -> "Northwind Labs".
    static func title(forFolder name: String) -> String {
        // A folder named like a title already reads as one.
        if name.contains(" "), !name.hasPrefix("sim-") { return name }
        // `adhoc-20261016-1432-room` -> "Call at 14:32".
        if SessionCatalog.isAdhoc(name) {
            let parts = name.split(separator: "-").map(String.init)
            if parts.count >= 3, parts[2].count == 4, parts[2].allSatisfy(\.isNumber) {
                return "Call at \(parts[2].prefix(2)):\(parts[2].suffix(2))"
            }
            return "Call"
        }
        var s = name
        var practice = false
        if s.hasPrefix("sim-") { practice = true; s.removeFirst(4) }
        if s.hasPrefix("conv-") { s.removeFirst(5) }
        // A leading yyyyMMdd-HHmm- stamp.
        let parts = s.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        var rest = parts[...]
        if rest.count >= 2, rest[rest.startIndex].count == 8, rest[rest.startIndex].allSatisfy(\.isNumber),
           rest[rest.startIndex + 1].count == 4, rest[rest.startIndex + 1].allSatisfy(\.isNumber) {
            rest = rest.dropFirst(2)
        }
        let words = rest.joined(separator: " ").split(separator: " ").map { String($0.prefix(1)).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let base = words.isEmpty ? name : words
        return practice ? "Practice · \(base)" : base
    }

    static func load(name: String, root: URL) -> HomeSession {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(name, isDirectory: true)
        func file(_ f: String) -> URL? {
            let u = dir.appendingPathComponent(f)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        let summary = file("summary.md"), report = file("report.html"), transcript = file("transcript.jsonl")
        let adhoc = SessionCatalog.isAdhoc(name) ? AdhocMeta.read(sessionDir: dir) : nil
        let kind: Kind = name.hasPrefix("sim-") ? .practice : (SessionCatalog.isAdhoc(name) ? .call : (summary != nil ? .meeting : .prepared))
        let date = (report ?? summary).flatMap(mtime) ?? file("meta.json").flatMap(mtime) ?? mtime(dir) ?? .distantPast
        let spend = SpendLedger.runs(sessionDir: dir).reduce(0) { $0 + $1.costUSD }
        var session = HomeSession(name: name, dir: dir, kind: kind, title: title(forFolder: name), date: date, summaryURL: summary,
                                  reportURL: report, transcriptURL: transcript, spend: spend)
        if kind == .call {
            session.unprepared = true
            // The route is in meta.json; a folder without one still carries it in its name (`adhoc-<stamp>-<route>`).
            let fromName = name.split(separator: "-").dropFirst(3).first.map(String.init)
            session.routeLabel = Self.routeLabel(adhoc?.route ?? fromName)
        }
        return session
    }

    /// `room` -> "Room".
    static func routeLabel(_ route: String?) -> String? {
        switch route {
        case "phone": return "Phone"
        case "room": return "Room"
        case "meeting": return "Meeting"
        default: return nil
        }
    }
}

@MainActor
public final class HomeSessionsModel: ObservableObject {
    @Published public private(set) var sessions: [HomeSession] = []
    public let root: URL

    public init(root: URL = SessionCatalog.root) {
        self.root = root
        reload()
    }

    /// Newest first.
    public func reload() {
        sessions = SessionCatalog.list(root: root).map { HomeSession.load(name: $0, root: root) }.sorted { $0.date > $1.date }
    }

    public func session(named name: String?) -> HomeSession? {
        guard let name else { return nil }
        return sessions.first { $0.name == name }
    }
}

/// What the Sessions detail shows, parsed from the session folder.
struct HomeSessionDetail: Equatable {
    struct Section: Equatable, Identifiable {
        var title: String
        var items: [String]
        var isParagraph: Bool
        var id: String { title }
    }

    var sections: [Section] = []
    /// The questions heard in the transcript (`kind: question`), once each.
    var questions: [String] = []

    /// `summary.md` has `## Heading` sections of paragraphs and `- ` bullets, after a `_generated …_` line and a
    /// `> DRAFT` note that are not content.
    static func parseSummary(_ text: String) -> [Section] {
        var out: [Section] = []
        var title: String?
        var items: [String] = []
        var paragraph = false
        func flush() {
            if let t = title, !items.isEmpty { out.append(Section(title: t, items: items, isParagraph: paragraph)) }
            items = []
            paragraph = false
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { flush(); title = String(line.dropFirst(3)); continue }
            guard title != nil, !line.hasPrefix(">"), !line.hasPrefix("_generated") else { continue }
            if line.hasPrefix("- ") {
                let item = String(line.dropFirst(2))
                if item != "(none)", !items.contains(item) { items.append(item) }
            } else {
                paragraph = true
                items.append(line)
            }
        }
        flush()
        return out
    }

    static func questions(transcript url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var byTurn: [(id: String, text: String)] = []
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["kind"] as? String == "question", let t = obj["text"] as? String, let id = obj["turn_id"] as? String else { continue }
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = byTurn.firstIndex(where: { $0.id == id }) { byTurn[i].text = clean } else { byTurn.append((id, clean)) }
        }
        var seen = Set<String>()
        return byTurn.map(\.text).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func load(_ s: HomeSession) -> HomeSessionDetail {
        var d = HomeSessionDetail()
        if let u = s.summaryURL, let t = try? String(contentsOf: u, encoding: .utf8) { d.sections = parseSummary(t) }
        if let u = s.transcriptURL { d.questions = questions(transcript: u) }
        return d
    }
}

/// Follow-up items he ticked, per session. Small, local, in the app's defaults suite.
@MainActor
struct HomeChecklistStore {
    var defaults = Bundle.main.bundleIdentifier == AppSettings.suiteName ? UserDefaults.standard
        : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard

    func done(session: String) -> Set<String> {
        Set(defaults.stringArray(forKey: "followUpDone.\(session)") ?? [])
    }

    func set(_ item: String, done on: Bool, session: String) {
        var s = done(session: session)
        if on { s.insert(item) } else { s.remove(item) }
        defaults.set(Array(s).sorted(), forKey: "followUpDone.\(session)")
    }
}

// MARK: - Up next

public struct HomeUpNextItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var meta: String
    /// The prepared session's folder name; nil when the event has none.
    public var session: String?
    public var event: MeetingEvent?

    public init(id: String, title: String, meta: String, session: String?, event: MeetingEvent? = nil) {
        self.id = id
        self.title = title
        self.meta = meta
        self.session = session
        self.event = event
    }
}

/// Calendar meetings in the next 36 hours, with whether each has a prepared session (the same match the "meeting
/// detected" prompt uses), and Prepare from an invite (the same call the prompt's Start makes).
@MainActor
public final class HomeUpNextModel: ObservableObject {
    @Published public private(set) var items: [HomeUpNextItem] = []
    @Published public private(set) var preparing: Set<String> = []
    @Published public private(set) var message: String?
    private var fixed = false

    private let settings: AppSettings
    private let meeting: MeetingSettings
    private let sessions: () -> [String]
    private let calendar: CalendarSource
    private let eventMap: EventSessionMap
    private let prepare: @Sendable (MeetingEvent, String) async throws -> URL
    private let onPrepared: @MainActor (String) -> Void
    static let window: TimeInterval = 36 * 3600

    public init(settings: AppSettings, meeting: MeetingSettings, sessions: @escaping () -> [String],
                calendar: CalendarSource = CalendarSource(), eventMap: EventSessionMap = EventSessionMap(),
                prepare: (@Sendable (MeetingEvent, String) async throws -> URL)? = nil,
                onPrepared: @escaping @MainActor (String) -> Void = { _ in }) {
        self.settings = settings
        self.meeting = meeting
        self.sessions = sessions
        self.calendar = calendar
        self.eventMap = eventMap
        self.onPrepared = onPrepared
        let brainDir = VerseController.brainDir()
        self.prepare = prepare ?? { event, lang in
            guard let brain = brainDir else { throw CalendarPrepError.brainDirNotFound("(not found)") }
            return try await CalendarPrep(brainDir: brain).makeSession(for: event, lang: lang)
        }
    }

    /// Fixed items for renders and tests.
    public func setItems(_ items: [HomeUpNextItem]) { self.items = items; fixed = true }

    public var calendarOn: Bool { meeting.useCalendar || fixed }

    public func refresh() async {
        guard !fixed else { return }
        guard meeting.useCalendar, calendar.authorization() == .fullAccess else {
            items = []
            return
        }
        let events = (try? await calendar.upcoming(within: Self.window)) ?? []
        let remembered = eventMap.load()
        let names = sessions()
        items = events.prefix(6).map { e in
            var prepared: String?
            if case .prepared(let n) = MeetingSessionResolver.plan(for: e, sessions: names, remembered: remembered, selected: nil) { prepared = n }
            return HomeUpNextItem(id: e.id, title: e.title, meta: Self.meta(e), session: prepared, event: e)
        }
    }

    public func prepare(_ item: HomeUpNextItem) {
        guard let event = item.event, !preparing.contains(item.id) else { return }
        preparing.insert(item.id)
        message = nil
        let lang = settings.language
        let prepare = self.prepare
        Task { @MainActor in
            defer { preparing.remove(item.id) }
            do {
                let dir = try await prepare(event, lang)
                eventMap.remember(eventID: event.id, session: dir.lastPathComponent)
                onPrepared(dir.lastPathComponent)
                await refresh()
            } catch {
                message = "Could not prepare \"\(item.title)\": \(error)"
            }
        }
    }

    /// "Today 14:30 · Zoom · in 4 minutes".
    static func meta(_ e: MeetingEvent, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(e.start) { day = "Today" } else if cal.isDateInTomorrow(e.start) { day = "Tomorrow" } else {
            day = e.start.formatted(HomeFormat.dayMonth)
        }
        var parts = ["\(day) \(e.start.formatted(HomeFormat.time))"]
        if e.provider != .other { parts.append(e.provider.displayName) }
        let minutes = Int(e.start.timeIntervalSince(now) / 60)
        if minutes > 0 && minutes < 90 { parts.append("in \(minutes) minute\(minutes == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
