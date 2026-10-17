import Foundation

/// The standing general prep (`sessions/general-core`): evergreen Q&A that unprepared calls start with. The folder is a
/// normal prepared session built elsewhere; Swift only copies it into adhoc folders and reports its state.
public enum GeneralPrep {
    public static let name = "general-core"
    /// The files copied into an unprepared session, whichever exist.
    static let files = ["pack.md", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"]

    public static func isGeneral(_ session: String) -> Bool { session == name }

    /// True when `general-core/pack.md` exists and is non-empty.
    public static func isAvailable(root: URL) -> Bool {
        let u = SessionCatalog.url(name, root: root).appendingPathComponent("pack.md")
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0
        return size > 0
    }

    /// Copies the prep files into `dir` (copies, never links: a later rebuild must not change a past session).
    /// Returns false, having copied nothing, when the general prep is missing or empty.
    static func seed(into dir: URL, root: URL) -> Bool {
        guard isAvailable(root: root) else { return false }
        let fm = FileManager.default
        let src = SessionCatalog.url(name, root: root)
        for f in files {
            let from = src.appendingPathComponent(f), to = dir.appendingPathComponent(f)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
        }
        return true
    }

    public struct Status: Equatable, Sendable {
        public var answers: Int
        public var built: Date
        /// "12 answers · built 16 Oct 2026".
        public func text(locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = "d MMM yyyy"
            return "\(answers) \(answers == 1 ? "answer" : "answers") · built \(f.string(from: built))"
        }
    }

    /// nil when not built (no non-empty pack). Answers = non-empty lines of `bank.jsonl`.
    public static func status(root: URL) -> Status? {
        guard isAvailable(root: root) else { return nil }
        let dir = SessionCatalog.url(name, root: root)
        let fm = FileManager.default
        let built = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("pack.md").path))?[.modificationDate] as? Date ?? .distantPast
        let bank = (try? String(contentsOf: dir.appendingPathComponent("bank.jsonl"), encoding: .utf8)) ?? ""
        let n = bank.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        return Status(answers: n, built: built)
    }
}
