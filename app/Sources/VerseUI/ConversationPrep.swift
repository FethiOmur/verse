import Foundation

/// "New session from a conversation": the inputs the window collects, the folder rule and the process that runs
/// `python -m verse_brain.prep conversation`. The pasted thread reaches the process through a private temp file
/// (mode 0600 in a 0700 folder) that is removed when prep ends; no key and no thread text is ever on the command line
/// (prep reads the Anthropic key from the Keychain itself).
public struct ConversationSetup: Equatable, Sendable {
    public var thread = ""
    public var postingText = ""
    public var postingURL: URL?
    public var companyURL = ""
    public var note = ""
    /// The thread owner's name (Settings › owner), so prep can tell who wrote what.
    public var owner = "Alex"
    /// Canned model output, no key, no network (the app's "Fake brain" testing switch).
    public var fake = false

    public init(thread: String = "") { self.thread = thread }

    /// The `python -m verse_brain.prep conversation ...` arguments. Files are passed by path.
    public func prepArguments(threadFile: URL, postingFile: URL?, noteFile: URL?, out: URL) -> [String] {
        var a = ["-u", "-m", "verse_brain.prep", "conversation", "--thread", threadFile.path, "--out", out.path, "--lang", "en"]
        if let postingFile { a += ["--posting-file", postingFile.path] }
        if let u = postingURL { a += ["--posting-url", u.absoluteString] }
        let c = companyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { a += ["--company-url", c.contains("://") ? c : "https://" + c] }
        if let noteFile { a += ["--note", noteFile.path] }
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { a += ["--me", o] }
        if fake { a.append("--fake") }
        return a
    }
}

public enum ConversationSessionFolder {
    /// The folder prep printed, when it is a `conv-` folder directly under `root` that holds a `pack.md`; else nil.
    public static func validated(_ printed: String, root: URL = SessionCatalog.root) -> URL? {
        let p = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        let u = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
        let r = root.standardizedFileURL.resolvingSymlinksInPath()
        guard u.deletingLastPathComponent().path == r.path, u.lastPathComponent.hasPrefix("conv-"),
              FileManager.default.fileExists(atPath: u.appendingPathComponent("pack.md").path) else { return nil }
        return u
    }
}

/// What prep wrote into `meta.json` (`conversation` block) that the window shows.
public struct ConversationSummary: Equatable, Sendable {
    public var company: String
    public var people: [String]
    public var searches: Int
    public var sourced: Int
    public var unverified: Int
    public var bankEntries: Int
    public var costUSD: Double
    public var warnings: [String]

    public static func load(sessionDir: URL) -> ConversationSummary? {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("meta.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let c = o["conversation"] as? [String: Any] else { return nil }
        let cost = (c["cost_usd"] as? [String: Any])?["total"] as? Double ?? 0
        let stats = o["stats"] as? [String: Any]
        return ConversationSummary(
            company: c["company"] as? String ?? "", people: c["people"] as? [String] ?? [],
            searches: c["searches"] as? Int ?? 0, sourced: c["facts_sourced"] as? Int ?? 0,
            unverified: c["facts_unverified"] as? Int ?? 0, bankEntries: stats?["bank_entries"] as? Int ?? 0,
            costUSD: cost, warnings: o["warnings"] as? [String] ?? [])
    }
}

public enum ConversationOutcome: Sendable, Equatable {
    case done(URL)
    case failed(String)
    case cancelled
}

/// Runs prep for one conversation. The window model takes it as a protocol so tests can use a fake.
public protocol ConversationRunning: AnyObject, Sendable {
    func run(_ setup: ConversationSetup, brainDir: URL, root: URL, onLine: @escaping @Sendable (String) -> Void) async -> ConversationOutcome
    func cancel()
}

/// The real runner: a child process of the brain venv, like `SimPrep`.
public final class ConversationPrep: ConversationRunning, @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func run(_ setup: ConversationSetup, brainDir: URL, root: URL = SessionCatalog.root,
                    onLine: @escaping @Sendable (String) -> Void) async -> ConversationOutcome {
        let fm = FileManager.default
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        guard fm.isExecutableFile(atPath: python.path) else { return .failed(L10n.tr("brain python missing: \(python.path)")) }
        let tmp = fm.temporaryDirectory.appendingPathComponent("verse-conversation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let threadFile = tmp.appendingPathComponent("thread.txt")
        var postingFile: URL?
        var noteFile: URL?
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func write(_ name: String, _ text: String) throws -> URL {
                let u = tmp.appendingPathComponent(name)
                guard fm.createFile(atPath: u.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return u
            }
            _ = try write("thread.txt", setup.thread)
            let posting = setup.postingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !posting.isEmpty { postingFile = try write("posting.txt", posting) }
            let note = setup.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { noteFile = try write("note.md", note) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failed(L10n.tr("cannot write the conversation for prep: \(error.localizedDescription)"))
        }

        let out = Pipe(), err = Pipe()
        process.executableURL = python
        process.arguments = setup.prepArguments(threadFile: threadFile, postingFile: postingFile, noteFile: noteFile, out: root)
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
        let printed = stdout.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let dir = ConversationSessionFolder.validated(printed, root: root) else {
            return .failed(L10n.tr("prep did not report a session folder"))
        }
        return .done(dir)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }
}
