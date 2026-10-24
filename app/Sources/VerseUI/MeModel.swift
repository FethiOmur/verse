import Combine
import Foundation
import VerseAudio
import VerseTurns

// The Me page's model (anytime-calls spec 2.2, "UI"): the permanent profile in
// `~/Library/Application Support/Verse/profile/`. It reads and edits `me.md` and `me.sources.json` as plain files, and runs
// `python -m verse_brain.prep me build|refresh|show` through a child process, the same pattern as `ConversationPrep`. The
// format and the merge rules are the brain's (`brain/verse_brain/prep/me.py`): a line he edits here keeps its `[id]`, so the
// next refresh counts it as edited and keeps it verbatim; a line he deletes stays deleted. Keys are never on the command
// line: prep reads the Anthropic key from the Keychain itself.

// MARK: - Sections and lines

/// The sections of `me.md`, in file order.
public enum MeSection: CaseIterable, Sendable, RawRepresentable {
    case who, experience, projects, skills, numbers, stories, looking, notes

    /// The heading in `me.md`. The notes section is named after the owner (`<NAME>'S NOTES`, `MY NOTES` without a profile).
    public var rawValue: String {
        switch self {
        case .who: "WHO I AM"
        case .experience: "EXPERIENCE"
        case .projects: "PROJECTS"
        case .skills: "SKILLS"
        case .numbers: "NUMBERS"
        case .stories: "STORIES"
        case .looking: "LOOKING FOR"
        case .notes: OwnerProfile.current.notesHeading
        }
    }

    public init?(rawValue: String) {
        guard let s = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = s
    }

    /// What the page calls it.
    public var title: String {
        switch self {
        case .who: return L10n.tr("Who I am")
        case .experience: return L10n.tr("Experience")
        case .projects: return L10n.tr("Projects")
        case .skills: return L10n.tr("Skills")
        case .numbers: return L10n.tr("Numbers")
        case .stories: return L10n.tr("Stories")
        case .looking: return L10n.tr("Looking for")
        case .notes: return L10n.tr("My notes")
        }
    }

    /// Fields of a line before its source (`N_FIELDS` in prep).
    public var fieldCount: Int {
        switch self {
        case .who: return 1
        case .experience: return 4
        case .projects: return 5
        case .skills: return 2
        case .numbers: return 3
        case .stories: return 2
        case .looking: return 1
        case .notes: return 1
        }
    }

    /// Ids of the section start here (`m001`, `m101`, ... `m701`).
    var idBase: Int { (Self.allCases.firstIndex(of: self) ?? 0) * 100 }
}

/// One line of `me.md`: `[m101] field | field | ... | src`.
public struct MeLine: Identifiable, Equatable, Sendable {
    /// `m101`; a line typed by hand without an id gets a placeholder (`line-<section>-<n>`).
    public var id: String
    public var hasID: Bool
    public var section: MeSection
    public var fields: [String]
    /// Where the line came from (`file:dana_profile.md#L13`, or the owner's source tag).
    public var source: String
    /// The line exactly as it stands in the file. Rendering uses it, so a line nobody edited is written back byte for byte
    /// (prep tells an edited line from a generated one by the hash of this text).
    var raw: String

    /// The line as the page reads it.
    public var text: String {
        // A NUMBERS line is `kind | sentence | value`: the page reads the sentence; the editor still has all three.
        if section == .numbers, fields.count == 3 { return fields[1] }
        return fields.joined(separator: " · ")
    }
    /// What the editor shows: the fields with the file's separator.
    public var editable: String { fields.joined(separator: " | ") }
}

public enum MeFile {
    // MARK: parse (the same rules as prep's `parse_md` / `parse_body`)

    public static func parse(_ text: String) -> [MeSection: [MeLine]] {
        var out: [MeSection: [MeLine]] = Dictionary(uniqueKeysWithValues: MeSection.allCases.map { ($0, []) })
        var current: MeSection?
        var anonymous = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let s = rawLine.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("## ") {
                let name = s.dropFirst(3).trimmingCharacters(in: .whitespaces)
                current = MeSection.allCases.first { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }
                continue
            }
            guard let section = current, !s.isEmpty else { continue }
            var id: String?
            var body = s
            if let m = s.range(of: #"^\[(m\d{3})\]\s*"#, options: .regularExpression) {
                id = String(s[s.index(after: s.startIndex)..<s.index(s.startIndex, offsetBy: 5)])
                body = String(s[m.upperBound...])
            }
            let parts = body.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            let n = section.fieldCount
            let fields: [String], src: String
            if parts.count == n + 1 {
                fields = Array(parts[0..<n])
                src = parts[n]
            } else if parts.count > 1 {
                fields = Array(parts.dropLast())
                src = parts[parts.count - 1]
            } else {
                fields = parts
                src = ""
            }
            if id == nil { anonymous += 1 }
            out[section, default: []].append(MeLine(id: id ?? "line-\(section.idBase)-\(anonymous)", hasID: id != nil, section: section,
                                                    fields: fields, source: src, raw: s))
        }
        return out
    }

    static func idNumber(_ id: String) -> Int { Int(id.dropFirst()) ?? 1_000_000 }

    /// The file text (prep's `render_md`): sections in order, lines with an id by number, then the ones without.
    public static func render(_ sections: [MeSection: [MeLine]]) -> String {
        var out: [String] = []
        for s in MeSection.allCases {
            out.append("## \(s.rawValue)")
            let lines = sections[s] ?? []
            out += lines.filter(\.hasID).sorted { idNumber($0.id) < idNumber($1.id) }.map(\.raw)
            out += lines.filter { !$0.hasID }.map(\.raw)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// `[m101] a | b | src`.
    static func compose(id: String, fields: [String], source: String) -> String {
        "[\(id)] " + (fields + [source]).joined(separator: " | ")
    }

    /// The next free id of a section (prep's `alloc_id`), or nil when its hundred are used.
    static func allocate(_ section: MeSection, used: Set<String>) -> String? {
        for n in (section.idBase + 1)..<(section.idBase + 100) {
            let id = String(format: "m%03d", n)
            if !used.contains(id) { return id }
        }
        return nil
    }

    /// Collapses whitespace and line breaks; the file keeps one item per line.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Meta, sources, show output

/// `me.meta.json`, as far as the page needs it.
public struct MeMeta: Equatable, Sendable {
    public var builtAt: Date?
    public var tokens: Int
    public var spendTotal: Double
    public var model: String
    var usedIDs: Set<String>
    /// Source quotes of generated lines by id, for the facts export.
    var quotes: [String: [String: String]]

    public static func load(_ url: URL) -> MeMeta? {
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var used = Set((o["lines"] as? [String: Any])?.keys.map { $0 } ?? [])
        for d in o["deleted"] as? [[String: Any]] ?? [] { if let i = d["id"] as? String { used.insert(i) } }
        for i in o["notes_issued"] as? [String] ?? [] { used.insert(i) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return MeMeta(builtAt: (o["built_at"] as? String).flatMap { formatter.date(from: $0) },
                      tokens: (o["tokens"] as? NSNumber)?.intValue ?? 0,
                      spendTotal: (o["spend_usd_total"] as? NSNumber)?.doubleValue ?? 0,
                      model: o["model"] as? String ?? "",
                      usedIDs: used,
                      quotes: (o["quotes"] as? [String: [String: String]]) ?? [:])
    }

    /// "Built 16 Oct · 3,140 tokens · $0.07".
    public var summary: String {
        var parts: [String] = []
        if let b = builtAt { parts.append(L10n.tr("Built \(b.formatted(Date.FormatStyle().locale(HomeFormat.locale).day().month(.abbreviated)))")) } else { parts.append(L10n.tr("Built")) }
        parts.append(L10n.tr("\(Self.tokenText(tokens)) tokens"))
        parts.append(L10n.usd(spendTotal))
        return parts.joined(separator: " · ")
    }

    /// The same line for the "Done · built 16 Oct · …" message after a run.
    public var doneSummary: String {
        var parts: [String] = []
        if let b = builtAt { parts.append(L10n.tr("built \(b.formatted(Date.FormatStyle().locale(HomeFormat.locale).day().month(.abbreviated)))")) } else { parts.append(L10n.tr("built")) }
        parts.append(L10n.tr("\(Self.tokenText(tokens)) tokens"))
        parts.append(L10n.usd(spendTotal))
        return parts.joined(separator: " · ")
    }

    public static func tokenText(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = L10n.formatLocale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// One entry of `me.sources.json`.
public struct MeSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var path: String
    public var label: String
    public var enabled: Bool
    /// `prep me show` lists it as changed since the last build.
    public var changed = false

    /// "vault note", "file", "facts of earlier meeting preps".
    public var kindText: String {
        switch kind {
        case "vault": return L10n.tr("Vault note")
        case "sessions": return L10n.tr("Earlier meeting preps")
        case "notes": return L10n.tr("Notes")
        default: return L10n.tr("File")
        }
    }
}

/// What `prep me show` printed.
public struct MeShow: Equatable, Sendable {
    public var staleSources: [String]

    /// The `stale sources:` line (`none`, or labels separated by commas).
    public static func parse(_ output: String) -> MeShow {
        for line in output.components(separatedBy: .newlines) where line.hasPrefix("stale sources:") {
            let rest = line.dropFirst("stale sources:".count).trimmingCharacters(in: .whitespaces)
            if rest == "none" || rest.isEmpty { return MeShow(staleSources: []) }
            return MeShow(staleSources: rest.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return MeShow(staleSources: [])
    }
}

// MARK: - Running prep

public enum MeAction: String, Sendable { case build, refresh, show }

public enum MeOutcome: Equatable, Sendable {
    /// `stdout` is what prep printed (for `show` the report, otherwise the profile folder); `log` its progress lines.
    case done(stdout: String, log: [String])
    case failed(String)
    case cancelled
}

/// Runs one `prep me ...` call. The model takes it as a protocol so tests use a fake.
public protocol MeRunning: AnyObject, Sendable {
    func run(_ action: MeAction, profileDir: URL, brainDir: URL, fake: Bool, onLine: @escaping @Sendable (String) -> Void) async -> MeOutcome
    func cancel()
}

/// The real runner: a child process of the brain venv. No key and no profile text is on the command line.
public final class MePrep: MeRunning, @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    /// An interpreter other than the brain's own venv (tests with `VERSE_BRAIN_PYTHON`).
    private let python: URL?

    public init(python: URL? = nil) { self.python = python }

    /// `-u -m verse_brain.prep me <action> --profile-dir <dir> [--fake]`.
    public static func arguments(_ action: MeAction, profileDir: URL, fake: Bool) -> [String] {
        var a = ["-u", "-m", "verse_brain.prep", "me", action.rawValue, "--profile-dir", profileDir.path]
        if fake && action != .show { a.append("--fake") }
        return a
    }

    public func run(_ action: MeAction, profileDir: URL, brainDir: URL, fake: Bool, onLine: @escaping @Sendable (String) -> Void) async -> MeOutcome {
        let python = self.python ?? brainDir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return .failed(L10n.tr("brain python missing: \(python.path)")) }
        let out = Pipe(), err = Pipe()
        process.executableURL = python
        process.arguments = Self.arguments(action, profileDir: profileDir, fake: fake)
        process.currentDirectoryURL = brainDir
        process.standardOutput = out
        process.standardError = err
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let collected = LineCollector()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            for l in collected.add(d) { onLine(l) }
        }
        let stdout = OutputBox()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            stdout.append(d)
        }
        let exited: Int32 = await withCheckedContinuation { c in
            process.terminationHandler = { p in c.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                c.resume(returning: -1)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = collected.rest() { onLine(rest) }

        if lock.withLock({ cancelled }) { return .cancelled }
        if exited == -1 { return .failed(L10n.tr("could not start prep")) }
        guard exited == 0 else {
            let last = collected.lines.last { $0.hasPrefix("error:") } ?? collected.lines.last ?? L10n.tr("prep failed (exit \(exited))")
            return .failed(last)
        }
        return .done(stdout: stdout.text, log: collected.lines)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }
}

// MARK: - The model

/// The Me page: the profile's lines by section, its sources, how it was built, and the runs that rebuild it.
@MainActor
public final class MeModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case running(MeAction)
        case failed(String)
    }

    @Published public private(set) var sections: [MeSection: [MeLine]] = [:]
    @Published public private(set) var meta: MeMeta?
    @Published public private(set) var sources: [MeSource] = []
    @Published public private(set) var staleSources: [String] = []
    @Published public private(set) var phase = Phase.idle
    /// What the last run or edit said, for a line under the header ("Built · 3,140 tokens", "Nothing changed").
    @Published public private(set) var message: String?
    /// The last progress line of the running call.
    @Published public private(set) var progress: String?
    @Published public private(set) var hasProfile = false
    @Published public private(set) var hasSourcesFile = false

    public let directory: URL
    private let makeRunner: () -> any MeRunning
    private let brainDir: () -> URL?
    public var fake: () -> Bool
    public var now: () -> Date
    private var runner: (any MeRunning)?

    /// A build older than this, with a source changed since, shows "Sources changed · Refresh" (spec 2.2).
    public static let staleAfter: TimeInterval = 7 * 24 * 3600

    public init(directory: URL = MeProfilePaths.defaultDirectory, runner: @escaping () -> any MeRunning = { MePrep() },
                brainDir: (() -> URL?)? = nil, fake: @escaping () -> Bool = { false },
                now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.makeRunner = runner
        self.brainDir = brainDir ?? { VerseController.brainDir() }
        self.fake = fake
        self.now = now
        reload()
    }

    // MARK: files

    var mdURL: URL { directory.appendingPathComponent("me.md") }
    var metaURL: URL { directory.appendingPathComponent("me.meta.json") }
    var sourcesURL: URL { directory.appendingPathComponent("me.sources.json") }
    var factsURL: URL { directory.appendingPathComponent("me.facts.jsonl") }

    public var isRunning: Bool { if case .running = phase { return true }; return false }

    public func lines(_ section: MeSection) -> [MeLine] {
        (sections[section] ?? []).sorted { a, b in
            a.hasID != b.hasID ? a.hasID : MeFile.idNumber(a.id) < MeFile.idNumber(b.id)
        }
    }

    public func line(id: String) -> MeLine? {
        sections.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Reads the folder again. Cheap; the views call it when they appear and after every change.
    public func reload() {
        let fm = FileManager.default
        hasProfile = fm.fileExists(atPath: mdURL.path)
        if hasProfile, let text = try? String(contentsOf: mdURL, encoding: .utf8) {
            sections = MeFile.parse(text)
        } else {
            sections = [:]
        }
        meta = MeMeta.load(metaURL)
        hasSourcesFile = fm.fileExists(atPath: sourcesURL.path)
        sources = Self.readSources(sourcesURL).map { s in
            var s = s
            s.changed = staleSources.contains(s.label)
            return s
        }
    }

    static func readSources(_ url: URL) -> [MeSource] {
        guard let d = try? Data(contentsOf: url), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let path = o["path"] as? String, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return MeSource(id: o["id"] as? String ?? name, kind: o["kind"] as? String ?? "file", path: path,
                            label: (o["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name, enabled: o["enabled"] as? Bool ?? true)
        }
    }

    // MARK: derived

    /// "Sources changed · Refresh": a source changed since the last build and the build is more than 7 days old.
    public var showSourcesChanged: Bool {
        guard hasProfile, !staleSources.isEmpty, !isRunning else { return false }
        guard let built = meta?.builtAt else { return true }
        return now().timeIntervalSince(built) > Self.staleAfter
    }

    /// Where an edit may not happen: while prep writes the same files.
    public var canEdit: Bool { hasProfile && !isRunning }

    // MARK: edits

    public enum EditError: Error, Equatable, CustomStringConvertible {
        case busy, unknownLine, parts(expected: Int), empty, noRoom, noProfile, noSourcesFile, notFound(String), failed(String)
        public var description: String {
            switch self {
            case .busy: return L10n.tr("Wait for the refresh to finish.")
            case .unknownLine: return L10n.tr("That line is gone.")
            case .parts(let n): return L10n.tr("This line has \(n) parts separated by “|”. Keep all of them.")
            case .empty: return L10n.tr("A line cannot be empty.")
            case .noRoom: return L10n.tr("This section has no free line number.")
            case .noProfile: return L10n.tr("Build the profile first.")
            case .noSourcesFile: return L10n.tr("Build the profile once first: the default sources are chosen at the first build.")
            case .notFound(let p): return L10n.tr("No file at \(p).")
            case .failed(let m): return m
            }
        }
    }

    /// Replaces the text of a line, keeping its id and its source. The next refresh counts it as edited and keeps it.
    @discardableResult
    public func edit(id: String, to text: String) -> Result<Void, EditError> {
        guard !isRunning else { return .failure(.busy) }
        guard var line = line(id: id) else { return .failure(.unknownLine) }
        let clean = MeFile.oneLine(text)
        guard !clean.isEmpty else { return .failure(.empty) }
        let n = line.section.fieldCount
        var fields: [String]
        if n == 1 {
            fields = [clean.replacingOccurrences(of: " | ", with: " / ")]
        } else {
            fields = clean.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == n, !fields.contains(where: \.isEmpty) else { return .failure(.parts(expected: n)) }
        }
        guard line.hasID else { return .failure(.unknownLine) }
        line.fields = fields
        line.raw = MeFile.compose(id: line.id, fields: fields, source: line.source)
        return replace(line)
    }

    /// Removes a line. A generated line stays deleted at the next refresh (prep sees its id missing).
    @discardableResult
    public func delete(id: String) -> Result<Void, EditError> {
        guard !isRunning else { return .failure(.busy) }
        guard let line = line(id: id) else { return .failure(.unknownLine) }
        var all = sections
        all[line.section] = (all[line.section] ?? []).filter { $0.id != id }
        return write(all, touchesNumbers: line.section == .numbers)
    }

    /// Adds a line of his own under "My notes", with the next free id. It is read as it stands, never regenerated.
    @discardableResult
    public func addNote(_ text: String) -> Result<String, EditError> {
        guard !isRunning else { return .failure(.busy) }
        guard hasProfile else { return .failure(.noProfile) }
        let clean = MeFile.oneLine(text).replacingOccurrences(of: " | ", with: " / ")
        guard !clean.isEmpty else { return .failure(.empty) }
        var used = Set(sections.values.flatMap { $0 }.filter(\.hasID).map(\.id))
        used.formUnion(meta?.usedIDs ?? [])
        guard let id = MeFile.allocate(.notes, used: used) else { return .failure(.noRoom) }
        let raw = MeFile.compose(id: id, fields: [clean], source: OwnerProfile.current.sourceTag)
        var all = sections
        all[.notes, default: []].append(MeLine(id: id, hasID: true, section: .notes, fields: [clean], source: OwnerProfile.current.sourceTag, raw: raw))
        switch write(all, touchesNumbers: false) {
        case .success: return .success(id)
        case .failure(let e): return .failure(e)
        }
    }

    private func replace(_ line: MeLine) -> Result<Void, EditError> {
        var all = sections
        all[line.section] = (all[line.section] ?? []).map { $0.id == line.id ? line : $0 }
        return write(all, touchesNumbers: line.section == .numbers)
    }

    private func write(_ all: [MeSection: [MeLine]], touchesNumbers: Bool) -> Result<Void, EditError> {
        do {
            try Data(MeFile.render(all).utf8).write(to: mdURL, options: .atomic)
            if touchesNumbers { try writeFacts(all[.numbers] ?? []) }
        } catch {
            return .failure(.failed(L10n.tr("Could not save: \(error.localizedDescription)")))
        }
        reload()
        return .success(())
    }

    /// `me.facts.jsonl` again, so the fact chips of the next session follow an edited NUMBERS line (prep's `facts_records`: a
    /// line keeps the quote it was generated with).
    private func writeFacts(_ numbers: [MeLine]) throws {
        let quotes = meta?.quotes ?? [:]
        var out = ""
        for l in numbers.filter(\.hasID).sorted(by: { MeFile.idNumber($0.id) < MeFile.idNumber($1.id) }) {
            guard l.fields.count == 3, ["number", "date", "name"].contains(l.fields[0]) else { continue }
            let src = quotes[l.id] ?? ["kind": OwnerProfile.current.sourceTag, "ref": "me.md", "quote": l.fields[1]]
            let rec: [String: Any] = ["id": l.id, "kind": l.fields[0], "text": l.fields[1], "value": l.fields[2], "sources": [src]]
            let d = try JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys, .withoutEscapingSlashes])
            out += String(decoding: d, as: UTF8.self) + "\n"
        }
        try Data(out.utf8).write(to: factsURL, options: .atomic)
    }

    // MARK: sources

    /// Switches a source on or off for the next refresh.
    @discardableResult
    public func setSource(_ id: String, enabled: Bool) -> Result<Void, EditError> {
        mutateSources { arr in
            guard let i = arr.firstIndex(where: { ($0["id"] as? String) == id }) else { return false }
            arr[i]["enabled"] = enabled
            return true
        }
    }

    /// Adds a file (.md, .txt or .pdf) as a source.
    @discardableResult
    public func addSource(file url: URL) -> Result<Void, EditError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.notFound(url.path)) }
        return mutateSources { arr in
            if arr.contains(where: { ($0["path"] as? String) == url.path }) { return true }
            let nums = arr.compactMap { ($0["id"] as? String).flatMap { Int($0.dropFirst()) } }
            arr.append(["id": "s\((nums.max() ?? arr.count) + 1)", "kind": "file", "path": url.path, "label": url.lastPathComponent, "enabled": true])
            return true
        }
    }

    @discardableResult
    public func removeSource(_ id: String) -> Result<Void, EditError> {
        mutateSources { arr in
            let before = arr.count
            arr.removeAll { ($0["id"] as? String) == id }
            return arr.count != before
        }
    }

    private func mutateSources(_ change: (inout [[String: Any]]) -> Bool) -> Result<Void, EditError> {
        guard !isRunning else { return .failure(.busy) }
        guard hasSourcesFile, let d = try? Data(contentsOf: sourcesURL),
              var arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return .failure(.noSourcesFile) }
        guard change(&arr) else { return .failure(.unknownLine) }
        do {
            let out = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (out + Data("\n".utf8)).write(to: sourcesURL, options: .atomic)
        } catch {
            return .failure(.failed(L10n.tr("Could not save: \(error.localizedDescription)")))
        }
        reload()
        return .success(())
    }

    // MARK: runs

    /// Builds the profile the first time, refreshes it after. Refresh rebuilds only when a source changed and keeps every line
    /// he edited, added or deleted; it spends nothing when no source changed.
    public func refresh() async {
        await run(hasProfile ? .refresh : .build)
    }

    /// `prep me show`: which sources changed since the last build. No key, no network.
    public func checkSources() async {
        guard hasProfile, !isRunning, let brain = brainDir() else { return }
        let r = makeRunner()
        if case .done(let out, _) = await r.run(.show, profileDir: directory, brainDir: brain, fake: fake(), onLine: { _ in }) {
            staleSources = MeShow.parse(out).staleSources
            reload()
        }
    }

    public func cancel() { runner?.cancel() }

    private func run(_ action: MeAction) async {
        guard !isRunning else { return }
        guard let brain = brainDir() else {
            phase = .failed(L10n.tr("The brain folder was not found."))
            return
        }
        phase = .running(action)
        message = nil
        progress = nil
        let r = makeRunner()
        runner = r
        let outcome = await r.run(action, profileDir: directory, brainDir: brain, fake: fake(), onLine: { [weak self] line in
            Task { @MainActor in self?.progress = line }
        })
        runner = nil
        reload()
        switch outcome {
        case .done(_, let log):
            phase = .idle
            progress = nil
            if let nothing = log.first(where: { $0.hasPrefix("no source changed") }) {
                message = nothing.prefix(1).uppercased() + nothing.dropFirst()
            } else {
                message = meta.map { L10n.tr("Done · \($0.doneSummary)") } ?? L10n.tr("Done")
            }
            await checkSources()
        case .failed(let m):
            phase = .failed(m)
            progress = nil
        case .cancelled:
            phase = .idle
            progress = nil
            message = L10n.tr("Cancelled")
        }
    }
}
