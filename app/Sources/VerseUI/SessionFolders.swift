import Combine
import Foundation

// Folders by company or person (spec 2.3, 3.5). A session stays where it is on disk: folders are an index file,
// `<sessions root>/folders.json`, written only by the app on the main actor with atomic writes. Deleting or renaming a folder
// never touches a session. This file holds the folder model, the file codec, the store and the pure suggester.

// MARK: - Model and file

struct SessionFolder: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var name: String
    var createdAt: Date
    var usedAt: Date

    enum CodingKeys: String, CodingKey { case id, name, createdAt = "created_at", usedAt = "used_at" }
}

enum FolderError: Error, Equatable {
    case emptyName, tooLong, duplicateName
    /// `folders.json` could not be written; nothing changed.
    case writeFailed

    /// The line a validation field shows under itself.
    var message: String {
        switch self {
        case .emptyName: L10n.tr("Give the folder a name.")
        case .tooLong: L10n.tr("A folder name can have up to 60 characters.")
        case .duplicateName: L10n.tr("A folder with that name already exists.")
        case .writeFailed: L10n.tr("Verse could not save the folders.")
        }
    }
}

/// The content of `folders.json` (3.5). Unknown keys are ignored on read; a missing key is its empty value.
struct FoldersFile: Codable, Equatable {
    var version = 1
    var folders: [SessionFolder] = []
    /// Session folder name -> folder id.
    var assign: [String: String] = [:]
    /// Session folder name -> names of the folders whose suggestion he turned down.
    var dismissed: [String: [String]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        folders = try c.decodeIfPresent([SessionFolder].self, forKey: .folders) ?? []
        assign = try c.decodeIfPresent([String: String].self, forKey: .assign) ?? [:]
        dismissed = try c.decodeIfPresent([String: [String]].self, forKey: .dismissed) ?? [:]
    }
}

enum FoldersCodec {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static func decode(_ data: Data) throws -> FoldersFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter(fractional: false).date(from: s) ?? formatter(fractional: true).date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return try d.decode(FoldersFile.self, from: data)
    }

    static func encode(_ file: FoldersFile) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter(fractional: false).string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(file)
    }
}

// MARK: - Store

@MainActor
final class SessionFolderStore: ObservableObject {
    nonisolated static let fileName = "folders.json"
    nonisolated static let maxNameLength = 60

    @Published private(set) var file = FoldersFile()
    /// Set when `folders.json` was unreadable and was set aside; shown once, cleared by `dismissNotice()` or the next change.
    @Published private(set) var notice: String?

    let url: URL
    private let sessionExists: (String) -> Bool
    private let now: () -> Date
    private let makeID: () -> String

    var folders: [SessionFolder] { file.folders }

    /// `sessionExists` answers whether a session folder is still there (default: its `pack.md`); assignments to sessions that
    /// are gone are dropped on every write.
    init(root: URL, sessionExists: ((String) -> Bool)? = nil, now: @escaping () -> Date = Date.init,
         makeID: @escaping () -> String = SessionFolderStore.randomID) {
        url = root.appendingPathComponent(Self.fileName)
        self.sessionExists = sessionExists ?? { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("pack.md").path)
        }
        self.now = now
        self.makeID = makeID
        load()
    }

    /// `f-` and 8 random lowercase base-36 characters.
    nonisolated static func randomID() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return "f-" + String((0..<8).map { _ in alphabet.randomElement() ?? "0" })
    }

    // MARK: read

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            var f = try FoldersCodec.decode(Data(contentsOf: url))
            // An assignment to a folder that is not in the list can only be a leftover.
            let ids = Set(f.folders.map(\.id))
            f.assign = f.assign.filter { ids.contains($0.value) }
            file = f
        } catch {
            // Never delete what we could not read: set it aside under a stamped name.
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let aside = url.deletingLastPathComponent().appendingPathComponent("\(Self.fileName).unreadable-\(stamp.string(from: now()))")
            try? fm.moveItem(at: url, to: aside)
            notice = L10n.tr("The folders file could not be read, so the folders start empty. The old file was kept next to it.")
        }
    }

    func folder(of session: String) -> SessionFolder? {
        guard let id = file.assign[session] else { return nil }
        return file.folders.first { $0.id == id }
    }

    func isDismissed(_ folderName: String, for session: String) -> Bool {
        let folded = TextFold.fold(folderName)
        return (file.dismissed[session] ?? []).contains { TextFold.fold($0) == folded }
    }

    func dismissNotice() { notice = nil }

    // MARK: validation

    /// The trimmed name, or the reason it is refused. `excluding` is the folder being renamed.
    func validate(_ raw: String, excluding id: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        guard name.count <= Self.maxNameLength else { throw FolderError.tooLong }
        let folded = TextFold.fold(name)
        if file.folders.contains(where: { $0.id != id && TextFold.fold($0.name) == folded }) { throw FolderError.duplicateName }
        return name
    }

    // MARK: changes

    @discardableResult
    func create(name raw: String) throws -> SessionFolder {
        let name = try validate(raw)
        var f = file
        var id = makeID()
        while f.folders.contains(where: { $0.id == id }) { id = makeID() }
        let folder = SessionFolder(id: id, name: name, createdAt: now(), usedAt: now())
        f.folders.append(folder)
        try commit(f)
        return folder
    }

    func rename(_ id: String, to raw: String) throws {
        let name = try validate(raw, excluding: id)
        var f = file
        guard let i = f.folders.firstIndex(where: { $0.id == id }) else { return }
        let old = f.folders[i].name
        f.folders[i].name = name
        // A turned-down suggestion follows the new name.
        for (session, names) in f.dismissed {
            f.dismissed[session] = names.map { TextFold.fold($0) == TextFold.fold(old) ? name : $0 }
        }
        try commit(f)
    }

    /// Removes the folder and its assignments. No session is touched.
    func delete(_ id: String) throws {
        var f = file
        f.folders.removeAll { $0.id == id }
        f.assign = f.assign.filter { $0.value != id }
        try commit(f)
    }

    /// `folder` nil takes the session out of its folder. A session he takes out of a folder does not come back through a
    /// suggestion or an auto-assign of that same folder.
    func move(_ session: String, to folder: String?) throws {
        var f = file
        if let id = folder {
            guard let i = f.folders.firstIndex(where: { $0.id == id }) else { return }
            f.assign[session] = id
            f.folders[i].usedAt = now()
            f.dismissed[session] = (f.dismissed[session] ?? []).filter { TextFold.fold($0) != TextFold.fold(f.folders[i].name) }
            if f.dismissed[session]?.isEmpty == true { f.dismissed[session] = nil }
        } else {
            if let id = f.assign[session], let old = f.folders.first(where: { $0.id == id }), !isDismissed(old.name, for: session) {
                f.dismissed[session, default: []].append(old.name)
            }
            f.assign[session] = nil
        }
        try commit(f)
    }

    /// Files sessions that are derived from a filed one (practice runs). Not a move by him, so `used_at` stays.
    func autoAssign(_ pairs: [String: String]) throws {
        var f = file
        let ids = Set(f.folders.map(\.id))
        var changed = false
        for (session, id) in pairs where ids.contains(id) && f.assign[session] == nil {
            f.assign[session] = id
            changed = true
        }
        if changed { try commit(f) }
    }

    /// "Not this folder": the suggestion of `folderName` for `session` is not shown again.
    func dismissSuggestion(_ folderName: String, for session: String) throws {
        guard !isDismissed(folderName, for: session) else { return }
        var f = file
        f.dismissed[session, default: []].append(folderName)
        try commit(f)
    }

    // MARK: write

    private func commit(_ new: FoldersFile) throws {
        var f = new
        f.version = 1
        f.assign = f.assign.filter { sessionExists($0.key) }
        f.dismissed = f.dismissed.filter { sessionExists($0.key) && !$0.value.isEmpty }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FoldersCodec.encode(f).write(to: url, options: .atomic)
        } catch {
            FileLog.shared.write("folders: could not write \(url.lastPathComponent): \(error.localizedDescription)")
            throw FolderError.writeFailed
        }
        file = f
        notice = nil
    }
}

// MARK: - Suggestions (pure)

/// What the suggester reads about one session. Built from the session folder's own files, never from the calendar.
struct FolderSignals: Equatable, Sendable {
    /// The session folder's name (`ironwood-lena`).
    var folderName = ""
    var title = ""
    /// `meta.json` `conversation.company`.
    var conversationCompany: String?
    /// `sim.json` `company`.
    var simCompany: String?
    /// `sim.json` `source_session`: the session a practice run was built from.
    var sourceSession: String?
    /// The `name`-kind FACTS lines of `pack.md` (first 40), as text.
    var factNames: [String] = []

    static let maxFactNames = 40
}

enum FolderSuggestion: Equatable {
    /// File the session in a folder that exists.
    case existing(SessionFolder)
    /// Create a folder with this name and file the session in it.
    case new(String)

    var name: String {
        switch self {
        case .existing(let f): f.name
        case .new(let n): n
        }
    }
}

enum FolderSuggester {
    /// Folded words: lowercase, accents removed, split on everything that is not a letter or digit.
    static func words(_ s: String) -> [String] {
        TextFold.fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// `needle` occurs in `hay` as whole words, in order, next to each other.
    static func contains(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<(start + needle.count)]) == needle { return true }
        return false
    }

    /// The text a folder name is looked for in, one string per source so a name never spans two of them.
    static func haystack(_ s: FolderSignals) -> [[String]] {
        var out: [[String]] = []
        // The session folder's name words, split on - and _ (the `words` split covers both).
        out.append(words(s.folderName))
        if let c = s.conversationCompany { out.append(words(c)) }
        if let c = s.simCompany { out.append(words(c)) }
        out.append(words(s.title))
        for line in s.factNames.prefix(FolderSignals.maxFactNames) { out.append(words(line)) }
        return out.filter { !$0.isEmpty }
    }

    /// The suggestion for an unfiled session (2.3): an existing folder whose name is in the session's haystack (the longest
    /// name wins, on a tie the folder used most recently), else a new folder from a company name. Dismissed names are skipped.
    static func suggestion(for s: FolderSignals, folders: [SessionFolder], dismissed: [String] = []) -> FolderSuggestion? {
        let turnedDown = Set(dismissed.map(TextFold.fold))
        let hay = haystack(s)
        let matches = folders.compactMap { f -> (SessionFolder, [String])? in
            let w = words(f.name)
            guard !turnedDown.contains(TextFold.fold(f.name)), hay.contains(where: { contains($0, w) }) else { return nil }
            return (f, w)
        }
        let best = matches.sorted { a, b in
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            let la = TextFold.fold(a.0.name).count, lb = TextFold.fold(b.0.name).count
            if la != lb { return la > lb }
            if a.0.usedAt != b.0.usedAt { return a.0.usedAt > b.0.usedAt }
            return a.0.name < b.0.name
        }.first
        if let (f, _) = best { return .existing(f) }

        // A new folder only when no existing folder matched at all.
        guard matches.isEmpty else { return nil }
        for raw in [s.conversationCompany, s.simCompany] {
            guard let name = cleanCompany(raw) else { continue }
            let folded = TextFold.fold(name)
            if turnedDown.contains(folded) || folders.contains(where: { TextFold.fold($0.name) == folded }) { continue }
            return .new(name)
        }
        return nil
    }

    /// A company name that can be a folder name: trimmed, one space between words, 1-60 characters, not the sim prep's
    /// placeholder.
    static func cleanCompany(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= SessionFolderStore.maxNameLength, TextFold.fold(name) != "unknown company" else { return nil }
        return name
    }

    /// The folder id a practice run goes into on its own: the one its source session is in (`assigned` answers for a
    /// session name).
    static func autoAssignment(for s: FolderSignals, assigned: (String) -> String?) -> String? {
        guard let source = s.sourceSession, !source.isEmpty else { return nil }
        return assigned(source)
    }

    // MARK: reading the session folder

    /// The signals of one session folder: `meta.json`, `sim.json` and the head of `pack.md`.
    static func signals(folderName: String, title: String, dir: URL) -> FolderSignals {
        var s = FolderSignals(folderName: folderName, title: title)
        func json(_ file: String) -> [String: Any]? {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        if let meta = json("meta.json"), let conv = meta["conversation"] as? [String: Any] {
            s.conversationCompany = (conv["company"] as? String)
        }
        if folderName.hasPrefix("sim-"), let sim = json("sim.json") {
            s.simCompany = sim["company"] as? String
            s.sourceSession = sim["source_session"] as? String
        }
        s.factNames = factNames(pack: dir.appendingPathComponent("pack.md"))
        return s
    }

    /// `[f019] name | The live portfolio site is northwind.example. | northwind.example | prep:L85` -> the text and value of the
    /// first 40 `name` lines in the FACTS section.
    static func factNames(pack url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        var inFacts = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inFacts { break }
                inFacts = line == "## FACTS"
                continue
            }
            guard inFacts, line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: " | ")
            guard parts.first == "name", parts.count >= 2 else { continue }
            out.append(parts[1...min(2, parts.count - 1)].joined(separator: " "))
            if out.count >= FolderSignals.maxFactNames { break }
        }
        return out
    }
}
