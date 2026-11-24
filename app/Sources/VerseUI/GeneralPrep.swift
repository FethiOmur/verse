import Foundation

/// What unprepared calls start with (owner decision 4: one mechanism). Two standing folders can hold it, and only one is ever used:
///
/// - `sessions/persona-core`: the master persona compiled by the brain (`verse_brain/persona/compile.py`) from what he said in
///   his calls plus the general prep imported once. Used when the persona is on (`persona_dir` in the owner profile) and the
///   folder is a compiled one (its `.verse-compiled` marker) with a non-empty `pack.md`.
/// - `sessions/general-core`: the hand-built general prep. Never written by Verse; the import source and the fallback while no
///   persona exists.
///
/// "Use my general prep in unprepared calls" keeps its meaning: it means whichever of the two is current. Swift only copies the
/// chosen folder into adhoc folders and reports its state; both folders stay out of every session list (`isGeneral`).
public enum GeneralPrep {
    public static let name = "general-core"
    /// The compiled persona (`COMPILED_NAME` in brain/verse_brain/persona/compile.py).
    public static let personaName = "persona-core"
    /// The marker the brain writes into a folder it compiled.
    static let compiledMarker = ".verse-compiled"
    /// The files copied into an unprepared session, whichever exist.
    static let files = ["pack.md", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"]

    /// A standing prep folder, not a session: the general prep or the compiled persona.
    public static func isGeneral(_ session: String) -> Bool { session == name || session == personaName }

    /// Where an unprepared call's pack comes from.
    public enum Source: String, Sendable, Equatable {
        case persona, general, none

        /// The folder name the adhoc meta records as its `base`.
        var folder: String? {
            switch self {
            case .persona: GeneralPrep.personaName
            case .general: GeneralPrep.name
            case .none: nil
            }
        }
    }

    private static func packSize(_ folder: String, root: URL) -> Int {
        let u = SessionCatalog.url(folder, root: root).appendingPathComponent("pack.md")
        return (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0
    }

    /// True when `general-core/pack.md` exists and is non-empty.
    public static func isAvailable(root: URL) -> Bool { packSize(name, root: root) > 0 }

    /// True when `persona-core` is a folder the brain compiled and its `pack.md` is non-empty.
    public static func isPersonaCompiled(root: URL) -> Bool {
        let marker = SessionCatalog.url(personaName, root: root).appendingPathComponent(compiledMarker)
        return FileManager.default.fileExists(atPath: marker.path) && packSize(personaName, root: root) > 0
    }

    /// The one source an unprepared call uses: the compiled persona when the persona is on and compiled, else the general prep
    /// when it is built, else nothing (an empty pack).
    public static func source(root: URL, personaOn: Bool) -> Source {
        if personaOn && isPersonaCompiled(root: root) { return .persona }
        return isAvailable(root: root) ? .general : .none
    }

    /// Copies the prep files of the current source into `dir` (copies, never links: a later compile must not change a past
    /// session). Returns the source used, or `.none` having copied nothing when there is none or a copy fails (the caller then
    /// falls back to an empty pack instead of a half-seeded folder).
    static func seed(into dir: URL, root: URL, personaOn: Bool) -> Source {
        let source = source(root: root, personaOn: personaOn)
        guard let folder = source.folder, copy(from: folder, into: dir, root: root) else { return .none }
        return source
    }

    /// The general prep only (the seed before the persona existed); kept for callers that never use the persona.
    static func seed(into dir: URL, root: URL) -> Bool { seed(into: dir, root: root, personaOn: false) == .general }

    private static func copy(from folder: String, into dir: URL, root: URL) -> Bool {
        let fm = FileManager.default
        let src = SessionCatalog.url(folder, root: root)
        var copied: [URL] = []
        for f in files {
            let from = src.appendingPathComponent(f), to = dir.appendingPathComponent(f)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            do {
                try fm.copyItem(at: from, to: to)
                copied.append(to)
            } catch {
                for u in copied { try? fm.removeItem(at: u) }
                return false
            }
        }
        return true
    }

    public struct Status: Equatable, Sendable {
        public var answers: Int
        public var built: Date
        /// "12 answers · built 16 Oct 2026".
        public func text(locale: Locale = L10n.formatLocale, timeZone: TimeZone = .current) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = "d MMM yyyy"
            return "\(L10n.tr("\(answers) answers")) · \(L10n.tr("built \(f.string(from: built))"))"
        }
    }

    /// nil when not built (no non-empty pack). Answers = non-empty lines of `bank.jsonl`.
    public static func status(root: URL) -> Status? {
        guard isAvailable(root: root) else { return nil }
        return status(folder: name, root: root)
    }

    /// The status of the source unprepared calls use now, or nil when there is none.
    public static func status(root: URL, personaOn: Bool) -> (source: Source, status: Status)? {
        let s = source(root: root, personaOn: personaOn)
        guard let folder = s.folder else { return nil }
        return (s, status(folder: folder, root: root))
    }

    private static func status(folder: String, root: URL) -> Status {
        let dir = SessionCatalog.url(folder, root: root)
        let fm = FileManager.default
        let built = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("pack.md").path))?[.modificationDate] as? Date ?? .distantPast
        let bank = (try? String(contentsOf: dir.appendingPathComponent("bank.jsonl"), encoding: .utf8)) ?? ""
        let n = bank.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        return Status(answers: n, built: built)
    }
}
