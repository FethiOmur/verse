import Combine
import Foundation
import VerseMeet

// People and companies, app side (memory spec 2.5, 3.6): the people the owner meets, kept in `memory/people.json`. The file is
// written only by the app, on the main actor, atomically (the folders rule). `EntityResolver` decides which sessions belong to an
// entity and creates entities from folders and calendar attendees; this file holds the model, the codec and the store.

// MARK: - Model

struct MemoryEntity: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case person, company }

    var id: String
    var kind: Kind
    var name: String
    /// Lowercased.
    var emails: [String] = []
    /// A company's domains (lowercased).
    var domains: [String] = []
    var aliases: [String] = []
    /// Folder ids (`folders.json`) whose sessions belong to this entity.
    var folders: [String] = []
    /// A person's company (an entity id).
    var company: String?
    /// `auto` (made from a folder or an attendee) or `user` (named by hand).
    var namedBy: String = "auto"
    var hidden = false
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, name, emails, domains, aliases, company, folders, hidden
        case namedBy = "named_by", createdAt = "created_at"
    }

    init(id: String, kind: Kind, name: String, emails: [String] = [], domains: [String] = [], aliases: [String] = [],
         folders: [String] = [], company: String? = nil, namedBy: String = "auto", hidden: Bool = false, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.name = name
        self.emails = emails
        self.domains = domains
        self.aliases = aliases
        self.folders = folders
        self.company = company
        self.namedBy = namedBy
        self.hidden = hidden
        self.createdAt = createdAt
    }

    /// Tolerant: a missing key is its empty value, unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .person
        name = try c.decode(String.self, forKey: .name)
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        company = try c.decodeIfPresent(String.self, forKey: .company)
        namedBy = try c.decodeIfPresent(String.self, forKey: .namedBy) ?? "auto"
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// The lowercased name the entity is found by in text: its name and its aliases, folded.
    var foldedNames: [String] { ([name] + aliases).map(TextFold.fold) }
}

/// The content of `people.json` (spec 3.6). Unknown keys are ignored on read; a missing key is its empty value.
struct PeopleFile: Codable, Equatable, Sendable {
    var version = 1
    var entities: [MemoryEntity] = []
    /// Session folder name -> the event's attendees minus the owner (recorded when a session is prepared from an event).
    var attendees: [String: [Attendee]] = [:]
    /// Every owner address seen as the calendar's current user.
    var ownerEmails: [String] = []
    /// Session -> entity ids the owner added by hand.
    var links: [String: [String]] = [:]
    /// Session -> entity ids the owner removed.
    var unlinks: [String: [String]] = [:]
    /// Entity id -> sessions (and, for a merge suggestion, entity ids) he turned down.
    var dismissed: [String: [String]] = [:]
    /// Loser id -> survivor id, so old selections and chat scopes resolve.
    var merged: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case version, entities, attendees, links, unlinks, dismissed, merged
        case ownerEmails = "owner_emails"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entities = try c.decodeIfPresent([MemoryEntity].self, forKey: .entities) ?? []
        attendees = try c.decodeIfPresent([String: [Attendee]].self, forKey: .attendees) ?? [:]
        ownerEmails = try c.decodeIfPresent([String].self, forKey: .ownerEmails) ?? []
        links = try c.decodeIfPresent([String: [String]].self, forKey: .links) ?? [:]
        unlinks = try c.decodeIfPresent([String: [String]].self, forKey: .unlinks) ?? [:]
        dismissed = try c.decodeIfPresent([String: [String]].self, forKey: .dismissed) ?? [:]
        merged = try c.decodeIfPresent([String: String].self, forKey: .merged) ?? [:]
    }
}

enum PeopleCodec {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static func decode(_ data: Data) throws -> PeopleFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter(fractional: false).date(from: s) ?? formatter(fractional: true).date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return try d.decode(PeopleFile.self, from: data)
    }

    static func encode(_ file: PeopleFile) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter(fractional: false).string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(file)
    }
}

enum EntityError: Error, Equatable {
    case emptyName, tooLong
    /// Another entity of this kind already has the name.
    case duplicateName(kind: MemoryEntity.Kind, name: String)
    /// A person cannot be merged into a company or the reverse.
    case crossKind
    case notFound
    /// `people.json` could not be written; nothing changed.
    case writeFailed

    /// The line a validation field shows under itself.
    var message: String {
        switch self {
        case .emptyName: L10n.tr("Give the name at least one character.")
        case .tooLong: L10n.tr("A name can have up to 80 characters.")
        case .duplicateName(let kind, let name):
            kind == .person ? L10n.tr("There is already a person named “\(name)”.") : L10n.tr("There is already a company named “\(name)”.")
        case .crossKind: L10n.tr("A person and a company cannot be merged.")
        case .notFound: L10n.tr("That entry is no longer there.")
        case .writeFailed: L10n.tr("Verse could not save the people.")
        }
    }
}

// MARK: - Store

@MainActor
final class EntityStore: ObservableObject {
    nonisolated static let fileName = "people.json"
    nonisolated static let maxNameLength = 80

    @Published private(set) var file = PeopleFile()
    /// Set when `people.json` was unreadable and was set aside; shown once, cleared by `dismissNotice()` or the next change.
    @Published private(set) var notice: String?

    let url: URL
    /// The folders and sessions `refresh()` reconciles against; the window sets it. Without it `refresh()` does nothing.
    var context: (@MainActor () -> (folders: FoldersFile, sessions: [HomeSession]))?
    /// Called after every change that reached the disk: the memory index labels follow the entities.
    var onChange: (@MainActor () -> Void)?

    private let sessionExists: (String) -> Bool
    private let now: () -> Date
    private let makeID: () -> String

    /// `sessionExists` answers whether a session folder is still there (default: a folder of that name under `sessionsRoot`);
    /// `links`, `unlinks` and `dismissed` entries of sessions that are gone are dropped on every write.
    init(paths: MemoryPaths, sessionsRoot: URL = SessionCatalog.root, sessionExists: ((String) -> Bool)? = nil,
         now: @escaping () -> Date = Date.init, makeID: @escaping () -> String = EntityStore.randomID) {
        url = paths.people
        self.sessionExists = sessionExists ?? { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: sessionsRoot.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        self.now = now
        self.makeID = makeID
        load()
    }

    /// `e-` and 8 random lowercase base-36 characters.
    nonisolated static func randomID() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return "e-" + String((0..<8).map { _ in alphabet.randomElement() ?? "0" })
    }

    // MARK: read

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            file = try PeopleCodec.decode(Data(contentsOf: url))
        } catch {
            // Never delete what we could not read: set it aside under a stamped name.
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(Self.fileName).unreadable-\(stamp.string(from: now()))")
            try? fm.moveItem(at: url, to: aside)
            notice = L10n.tr("The people file could not be read, so People starts empty. The old file was kept next to it.")
        }
    }

    func dismissNotice() { notice = nil }

    /// The entity `id` names, following `merged` redirects. A hidden entity still resolves (its page can bring it back).
    func resolve(id: String) -> MemoryEntity? { Self.resolve(id: id, in: file) }

    nonisolated static func resolve(id: String, in file: PeopleFile) -> MemoryEntity? {
        var current = id
        var hops = 0
        while let next = file.merged[current], hops < 16 { current = next; hops += 1 }
        return file.entities.first { $0.id == current }
    }

    /// The id after following `merged` (the id itself when nothing redirects it).
    func resolvedID(_ id: String) -> String {
        var current = id
        var hops = 0
        while let next = file.merged[current], hops < 16 { current = next; hops += 1 }
        return current
    }

    /// The entities a session belongs to, persons first, then companies (spec 2.5 "Labels for the index").
    func entities(of session: String, folders: FoldersFile) -> [MemoryEntity] {
        EntityResolver.entities(of: session, file: file, folders: folders)
    }

    // MARK: validation

    /// The trimmed name, or the reason it is refused. `excluding` is the entity being renamed.
    func validate(_ raw: String, kind: MemoryEntity.Kind, excluding id: String? = nil) throws(EntityError) -> String {
        let name = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        guard name.count <= Self.maxNameLength else { throw .tooLong }
        let folded = TextFold.fold(name)
        if file.entities.contains(where: { $0.id != id && $0.kind == kind && TextFold.fold($0.name) == folded }) {
            throw .duplicateName(kind: kind, name: name)
        }
        return name
    }

    // MARK: changes

    func rename(_ id: String, to raw: String) throws(EntityError) {
        let id = resolvedID(id)
        guard let i = file.entities.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let name = try validate(raw, kind: file.entities[i].kind, excluding: id)
        var f = file
        f.entities[i].name = name
        f.entities[i].namedBy = "user"
        try commit(f)
    }

    /// A person that becomes a company keeps its emails; a company that becomes a person loses its domains into its aliases (a
    /// domain is not a person's).
    func setKind(_ id: String, _ kind: MemoryEntity.Kind) throws(EntityError) {
        let id = resolvedID(id)
        guard let i = file.entities.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard file.entities[i].kind != kind else { return }
        _ = try validate(file.entities[i].name, kind: kind, excluding: id)
        var f = file
        switch kind {
        case .company:
            f.entities[i].company = nil
        case .person:
            for d in f.entities[i].domains where !f.entities[i].aliases.contains(d) { f.entities[i].aliases.append(d) }
            f.entities[i].domains = []
            // People that pointed at it as their company no longer have one.
            for j in f.entities.indices where f.entities[j].company == id { f.entities[j].company = nil }
        }
        f.entities[i].kind = kind
        try commit(f)
    }

    /// Emails, aliases (with the loser's name), folders and domains go to the survivor; `links`, `unlinks`, `dismissed` are rewritten;
    /// `merged[loser]` redirects every old reference. A person and a company cannot be merged.
    func merge(_ loser: String, into survivor: String) throws(EntityError) {
        let loserID = resolvedID(loser), survivorID = resolvedID(survivor)
        guard loserID != survivorID else { return }
        guard let li = file.entities.firstIndex(where: { $0.id == loserID }),
              let si = file.entities.firstIndex(where: { $0.id == survivorID }) else { throw .notFound }
        guard file.entities[li].kind == file.entities[si].kind else { throw .crossKind }
        var f = file
        let l = f.entities[li]
        var s = f.entities[si]
        func union(_ a: [String], _ b: [String], fold: Bool = false) -> [String] {
            var out = a
            for x in b where !out.contains(where: { fold ? TextFold.fold($0) == TextFold.fold(x) : $0 == x }) { out.append(x) }
            return out
        }
        s.emails = union(s.emails, l.emails)
        s.domains = union(s.domains, l.domains)
        s.folders = union(s.folders, l.folders)
        var aliases = union(s.aliases, l.aliases, fold: true)
        if TextFold.fold(l.name) != TextFold.fold(s.name), !aliases.contains(where: { TextFold.fold($0) == TextFold.fold(l.name) }) {
            aliases.append(l.name)
        }
        s.aliases = aliases
        if s.company == nil || s.company == loserID { s.company = l.company == survivorID ? nil : l.company }
        f.entities[si] = s
        f.entities.remove(at: li)
        for j in f.entities.indices where f.entities[j].company == loserID { f.entities[j].company = survivorID }
        func rewrite(_ ids: [String]) -> [String] {
            var out: [String] = []
            for x in ids { let y = x == loserID ? survivorID : x; if !out.contains(y) { out.append(y) } }
            return out
        }
        f.links = f.links.mapValues(rewrite)
        f.unlinks = f.unlinks.mapValues(rewrite)
        if let turnedDown = f.dismissed.removeValue(forKey: loserID) {
            f.dismissed[survivorID] = union(f.dismissed[survivorID] ?? [], turnedDown)
        }
        f.dismissed = f.dismissed.mapValues(rewrite)
        // Anything that pointed at the loser, or at an earlier loser of it, now points at the survivor.
        for (k, v) in f.merged where v == loserID { f.merged[k] = survivorID }
        f.merged[loserID] = survivorID
        try commit(f)
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        let id = resolvedID(id)
        guard let i = file.entities.firstIndex(where: { $0.id == id }), file.entities[i].hidden != hidden else { return }
        var f = file
        f.entities[i].hidden = hidden
        try? commit(f)
    }

    /// Adds `session` to the entity's sessions by hand (and takes it off the entity's unlinks).
    func link(_ session: String, to id: String) {
        let id = resolvedID(id)
        guard resolve(id: id) != nil else { return }
        var f = file
        if !(f.links[session] ?? []).contains(id) { f.links[session, default: []].append(id) }
        f.unlinks[session] = (f.unlinks[session] ?? []).filter { $0 != id }
        if f.unlinks[session]?.isEmpty == true { f.unlinks[session] = nil }
        try? commit(f)
    }

    /// Takes `session` out of the entity's sessions, whatever put it there (a folder, an email, a domain, a link).
    func unlink(_ session: String, from id: String) {
        let id = resolvedID(id)
        guard resolve(id: id) != nil else { return }
        var f = file
        if !(f.unlinks[session] ?? []).contains(id) { f.unlinks[session, default: []].append(id) }
        f.links[session] = (f.links[session] ?? []).filter { $0 != id }
        if f.links[session]?.isEmpty == true { f.links[session] = nil }
        try? commit(f)
    }

    /// "Not this": the suggestion of `session` for the entity is not shown again.
    func dismiss(_ session: String, for id: String) {
        let id = resolvedID(id)
        guard !(file.dismissed[id] ?? []).contains(session) else { return }
        var f = file
        f.dismissed[id, default: []].append(session)
        try? commit(f)
    }

    // MARK: attendees

    /// Skipped addresses: rooms, group calendars and no-reply senders (spec 2.5).
    nonisolated static let skippedAddressParts = ["resource.calendar.google.com", "group.calendar.google.com", "noreply", "no-reply",
                                                  "calendar-notification"]

    nonisolated static func isSkippedAddress(_ email: String) -> Bool {
        let e = email.lowercased()
        return skippedAddressParts.contains { e.contains($0) }
    }

    /// Records the event's attendees for `session`: the owner (`owner`, and every address in `ownerEmails`) and the skipped
    /// addresses are left out, a new owner address is remembered, and new entities follow.
    func recordAttendees(_ attendees: [Attendee], owner: Attendee?, session: String) {
        var f = file
        if let mine = owner?.email?.lowercased(), !mine.isEmpty, !f.ownerEmails.contains(mine) { f.ownerEmails.append(mine) }
        let others = attendees.compactMap { a -> Attendee? in
            let name = a.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shownName = (name?.isEmpty ?? true) ? nil : name
            guard let email = a.email?.lowercased(), !email.isEmpty else {
                // A name without an address resolves to nobody, but it still tells a folder named after a person who was there.
                return shownName.map { Attendee(name: $0, email: nil) }
            }
            guard !f.ownerEmails.contains(email), !Self.isSkippedAddress(email) else { return nil }
            return Attendee(name: shownName, email: email)
        }
        if others.isEmpty { f.attendees[session] = nil } else { f.attendees[session] = others }
        if let ctx = context?() {
            f = EntityResolver.reconcile(f, folders: ctx.folders, sessions: ctx.sessions, makeID: makeID, now: now())
        }
        if f != file { try? commit(f) }
    }

    /// Once per launch: for each event the app mapped to a session that has no recorded attendees, asks the calendar for the event
    /// (`lookup`; a miss is ignored). Never asks for calendar access: the caller checks it. Returns how many sessions got attendees.
    @discardableResult
    func backfill(eventSessions: [String: String], lookup: (String) async -> MeetingEvent?) async -> Int {
        var recorded = 0
        for (eventID, session) in eventSessions.sorted(by: { $0.key < $1.key }) {
            guard file.attendees[session] == nil, sessionExists(session), let event = await lookup(eventID) else { continue }
            let before = file.attendees[session]
            recordAttendees(event.attendees, owner: event.currentUser, session: session)
            if file.attendees[session] != before { recorded += 1 }
        }
        return recorded
    }

    // MARK: reconcile

    /// Creates the entities that folders and recorded attendees imply and never deletes one. A no-op without `context`.
    func refresh() {
        guard let ctx = context?() else { return }
        reconcile(folders: ctx.folders, sessions: ctx.sessions)
    }

    func reconcile(folders: FoldersFile, sessions: [HomeSession]) {
        let f = EntityResolver.reconcile(file, folders: folders, sessions: sessions, makeID: makeID, now: now())
        if f != file { try? commit(f) }
    }

    // MARK: undo

    func snapshot() -> PeopleFile { file }

    /// Puts a snapshot back exactly as it was.
    func restore(_ snapshot: PeopleFile) {
        _ = try? write(snapshot, prune: false)
    }

    /// Runs `change` and, when it altered the file, registers one undo on `undoManager` that restores the whole file as it was before
    /// (and a redo that restores it as it is after). Returns the file as it was before the change.
    @discardableResult
    func apply(_ actionName: String, undoManager: UndoManager?, _ change: (EntityStore) throws -> Void) throws(EntityError) -> PeopleFile {
        let before = snapshot()
        do { try change(self) } catch let e as EntityError { throw e } catch { throw .writeFailed }
        if file != before { register(undo: before, actionName: actionName, undoManager: undoManager) }
        return before
    }

    private func register(undo before: PeopleFile, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let after = store.snapshot()
                store.restore(before)
                store.register(undo: after, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: write

    private func commit(_ new: PeopleFile) throws(EntityError) {
        do { file = try write(new, prune: true) } catch { throw .writeFailed }
        notice = nil
        onChange?()
    }

    @discardableResult
    private func write(_ new: PeopleFile, prune: Bool) throws -> PeopleFile {
        var f = new
        f.version = 1
        if prune {
            let ids = Set(f.entities.map(\.id))
            f.links = f.links.filter { sessionExists($0.key) }
            f.unlinks = f.unlinks.filter { sessionExists($0.key) }
            f.dismissed = f.dismissed.compactMap { key, list -> (String, [String])? in
                let kept = list.filter { ids.contains($0) || sessionExists($0) }
                return kept.isEmpty ? nil : (key, kept)
            }.reduce(into: [String: [String]]()) { $0[$1.0] = $1.1 }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PeopleCodec.encode(f).write(to: url, options: .atomic)
        } catch {
            FileLog.shared.write("people: could not write \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
        file = f
        if !prune { onChange?() }
        return f
    }
}
