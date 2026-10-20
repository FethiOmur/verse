import Foundation
import VerseMeet
import VerseTurns
import VerseVoice

/// Practice-interview session folders: `~/Library/Application Support/Verse/sessions/sim-<YYYYMMDD-HHMM>-<company-slug>/`
/// (plan S4, Shared contracts). S1's prep creates the folder and copies the confirmed `posting.txt` into it; the name
/// rule here is the same as prep's (`verse_brain.prep.sim.slugify`), so the app can say where the session will go and
/// check the path prep printed before trusting it.
public enum SimSessionFolder {
    /// `slugify` from prep: NFKD, ASCII only, lowercase, runs of anything else become `-`, at most 40 characters.
    public static func slug(_ name: String) -> String {
        let ascii = String(String.UnicodeScalarView(name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)))
        var out = ""
        var dash = false
        for ch in ascii.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let cut = String(trimmed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "company" : cut
    }

    /// `sim-20261015-0930-brightwave` (local time, like prep).
    public static func name(company: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "sim-\(f.string(from: date))-\(slug(company))"
    }

    /// The folder prep printed, when it is a sim folder directly under `root` that holds a `sim.json`; else nil.
    public static func validated(_ printed: String, root: URL = SessionCatalog.root) -> URL? {
        let p = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        let u = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
        let r = root.standardizedFileURL.resolvingSymlinksInPath()
        guard u.deletingLastPathComponent().path == r.path, u.lastPathComponent.hasPrefix("sim-"),
              FileManager.default.fileExists(atPath: u.appendingPathComponent("sim.json").path) else { return nil }
        return u
    }

    /// Finished practice sessions (those with a `report.html`), newest first.
    public static func reports(root: URL = SessionCatalog.root) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("sim-") }.sorted(by: >)
            .map { root.appendingPathComponent($0).appendingPathComponent("report.html") }
            .filter { fm.fileExists(atPath: $0.path) }
    }
}

/// What prep wrote into `sim.json` that the setup window shows.
public struct SimPackSummary: Equatable, Sendable {
    public var company: String
    public var role: String
    public var questions: Int
    public var evidence: Int
    public var warnings: [String]
    /// The interview language (`sim.json` `lang`): en, it or tr. Older packs have none (English).
    public var lang = "en"
    /// The meeting session the interview was built from (`"source":"session"`); nil for a job posting.
    public var sourceSession: String?

    public static func load(sessionDir: URL) -> SimPackSummary? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("sim.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return SimPackSummary(company: o["company"] as? String ?? "", role: o["role"] as? String ?? "",
                              questions: (o["questions"] as? [Any])?.count ?? 0, evidence: (o["evidence"] as? [Any])?.count ?? 0,
                              warnings: o["warnings"] as? [String] ?? [],
                              lang: Self.supportedLang(o["lang"] as? String),
                              sourceSession: o["source"] as? String == "session" ? o["source_session"] as? String : nil)
    }

    /// The interview language of a prepared sim folder (English when `sim.json` has none or cannot be read).
    public static func lang(sessionDir: URL) -> String { load(sessionDir: sessionDir)?.lang ?? "en" }

    /// `en`, `it` or `tr` for the first of a code such as `it-IT`; anything else is English (the brain's fixed lines do the same).
    static func supportedLang(_ code: String?) -> String {
        let c = (code ?? "").lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return ["en", "it", "tr"].contains(c) ? c : "en"
    }
}

/// The inputs of one practice interview, as the setup window collects them.
public struct SimSetup: Equatable, Sendable {
    public enum InterviewType: String, CaseIterable, Sendable { case screening, manager, technical, mixed }
    public enum Difficulty: String, CaseIterable, Sendable { case friendly, standard, tough }

    /// What the interview is built from: a prepared meeting session or a job posting (today's flow).
    public enum Source: String, CaseIterable, Sendable { case meeting, posting }

    public var source = Source.posting
    /// `.meeting`: the prepared session folder (its `pack.md` and `bank.jsonl`).
    public var meetingSession: URL?
    /// `.meeting`: the profile (`me.md`), only when "Use my profile in every session" is on and the file exists.
    public var meFile: URL?
    public var postingText: String
    public var postingURL: URL?
    /// Overrides the company prep reads from the posting (prefilled from the fetch).
    public var company = ""
    public var cv: URL?
    public var note = ""
    public var useVault = false
    public var repos: [String] = []
    public var type = InterviewType.mixed
    public var difficulty = Difficulty.standard
    public var lengthMin = 30
    public var mode = SimMode.coach
    public var voice = VoiceKind.apple
    public var hints = false
    /// Canned model output, no key, no network (the app's "Fake brain" testing switch).
    public var fake = false

    public init(postingText: String, postingURL: URL? = nil) {
        self.postingText = postingText
        self.postingURL = postingURL
    }

    /// The `python -m verse_brain.prep --sim ...` arguments. Files are passed by path; nothing secret is on the line
    /// (prep reads the Anthropic key from the Keychain itself).
    public func prepArguments(postingFile: URL, noteFile: URL?, out: URL) -> [String] {
        var a = ["-u", "-m", "verse_brain.prep", "--sim", "--posting-file", postingFile.path, "--out", out.path,
                 "--type", type.rawValue, "--difficulty", difficulty.rawValue, "--length", String(lengthMin), "--lang", "en"]
        if let u = postingURL { a += ["--posting-url", u.absoluteString] }
        if let cv { a += ["--cv", cv.path] }
        if let noteFile { a += ["--note", noteFile.path] }
        if !useVault { a.append("--no-vault") }
        for r in repos where !r.isEmpty { a += ["--repo", (r as NSString).expandingTildeInPath] }
        let c = company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { a += ["--company", c] }
        if fake { a.append("--fake") }
        return a
    }
}

extension SimSetup {
    /// The `python -m verse_brain.prep --sim --from-session ...` arguments for a mock interview built from a meeting.
    /// Paths only: the pack and the profile are read by prep from disk, so no text from either is on the line, and no
    /// key (prep reads the Anthropic key from the Keychain itself). The language is the session's (`meta.json`), the
    /// company and role come from the pack, so `--lang`, `--company`, `--posting-*`, `--cv`, `--note` and `--repo`
    /// are not passed (prep refuses the posting-only ones with `--from-session`).
    public func prepArguments(sessionDir: URL, out: URL) -> [String] {
        var a = ["-u", "-m", "verse_brain.prep", "--sim", "--from-session", sessionDir.path]
        if let meFile { a += ["--me", meFile.path] }
        a += ["--out", out.path, "--type", type.rawValue, "--difficulty", difficulty.rawValue, "--length", String(lengthMin)]
        if fake { a.append("--fake") }
        return a
    }
}

/// Runs S1's sim prep as a child process of the brain venv. The posting (and the note) go through a private temp
/// folder that is removed when prep ends; prep copies the posting into the new session folder as `posting.txt`.
public final class SimPrep: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case done(URL)
        case failed(String)
        case cancelled
    }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// Runs prep to the end. `onLine` gets prep's stderr lines (progress, `warning: ...`, `error: ...`).
    public func run(_ setup: SimSetup, brainDir: URL, root: URL = SessionCatalog.root,
                    onLine: @escaping @Sendable (String) -> Void) async -> Outcome {
        let fm = FileManager.default
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        guard fm.isExecutableFile(atPath: python.path) else { return .failed("brain python missing: \(python.path)") }
        // A job posting goes through a private temp folder; a meeting session is read by prep where it lies.
        var tmp: URL?
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        let arguments: [String]
        switch setup.source {
        case .meeting:
            guard let session = setup.meetingSession else { return .failed("no meeting is selected") }
            do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
                return .failed("cannot create the sessions folder: \(error.localizedDescription)")
            }
            arguments = setup.prepArguments(sessionDir: session, out: root)
        case .posting:
            let dir = fm.temporaryDirectory.appendingPathComponent("verse-sim-prep-\(UUID().uuidString)", isDirectory: true)
            tmp = dir
            let postingFile = dir.appendingPathComponent("posting.txt")
            var noteFile: URL?
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data(setup.postingText.utf8).write(to: postingFile)
                let note = setup.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    let u = dir.appendingPathComponent("note.md")
                    try Data(note.utf8).write(to: u)
                    noteFile = u
                }
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return .failed("cannot write the posting for prep: \(error.localizedDescription)")
            }
            arguments = setup.prepArguments(postingFile: postingFile, noteFile: noteFile, out: root)
        }

        let out = Pipe(), err = Pipe()
        process.executableURL = python
        process.arguments = arguments
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
        // Let the pipes drain.
        try? await Task.sleep(for: .milliseconds(50))
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = collected.rest() { onLine(rest) }

        if lock.withLock({ cancelled }) { return .cancelled }
        if exited == -1 { return .failed("could not start prep") }
        guard exited == 0 else {
            let last = collected.lines.last { $0.hasPrefix("error:") } ?? collected.lines.last ?? "prep failed (exit \(exited))"
            return .failed(last)
        }
        let printed = stdout.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let dir = SimSessionFolder.validated(printed, root: root) else {
            return .failed("prep did not report a session folder")
        }
        return .done(dir)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }
}

/// Splits a byte stream into lines.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all: [String] = []

    var lines: [String] { lock.withLock { all } }

    func add(_ d: Data) -> [String] {
        lock.withLock {
            buffer.append(d)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let l = String(decoding: buffer.subdata(in: buffer.startIndex..<nl), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !l.isEmpty { out.append(l) }
            }
            all += out
            return out
        }
    }

    func rest() -> String? {
        lock.withLock {
            defer { buffer.removeAll() }
            let l = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if l.isEmpty { return nil }
            all.append(l)
            return l
        }
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// A prepared meeting session a mock interview can be built from.
public struct PreparedMeeting: Identifiable, Equatable, Sendable {
    public var id: String { name }
    /// The session folder name.
    public let name: String
    /// How the popup shows it (the Sessions list's title for the folder).
    public let title: String
    /// The newest of its summary, its prep (`meta.json` `created_at`) and its pack.
    public let date: Date
    public let dir: URL
    /// The start of the calendar event this session belongs to (the soonest one in the next 14 days); nil when no upcoming
    /// event maps to it.
    public var eventStart: Date?
}

/// A calendar event the Meeting picker offers under "Upcoming": it has no prepared session yet.
public struct UpcomingMeeting: Identifiable, Equatable, Sendable {
    public let event: MeetingEvent
    public var id: String { event.id }
    public var start: Date { event.start }
    public var title: String {
        let t = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L10n.tr("Untitled event") : t
    }
}

/// One choice in the Meeting picker.
public enum MeetingChoice: Hashable, Sendable {
    /// A prepared session, by folder name.
    case prepared(String)
    /// A calendar event with no prepared session, by event id.
    case upcoming(String)
}

/// Which sessions the Practice page offers for "A meeting", and what it shows about the chosen one. Read-only.
public enum PracticeMeetings {
    /// What the pack holds, as the preview row counts it.
    public struct Preview: Equatable, Sendable {
        /// Non-empty lines of `bank.jsonl`: the likely questions the prep wrote answers for.
        public var questions: Int
        /// `[f…]` lines of the pack's FACTS section.
        public var facts: Int
    }

    /// Prepared means a non-empty `pack.md`. The standing general prep, unprepared calls (`adhoc-*`) and practice runs
    /// (`sim-*`) are not meetings.
    public static func isEligibleName(_ name: String) -> Bool {
        !GeneralPrep.isGeneral(name) && !SessionCatalog.isAdhoc(name) && !name.hasPrefix("sim-")
    }

    /// Prepared meeting sessions under `root`, newest first (ties by name).
    public static func list(root: URL = SessionCatalog.root) -> [PreparedMeeting] {
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        return SessionCatalog.list(root: root).filter(isEligibleName).compactMap { name -> PreparedMeeting? in
            let dir = SessionCatalog.url(name, root: root)
            let pack = dir.appendingPathComponent("pack.md")
            guard let size = (try? fm.attributesOfItem(atPath: pack.path))?[.size] as? Int, size > 0 else { return nil }
            let dates = [mtime(dir.appendingPathComponent("summary.md")), createdAt(dir), mtime(pack)].compactMap { $0 }
            return PreparedMeeting(name: name, title: HomeSession.title(forFolder: name), date: dates.max() ?? .distantPast, dir: dir)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
    }

    /// The default pick: the nearest Up next item that has a prepared session in `meetings`, else the newest.
    /// `upNext` is the Up next items' session names in calendar order (nil for an unprepared item).
    public static func defaultPick(upNext: [String?], among meetings: [PreparedMeeting]) -> String? {
        let names = Set(meetings.map(\.name))
        return upNext.compactMap { $0 }.first(where: names.contains) ?? meetings.first?.name
    }

    public static func preview(sessionDir: URL) -> Preview {
        let bank = (try? String(contentsOf: sessionDir.appendingPathComponent("bank.jsonl"), encoding: .utf8)) ?? ""
        let questions = bank.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        let pack = (try? String(contentsOf: sessionDir.appendingPathComponent("pack.md"), encoding: .utf8)) ?? ""
        var inFacts = false
        var facts = 0
        for raw in pack.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { inFacts = line.dropFirst(3).trimmingCharacters(in: .whitespaces).uppercased() == "FACTS"; continue }
            if inFacts, line.hasPrefix("[f"), line.contains("]") { facts += 1 }
        }
        return Preview(questions: questions, facts: facts)
    }

    /// `meta.json` `created_at` (ISO 8601), when the prep wrote one.
    private static func createdAt(_ dir: URL) -> Date? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let s = o["created_at"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - the Meeting picker's two groups

extension PracticeMeetings {
    /// How far ahead the picker looks for calendar events.
    public static let upcomingWindow: TimeInterval = 14 * 86_400

    /// What the picker lists: the prepared sessions, and the calendar events that have none.
    public struct Groups: Equatable, Sendable {
        public var prepared: [PreparedMeeting]
        public var upcoming: [UpcomingMeeting]
        public var isEmpty: Bool { prepared.isEmpty && upcoming.isEmpty }
    }

    /// Splits the next `window` of calendar events into the two groups. An event belongs to a prepared session when
    /// `MeetingSessionResolver` finds one (the id the app remembered, or one session named like the event); it then appears
    /// only under Prepared, which shows its date through `eventStart`. Every other event is Upcoming, soonest first. A
    /// recurring event comes with one entry per occurrence and one id: only its next occurrence counts.
    public static func groups(prepared: [PreparedMeeting], events: [MeetingEvent], remembered: [String: String], now: Date,
                              window: TimeInterval = upcomingWindow) -> Groups {
        let names = prepared.map(\.name)
        var starts: [String: Date] = [:]
        var upcoming: [UpcomingMeeting] = []
        var seen = Set<String>()
        let inWindow = events.filter { $0.end > now && $0.start <= now.addingTimeInterval(window) }
        for e in inWindow.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            if case .prepared(let name) = MeetingSessionResolver.plan(for: e, sessions: names, remembered: remembered, selected: nil) {
                if starts[name] == nil { starts[name] = e.start }
            } else if seen.insert(e.id).inserted {
                upcoming.append(UpcomingMeeting(event: e))
            }
        }
        return Groups(prepared: prepared.map { m in
            var m = m
            m.eventStart = starts[m.name]
            return m
        }, upcoming: upcoming)
    }

    /// The picker's rows, ready to show.
    public struct PickerMenu: Equatable, Sendable {
        public struct Entry: Equatable, Identifiable, Sendable {
            public var id: MeetingChoice
            public var label: String
        }
        public var prepared: [Entry]
        public var upcoming: [Entry]
    }

    public static func menu(_ g: Groups, now: Date = Date()) -> PickerMenu {
        PickerMenu(prepared: g.prepared.map { PickerMenu.Entry(id: .prepared($0.name), label: label($0.title, at: $0.eventStart, now: now)) },
             upcoming: g.upcoming.map { PickerMenu.Entry(id: .upcoming($0.id), label: label($0.title, at: $0.start, now: now)) })
    }

    /// "Northwind Labs technical · Tomorrow 10:00"; just the title when there is no date.
    public static func label(_ title: String, at start: Date?, now: Date = Date()) -> String {
        guard let start else { return title }
        return "\(title) · \(dayTime(start, now: now))"
    }

    /// "Today 15:00", "Tomorrow 10:00", "Thu 23 Oct 14:30".
    public static func dayTime(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDate(d, inSameDayAs: now) {
            day = L10n.tr("Today")
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            day = L10n.tr("Tomorrow")
        } else {
            day = d.formatted(HomeFormat.dayMonth)
        }
        return "\(day) \(d.formatted(HomeFormat.time))"
    }
}
