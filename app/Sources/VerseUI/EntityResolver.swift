import Foundation
import VerseMeet

// Which sessions belong to a person or company, and which entities the folders and the calendar imply (memory spec 2.4 "Primary
// entity", 2.5). Everything here is pure and synchronous: it reads `PeopleFile`, `FoldersFile` and the session list, and it never
// writes. A session is never stored in a list of an entity; membership is computed each time, so moving a session to another
// folder moves it between entities with no extra write.

enum EntityResolver {
    // MARK: freemail

    /// Mail providers whose domain says nothing about an employer: no company comes from them (spec 2.5).
    static let freemail: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "ymail.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de", "gmx.net", "libero.it", "virgilio.it",
        "tiscali.it", "alice.it", "yandex.com", "yandex.ru", "mail.ru", "hey.com", "fastmail.com",
    ]

    /// `marta@Halden.Example` -> `halden.example`; nil without an `@`.
    static func domain(of email: String) -> String? {
        let e = email.lowercased()
        guard let at = e.lastIndex(of: "@") else { return nil }
        let d = String(e[e.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? nil : d
    }

    /// The domain of `email` unless it is a freemail provider.
    static func companyDomain(of email: String) -> String? {
        guard let d = domain(of: email), !freemail.contains(d) else { return nil }
        return d
    }

    // MARK: membership

    /// True when `session` belongs to `entity` by its own signals: a folder it lists, a recorded attendee's email or non-freemail
    /// domain, or a link by hand; never when the owner removed it. A hidden entity owns nothing.
    static func belongs(_ session: String, to entity: MemoryEntity, file: PeopleFile, folders: FoldersFile) -> Bool {
        guard !entity.hidden else { return false }
        if file.unlinks[session]?.contains(entity.id) == true { return false }
        if file.links[session]?.contains(entity.id) == true { return true }
        if let folder = folders.assign[session], entity.folders.contains(folder) { return true }
        for a in file.attendees[session] ?? [] {
            guard let email = a.email?.lowercased() else { continue }
            if entity.emails.contains(email) { return true }
            if let d = companyDomain(of: email), entity.domains.contains(d) { return true }
        }
        return false
    }

    /// The entity and, for a company, the people who work there: their sessions are the company's too.
    private static func owners(of entity: MemoryEntity, file: PeopleFile) -> [MemoryEntity] {
        guard entity.kind == .company else { return [entity] }
        return [entity] + file.entities.filter { $0.kind == .person && $0.company == entity.id && !$0.hidden }
    }

    /// The entities `session` belongs to: people first, then companies, each group in file order. A person's company is included even
    /// when only the person matched.
    static func entities(of session: String, file: PeopleFile, folders: FoldersFile) -> [MemoryEntity] {
        var hit = file.entities.filter { belongs(session, to: $0, file: file, folders: folders) }
        for person in hit where person.kind == .person {
            guard let cid = person.company, !hit.contains(where: { $0.id == cid }),
                  let company = file.entities.first(where: { $0.id == cid && $0.kind == .company && !$0.hidden }),
                  file.unlinks[session]?.contains(cid) != true else { continue }
            hit.append(company)
        }
        return hit.filter { $0.kind == .person } + hit.filter { $0.kind == .company }
    }

    /// Sessions that can be on an entity's page at all: not practice runs.
    private static func eligible(_ s: HomeSession) -> Bool { s.kind != .practice }

    /// A session that was held: it has a transcript or a summary.
    static func wasHeld(_ s: HomeSession) -> Bool { eligible(s) && (s.summaryURL != nil || s.transcriptURL != nil) }

    /// The sessions of `id` (merged ids are followed by the caller), newest first. A company includes its people's.
    static func sessions(of id: String, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [HomeSession] {
        guard let entity = EntityStore.resolve(id: id, in: file) else { return [] }
        let owners = owners(of: entity, file: file)
        return sessions.filter { s in
            eligible(s) && owners.contains { belongs(s.name, to: $0, file: file, folders: folders) }
                && file.unlinks[s.name]?.contains(entity.id) != true
        }
        .sorted { ($0.date, $1.name) > ($1.date, $0.name) }
    }

    /// The sessions of `id` that were held (transcript or summary), newest first, without `excluding`: what a brief is made from.
    static func pastSessions(of id: String, excluding: String?, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [HomeSession] {
        self.sessions(of: id, file: file, folders: folders, sessions: sessions).filter { wasHeld($0) && $0.name != excluding }
    }

    // MARK: attendees of an event

    /// An event's attendees without the owner (`currentUser`, every owner address) and without rooms, group calendars and no-reply
    /// senders.
    static func guests(of event: MeetingEvent, file: PeopleFile) -> [Attendee] {
        let mine = Set(file.ownerEmails + [event.currentUser?.email?.lowercased()].compactMap { $0 })
        return event.attendees.filter { a in
            guard let email = a.email?.lowercased(), !email.isEmpty else { return false }
            return !mine.contains(email) && !EntityStore.isSkippedAddress(email)
        }
    }

    /// The names of an event's guests for the brief's `UPCOMING` line: the person's name when the address is one the app knows, else
    /// the name on the invite. Never an address, and not the local part of one.
    static func guestNames(of event: MeetingEvent, file: PeopleFile) -> [String] {
        var out: [String] = []
        for a in guests(of: event, file: file) {
            let known = entity(for: a, file: file).flatMap { $0.kind == .person ? $0.name : nil }
            let shown = (a.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let n = known ?? shown, !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// The entity one attendee is: the person with that address, else the company with that domain.
    private static func entity(for attendee: Attendee, file: PeopleFile) -> MemoryEntity? {
        guard let email = attendee.email?.lowercased() else { return nil }
        let live = file.entities.filter { !$0.hidden }
        if let p = live.first(where: { $0.kind == .person && $0.emails.contains(email) }) { return p }
        if let d = companyDomain(of: email) { return live.first { $0.kind == .company && $0.domains.contains(d) } }
        return nil
    }

    /// The entity a brief for `event` is about (spec 2.4): of the attendees minus the owner resolved to entities, the company they
    /// all share; else the one person; else the person with the most past sessions (ties: the most recent).
    static func primaryEntity(for event: MeetingEvent, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> MemoryEntity? {
        let resolved = guests(of: event, file: file).compactMap { entity(for: $0, file: file) }
        guard !resolved.isEmpty else { return nil }
        func companyID(_ e: MemoryEntity) -> String? { e.kind == .company ? e.id : e.company }
        let companies = Set(resolved.map(companyID))
        if companies.count == 1, let cid = companies.first ?? nil,
           let company = file.entities.first(where: { $0.id == cid && $0.kind == .company && !$0.hidden }) {
            return company
        }
        var distinct: [MemoryEntity] = []
        for e in resolved where !distinct.contains(where: { $0.id == e.id }) { distinct.append(e) }
        if distinct.count == 1 { return distinct[0] }
        func score(_ e: MemoryEntity) -> (Int, Date) {
            let past = pastSessions(of: e.id, excluding: nil, file: file, folders: folders, sessions: sessions)
            return (past.count, past.first?.date ?? .distantPast)
        }
        let people = distinct.filter { $0.kind == .person }
        return (people.isEmpty ? distinct : people).max { score($0) < score($1) }
    }

    /// Upcoming Up next items that are about `id`: an invite with a guest that is the entity (or one of its people), or an item whose
    /// prepared session belongs to it. Soonest first.
    static func upcoming(of id: String, file: PeopleFile, folders: FoldersFile, items: [HomeUpNextItem]) -> [HomeUpNextItem] {
        guard let entity = EntityStore.resolve(id: id, in: file), !entity.hidden else { return [] }
        let owners = owners(of: entity, file: file)
        return items.filter { item in
            if let name = item.session, owners.contains(where: { belongs(name, to: $0, file: file, folders: folders) }) { return true }
            guard let event = item.event else { return false }
            return guests(of: event, file: file).contains { a in
                guard let e = self.entity(for: a, file: file) else { return false }
                return e.id == entity.id || (entity.kind == .company && e.company == entity.id)
            }
        }
        .sorted { ($0.event?.start ?? .distantFuture) < ($1.event?.start ?? .distantFuture) }
    }

    // MARK: reconcile

    /// "Halden" from `halden.example`: the first label, capitalised.
    static func companyName(fromDomain d: String) -> String {
        let label = d.split(separator: ".").first.map(String.init) ?? d
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// "marta.velin" -> "Marta Velin".
    static func personName(fromEmail email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let words = local.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init).filter { !$0.isEmpty }
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? email : name
    }

    /// Creates, never deletes (spec 2.5 "Automatic entities"): an entity for each folder no entity lists, and a person (and the
    /// company their domain implies) for each recorded attendee address no entity has. An auto-named entity that follows one folder
    /// also follows that folder's name. Running it twice changes nothing.
    static func reconcile(_ file: PeopleFile, folders: FoldersFile, sessions: [HomeSession],
                          makeID: () -> String = EntityStore.randomID, now: Date = Date()) -> PeopleFile {
        var f = file
        let existing = Set(sessions.map(\.name))
        func freshID() -> String {
            var id = makeID()
            while f.entities.contains(where: { $0.id == id }) || f.merged[id] != nil { id = makeID() }
            return id
        }
        func foldedEquals(_ e: MemoryEntity, _ name: String) -> Bool { e.foldedNames.contains(TextFold.fold(name)) }

        // 1. Folders.
        for folder in folders.folders {
            if f.entities.contains(where: { $0.folders.contains(folder.id) }) { continue }
            let foldedName = TextFold.fold(folder.name)
            let named = f.assign(of: folder.id, folders: folders).filter { existing.contains($0) }.contains { session in
                (f.attendees[session] ?? []).contains { a in a.name.map { TextFold.fold($0) == foldedName } ?? false }
            }
            let kind: MemoryEntity.Kind = named ? .person : .company
            if let i = f.entities.firstIndex(where: { $0.kind == kind && foldedEquals($0, folder.name) }) {
                // An entity of that name exists already (made from an address): the folder joins it.
                f.entities[i].folders.append(folder.id)
            } else {
                f.entities.append(MemoryEntity(id: freshID(), kind: kind, name: folder.name, folders: [folder.id], createdAt: now))
            }
        }

        // 1b. A renamed folder renames the auto-named entity that follows it alone.
        for i in f.entities.indices {
            let e = f.entities[i]
            guard e.namedBy == "auto", e.folders.count == 1, let folder = folders.folders.first(where: { $0.id == e.folders[0] }),
                  folder.name != e.name,
                  !f.entities.contains(where: { $0.id != e.id && $0.kind == e.kind && TextFold.fold($0.name) == TextFold.fold(folder.name) })
            else { continue }
            if !f.entities[i].aliases.contains(where: { TextFold.fold($0) == TextFold.fold(e.name) }) { f.entities[i].aliases.append(e.name) }
            f.entities[i].name = folder.name
        }

        // 2. Attendees.
        let mine = Set(f.ownerEmails)
        for session in f.attendees.keys.sorted() where existing.contains(session) {
            for a in f.attendees[session] ?? [] {
                guard let email = a.email?.lowercased(), email.contains("@"), !mine.contains(email), !EntityStore.isSkippedAddress(email) else { continue }
                var personIndex = f.entities.firstIndex { $0.kind == .person && $0.emails.contains(email) }
                if personIndex == nil {
                    let shown = a.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let shown, !shown.isEmpty,
                       let i = f.entities.firstIndex(where: { $0.kind == .person && $0.emails.isEmpty && foldedEquals($0, shown) }) {
                        // A person made from a folder of their name: the address joins it.
                        f.entities[i].emails.append(email)
                        personIndex = i
                    } else {
                        let name = (shown?.isEmpty ?? true) ? personName(fromEmail: email) : shown!
                        f.entities.append(MemoryEntity(id: freshID(), kind: .person, name: name, emails: [email], createdAt: now))
                        personIndex = f.entities.count - 1
                    }
                }
                guard let pi = personIndex, let d = companyDomain(of: email) else { continue }
                let label = d.split(separator: ".").first.map(String.init) ?? d
                var ci = f.entities.firstIndex { $0.kind == .company && $0.domains.contains(d) }
                if ci == nil { ci = f.entities.firstIndex { $0.kind == .company && foldedEquals($0, label) } }
                if ci == nil {
                    f.entities.append(MemoryEntity(id: freshID(), kind: .company, name: companyName(fromDomain: d), domains: [d], createdAt: now))
                    ci = f.entities.count - 1
                }
                if let ci, !f.entities[ci].domains.contains(d) { f.entities[ci].domains.append(d) }
                if let ci, f.entities[pi].company == nil { f.entities[pi].company = f.entities[ci].id }
            }
        }
        return f
    }

    // MARK: suggestions

    /// The words a company is also known by in text: the first word of a multi-word name ("Halden" for "Halden Works").
    private static func looseNames(of e: MemoryEntity) -> [[String]] {
        var out = e.foldedNames.map { FolderSuggester.words($0) }
        if e.kind == .company, let first = FolderSuggester.words(e.name).first, FolderSuggester.words(e.name).count > 1, first.count >= 4 {
            out.append([first])
        }
        return out.filter { !$0.isEmpty }
    }

    /// Session names that mention the entity (title, folder-name words, `conversation.company`, FACTS names) but are not its sessions
    /// yet: shown as "Maybe also", never linked by themselves. A session turned down for the entity, or removed from it, is left out.
    static func suggestions(for id: String, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [String] {
        guard let entity = EntityStore.resolve(id: id, in: file), !entity.hidden else { return [] }
        let mine = Set(self.sessions(of: entity.id, file: file, folders: folders, sessions: sessions).map(\.name))
        let turnedDown = Set(file.dismissed[entity.id] ?? [])
        let needles = looseNames(of: entity)
        return sessions.filter { s in
            guard eligible(s), !mine.contains(s.name), !turnedDown.contains(s.name),
                  file.unlinks[s.name]?.contains(entity.id) != true else { return false }
            let hay = FolderSuggester.haystack(s.folderSignals)
            return needles.contains { n in hay.contains { FolderSuggester.contains($0, n) } }
        }
        .sorted { ($0.date, $1.name) > ($1.date, $0.name) }
        .map(\.name)
    }

    /// The other entity of the same kind that `id` may be (spec 2.5 "Suggest a merge"): equal folded names, or the same first word
    /// when one of the two is a single word. Only for the newer of the two, so the line shows on one page. Nil once turned down.
    static func mergeSuggestion(for id: String, file: PeopleFile) -> MemoryEntity? {
        guard let e = EntityStore.resolve(id: id, in: file), !e.hidden else { return nil }
        let turnedDown = Set(file.dismissed[e.id] ?? [])
        let words = FolderSuggester.words(e.name)
        guard let first = words.first else { return nil }
        for other in file.entities where other.id != e.id && other.kind == e.kind && !other.hidden && !turnedDown.contains(other.id) {
            // Shown on the newer one's page only (ties: the larger id).
            guard (e.createdAt, e.id) > (other.createdAt, other.id) else { continue }
            let ow = FolderSuggester.words(other.name)
            if ow == words { return other }
            if ow.first == first, words.count == 1 || ow.count == 1 { return other }
        }
        return nil
    }
}

private extension PeopleFile {
    /// Sessions the folders file assigns to `folder`.
    func assign(of folder: String, folders: FoldersFile) -> [String] {
        folders.assign.filter { $0.value == folder }.map(\.key).sorted()
    }
}
