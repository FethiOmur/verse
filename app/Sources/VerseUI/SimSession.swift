import Foundation
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

    public static func load(sessionDir: URL) -> SimPackSummary? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("sim.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return SimPackSummary(company: o["company"] as? String ?? "", role: o["role"] as? String ?? "",
                              questions: (o["questions"] as? [Any])?.count ?? 0, evidence: (o["evidence"] as? [Any])?.count ?? 0,
                              warnings: o["warnings"] as? [String] ?? [])
    }
}

/// The inputs of one practice interview, as the setup window collects them.
public struct SimSetup: Equatable, Sendable {
    public enum InterviewType: String, CaseIterable, Sendable { case screening, manager, technical, mixed }
    public enum Difficulty: String, CaseIterable, Sendable { case friendly, standard, tough }

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
        let tmp = fm.temporaryDirectory.appendingPathComponent("verse-sim-prep-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let postingFile = tmp.appendingPathComponent("posting.txt")
        var noteFile: URL?
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(setup.postingText.utf8).write(to: postingFile)
            let note = setup.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                let u = tmp.appendingPathComponent("note.md")
                try Data(note.utf8).write(to: u)
                noteFile = u
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failed("cannot write the posting for prep: \(error.localizedDescription)")
        }

        let out = Pipe(), err = Pipe()
        process.executableURL = python
        process.arguments = setup.prepArguments(postingFile: postingFile, noteFile: noteFile, out: root)
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
