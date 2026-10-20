import Combine
import Foundation
import VerseMeet

// Read-only models for the home window's Sessions list and Prepare's "Up next". They read what the app already writes
// (session folders, the calendar); nothing here changes how sessions are made.

// MARK: - Sessions

public struct HomeSession: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case meeting = "Meeting", practice = "Practice", prepared = "Prepared", call = "Call"

        /// The name in the interface language (the raw value is the English identifier).
        public var label: String {
            switch self {
            case .meeting: L10n.tr("Meeting")
            case .practice: L10n.tr("Practice")
            case .prepared: L10n.tr("Prepared")
            case .call: L10n.tr("Call")
            }
        }
    }

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
    /// What the folder suggester reads (F3): company names, the source session of a practice run, FACTS names.
    var folderSignals = FolderSignals()

    /// The second line of a Sessions row after the day: the route of an adhoc session, else the kind.
    public var kindText: String { routeLabel ?? kind.label }

    /// `sim-20261015-0930-brightwave` -> "Practice · brightwave"; `conv-20261015-1857-northwind-labs` -> "Northwind Labs".
    static func title(forFolder name: String) -> String {
        // A folder named like a title already reads as one.
        if name.contains(" "), !name.hasPrefix("sim-") { return name }
        // `adhoc-20261016-1432-room` -> "Call at 14:32".
        if SessionCatalog.isAdhoc(name) {
            let parts = name.split(separator: "-").map(String.init)
            if parts.count >= 3, parts[2].count == 4, parts[2].allSatisfy(\.isNumber) {
                return L10n.tr("Call at \(String(parts[2].prefix(2))):\(String(parts[2].suffix(2)))")
            }
            return L10n.tr("Call")
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
        return practice ? L10n.tr("Practice · \(base)") : base
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
        session.folderSignals = FolderSuggester.signals(folderName: name, title: session.title, dir: dir)
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
        case "phone": return L10n.tr("Phone")
        case "room": return L10n.tr("Room")
        case "meeting": return L10n.tr("Meeting")
        default: return nil
        }
    }
}

/// How the list column groups its rows: by folder, or one flat list newest first.
enum SessionsListMode: String, Equatable {
    case folders, recent
}

/// One group of the list column: a folder, or the sessions that are in none.
struct HomeSessionSection: Identifiable, Equatable {
    /// The folder id, or `HomeSessionSection.noFolderID`.
    var id: String
    /// nil for "No folder".
    var folder: SessionFolder?
    /// Newest first.
    var sessions: [HomeSession]

    static let noFolderID = "_none"
}

@MainActor
public final class HomeSessionsModel: ObservableObject {
    @Published public private(set) var sessions: [HomeSession] = []
    @Published private(set) var storedMode: SessionsListMode?
    @Published private(set) var collapsed: Set<String> = []
    public let root: URL
    /// Which folder each session is in (`folders.json`); sessions themselves never move.
    let folders: SessionFolderStore
    private let defaults: UserDefaults
    private var storeChange: AnyCancellable?

    static let modeKey = "sessionsListMode"
    static let collapsedKey = "sessionsCollapsedFolders"

    /// `defaults` holds the list mode and the collapsed sections; nil is the app's own suite.
    public init(root: URL = SessionCatalog.root, defaults: UserDefaults? = nil) {
        self.root = root
        self.defaults = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? UserDefaults.standard
            : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        folders = SessionFolderStore(root: root)
        storedMode = self.defaults.string(forKey: Self.modeKey).flatMap(SessionsListMode.init(rawValue:))
        collapsed = Set(self.defaults.stringArray(forKey: Self.collapsedKey) ?? [])
        // The views watch the model; a folder change must repaint them.
        storeChange = folders.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        reload()
    }

    /// Newest first.
    public func reload() {
        // The standing general prep is shown on the Me page, not as a session row.
        sessions = SessionCatalog.list(root: root).filter { !GeneralPrep.isGeneral($0) }.map { HomeSession.load(name: $0, root: root) }.sorted { $0.date > $1.date }
        autoAssignDerived()
    }

    public func session(named name: String?) -> HomeSession? {
        guard let name else { return nil }
        return sessions.first { $0.name == name }
    }

    // MARK: grouping

    /// Folders when at least one folder exists and he did not pick Recent; Recent otherwise. The picker shows only once a
    /// folder exists.
    var mode: SessionsListMode {
        folders.folders.isEmpty ? .recent : (storedMode ?? .folders)
    }

    func setMode(_ m: SessionsListMode) {
        storedMode = m
        defaults.set(m.rawValue, forKey: Self.modeKey)
    }

    func folder(of session: HomeSession) -> SessionFolder? { folders.folder(of: session.name) }

    /// One section per folder (ordered by its newest session; empty folders after them, alphabetically), then "No folder"
    /// when it has sessions. Rows are newest first.
    var sections: [HomeSessionSection] {
        var byFolder: [String: [HomeSession]] = [:]
        var loose: [HomeSession] = []
        for s in sessions {
            if let f = folders.folder(of: s.name) { byFolder[f.id, default: []].append(s) } else { loose.append(s) }
        }
        let filled = folders.folders.filter { !(byFolder[$0.id] ?? []).isEmpty }
            .sorted { (byFolder[$0.id]?.first?.date ?? .distantPast) > (byFolder[$1.id]?.first?.date ?? .distantPast) }
        let empty = folders.folders.filter { (byFolder[$0.id] ?? []).isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var out = (filled + empty).map { HomeSessionSection(id: $0.id, folder: $0, sessions: byFolder[$0.id] ?? []) }
        if !loose.isEmpty { out.append(HomeSessionSection(id: HomeSessionSection.noFolderID, folder: nil, sessions: loose)) }
        return out
    }

    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        persistCollapsed()
    }

    private func persistCollapsed() { defaults.set(collapsed.sorted(), forKey: Self.collapsedKey) }

    // MARK: folder changes (each returns the reason it was refused, or nil)

    /// Creates a folder; when `session` is given it goes in. Switches the list to Folders so the new folder shows.
    @discardableResult
    func createFolder(named name: String, filing session: String? = nil) -> FolderError? {
        do {
            let f = try folders.create(name: name)
            if let session { try folders.move(session, to: f.id) }
            setMode(.folders)
            return nil
        } catch { return error as? FolderError ?? .writeFailed }
    }

    func renameFolder(_ id: String, to name: String) -> FolderError? {
        do { try folders.rename(id, to: name); return nil } catch { return error as? FolderError ?? .writeFailed }
    }

    /// Removes the folder only. Every session stays, under No folder.
    func deleteFolder(_ id: String) {
        try? folders.delete(id)
        if collapsed.remove(id) != nil { persistCollapsed() }
    }

    func move(_ session: String, to folder: String?) {
        guard self.session(named: session) != nil else { return }
        try? folders.move(session, to: folder)
    }

    func sessionCount(in folder: String) -> Int { sessions.filter { folders.folder(of: $0.name)?.id == folder }.count }

    // MARK: suggestions

    /// The chip for a session that is in no folder (2.3).
    func suggestion(for session: HomeSession) -> FolderSuggestion? {
        guard folders.folder(of: session.name) == nil else { return nil }
        return FolderSuggester.suggestion(for: session.folderSignals, folders: folders.folders,
                                          dismissed: folders.file.dismissed[session.name] ?? [])
    }

    /// A click on the chip: files the session, creating the folder first when the suggestion is new.
    func accept(_ suggestion: FolderSuggestion, for session: String) {
        switch suggestion {
        case .existing(let f): move(session, to: f.id)
        case .new(let name): createFolder(named: name, filing: session)
        }
    }

    func dismiss(_ suggestion: FolderSuggestion, for session: String) {
        try? folders.dismissSuggestion(suggestion.name, for: session)
    }

    /// A practice run built from a session goes into that session's folder the first time it is listed without one.
    private func autoAssignDerived() {
        var pairs: [String: String] = [:]
        for s in sessions where s.kind == .practice && folders.folder(of: s.name) == nil {
            guard let id = FolderSuggester.autoAssignment(for: s.folderSignals, assigned: { folders.folder(of: $0)?.id }),
                  let folder = folders.folders.first(where: { $0.id == id }), !folders.isDismissed(folder.name, for: s.name) else { continue }
            pairs[s.name] = id
        }
        if !pairs.isEmpty { try? folders.autoAssign(pairs) }
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
        self.prepare = prepare ?? EventPrep.prepare(brainDir: brainDir)
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
        let events = (try? await calendar.upcoming(within: Self.window, realMeetingsOnly: true)) ?? []
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
        Task { @MainActor in
            defer { preparing.remove(item.id) }
            do {
                _ = try await prepareSession(for: event)
                await refresh()
            } catch {
                message = L10n.tr("Could not prepare \"\(item.title)\": \(String(describing: error))")
            }
        }
    }

    /// Prepares `event` from its invite (the call the Prepare button makes), remembers which session belongs to the event
    /// and tells `onPrepared`. Returns the new session folder. The Practice page's "Upcoming" meetings use it too, so there
    /// is one event-prep path.
    public func prepareSession(for event: MeetingEvent) async throws -> URL {
        let lang = settings.language
        let prepare = self.prepare
        let dir = try await prepare(event, lang)
        eventMap.remember(eventID: event.id, session: dir.lastPathComponent)
        onPrepared(dir.lastPathComponent)
        return dir
    }

    /// Calendar events that end after now and start within `within`, soonest first, for pickers. Empty when "Use my calendar"
    /// is off, full calendar access is not granted (this never asks) or the read fails. A fixed model (renders, tests that
    /// call `setItems`) returns the events of its items.
    public func upcomingEvents(within: TimeInterval, now: Date = Date()) async -> [MeetingEvent] {
        if fixed { return items.compactMap(\.event) }
        guard meeting.useCalendar, calendar.authorization() == .fullAccess else { return [] }
        return (try? await calendar.upcoming(within: within, now: now, realMeetingsOnly: true)) ?? []
    }

    /// Event id -> session folder name, for the sessions the app prepared from an event.
    public var rememberedSessions: [String: String] { eventMap.load() }

    /// "Today 14:30 · Zoom · in 4 minutes".
    static func meta(_ e: MeetingEvent, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(e.start) { day = L10n.tr("Today") } else if cal.isDateInTomorrow(e.start) { day = L10n.tr("Tomorrow") } else {
            day = e.start.formatted(HomeFormat.dayMonth)
        }
        var parts = ["\(day) \(e.start.formatted(HomeFormat.time))"]
        if e.provider != .other { parts.append(e.provider.displayName) }
        let minutes = Int(e.start.timeIntervalSince(now) / 60)
        if minutes > 0 && minutes < 90 { parts.append(L10n.tr("in \(minutes) minutes")) }
        return parts.joined(separator: " · ")
    }
}
