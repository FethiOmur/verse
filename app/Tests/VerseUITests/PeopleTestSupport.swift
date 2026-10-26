import Foundation
import VerseMeet
@testable import VerseUI

/// Scratch folders and fictional people for the People tests. Marta Velin and Joe Arkwright (Halden Works, `halden.example`), Giulia
/// Ferri (Corvo Studio, `corvo.example`), owner Dana Reyes. Nothing here reads the owner's own files.
@MainActor
final class PeopleEnv {
    let root: URL
    let paths: MemoryPaths
    var counter = 0
    let when = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = try FolderFixtures.scratch()
        paths = MemoryPaths(base: root.appendingPathComponent("memory", isDirectory: true))
    }

    var sessionsRoot: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    /// A store over the scratch memory folder; ids count up (`e-00000001`), so runs are deterministic.
    func store(sessionExists: ((String) -> Bool)? = { _ in true }) -> EntityStore {
        EntityStore(paths: paths, sessionsRoot: sessionsRoot, sessionExists: sessionExists, now: { [when] in when }, makeID: { [unowned self] in
            self.counter += 1
            return "e-" + String(format: "%08d", self.counter)
        })
    }

    /// A held meeting (a summary) `daysAgo` days back.
    @discardableResult
    func session(_ name: String, daysAgo: Int = 1, summary: String? = nil, files: [String: String] = [:]) throws -> HomeSession {
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        var f = files
        if let summary { f["summary.md"] = summary }
        try FolderFixtures.session(name, in: sessionsRoot, at: when.addingTimeInterval(-Double(daysAgo) * 86_400), files: f)
        return HomeSession.load(name: name, root: sessionsRoot)
    }

    func reload(_ names: [String]) -> [HomeSession] { names.map { HomeSession.load(name: $0, root: sessionsRoot) } }

    func folders(_ pairs: [(id: String, name: String, sessions: [String])]) -> FoldersFile {
        var f = FoldersFile()
        for p in pairs {
            f.folders.append(SessionFolder(id: p.id, name: p.name, createdAt: when, usedAt: when))
            for s in p.sessions { f.assign[s] = p.id }
        }
        return f
    }

    static let marta = Attendee(name: "Marta Velin", email: "marta@halden.example")
    static let joe = Attendee(name: "Joe Arkwright", email: "joe@halden.example")
    static let giulia = Attendee(name: "Giulia Ferri", email: "giulia@corvo.example")
    static let owner = Attendee(name: "Dana Reyes", email: "owner@example.com")

    func event(_ title: String = "Halden weekly", attendees: [Attendee]) -> MeetingEvent {
        MeetingEvent(id: "ev-\(title)", title: title, start: when.addingTimeInterval(86_400), end: when.addingTimeInterval(88_200),
                     attendees: attendees + [Self.owner], currentUser: Self.owner)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

extension PeopleFile {
    func entity(named name: String, _ kind: MemoryEntity.Kind? = nil) -> MemoryEntity? {
        entities.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }
}
