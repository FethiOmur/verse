import Foundation

/// Writes a meeting's `summary.md` into the vault as a new note. The spec (F2, "vault write stays opt-in") names no
/// folder, so notes go to `000-Inbox/Verse/` (in the real vault the inbox folder carries an emoji: `📥 000-Inbox`; any
/// top-level folder named `000-Inbox` or ending in ` 000-Inbox` is the one). Callers write only after a click.
public struct VaultSummaryWriter: Sendable {
    public enum WriteError: Error, Equatable, CustomStringConvertible {
        case vaultMissing(String)
        case noSummary
        case failed(String)

        public var description: String {
            switch self {
            case .vaultMissing(let p): return L10n.tr("The vault folder does not exist: \(p)")
            case .noSummary: return L10n.tr("There is no summary to save.")
            case .failed(let m): return L10n.tr("Could not write the note: \(m)")
            }
        }
    }

    public static let inboxName = "000-Inbox"
    public static let subfolder = "Verse"

    public var vaultRoot: URL

    public init(vaultRoot: URL) { self.vaultRoot = vaultRoot }

    /// The folder the note goes to (it may not exist yet).
    public func destinationFolder() -> URL {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: vaultRoot.path)) ?? []
        var isDir: ObjCBool = false
        let inbox = names.sorted().first {
            ($0 == Self.inboxName || $0.hasSuffix(" " + Self.inboxName))
                && fm.fileExists(atPath: vaultRoot.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        } ?? Self.inboxName
        return vaultRoot.appendingPathComponent(inbox, isDirectory: true).appendingPathComponent(Self.subfolder, isDirectory: true)
    }

    /// `2026-10-15 1530 Title.md`; characters that break paths or Obsidian links are dropped.
    public func fileName(title: String, date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        var t = String(title.unicodeScalars.filter { !"/\\:*?\"<>|#[]^".unicodeScalars.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init))
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        if t.isEmpty { t = "Meeting summary" }
        return "\(f.string(from: date)) \(t).md"
    }

    /// The note: the vault's note frontmatter (`📋 Templates/Note.md`: title, created, modified, type, status, tags) and the
    /// summary as written by the brain.
    public func noteText(summary: String, title: String, date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        return """
        ---
        title: "Meeting summary: \(safeTitle)"
        created: \(day)
        modified: \(day)
        type: note
        status: active
        tags: [verse, meeting-summary]
        ---
        \(summary.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    /// Writes a new note and returns its path. Never overwrites: an existing name gets ` (2)`, ` (3)`, ...
    /// The vault itself must exist; the inbox and `Verse` folders are created.
    @discardableResult
    public func write(summaryAt summaryURL: URL, title: String, date: Date = Date(), calendar: Calendar = .current) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vaultRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw WriteError.vaultMissing(vaultRoot.path)
        }
        guard let data = try? Data(contentsOf: summaryURL), let summary = String(data: data, encoding: .utf8),
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WriteError.noSummary }
        let folder = destinationFolder()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = fileName(title: title, date: date, calendar: calendar)
            let stem = (base as NSString).deletingPathExtension
            var target = folder.appendingPathComponent(base)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(stem) (\(n)).md")
                n += 1
            }
            try Data(noteText(summary: summary, title: title, date: date, calendar: calendar).utf8).write(to: target, options: .atomic)
            return target
        } catch let e as WriteError {
            throw e
        } catch {
            throw WriteError.failed((error as NSError).localizedDescription)
        }
    }
}
