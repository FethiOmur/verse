import Foundation

public enum CalendarPrepError: Error, Sendable, Equatable, CustomStringConvertible {
    case pythonMissing(String)
    case brainDirNotFound(String)
    case prepFailed(status: Int32, stderrTail: String)
    case noSessionInOutput

    public var description: String {
        switch self {
        case .pythonMissing(let p): return "brain python missing: \(p) (create brain/.venv first)"
        case .brainDirNotFound(let p): return "brain directory not found: \(p)"
        case .prepFailed(let s, let t): return "prep failed (exit \(s)): \(t)"
        case .noSessionInOutput: return "prep finished but printed no session folder"
        }
    }
}

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult
}

/// Runs a child process; stdout is read in full, stderr goes to a temp file so neither pipe can block.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let out = Pipe()
            let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("verse-meet-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let errHandle = try FileHandle(forWritingTo: errURL)
            defer {
                try? errHandle.close()
                try? FileManager.default.removeItem(at: errURL)
            }
            process.standardOutput = out
            process.standardError = errHandle
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let err = (try? Data(contentsOf: errURL)) ?? Data()
            return CommandResult(status: process.terminationStatus,
                                 stdout: String(decoding: data, as: UTF8.self),
                                 stderr: String(decoding: err, as: UTF8.self))
        }.value
    }
}

/// Builds a Verse session folder for a calendar event by running the brain's prep stage with `--from-event`.
public struct CalendarPrep: Sendable {
    public var brainDir: URL
    /// Defaults to `brainDir/.venv/bin/python`.
    public var python: URL
    /// Sessions root; nil keeps the prep default (`~/Library/Application Support/Verse/sessions`).
    public var outRoot: URL?
    /// Offline deterministic prep (no network, no spend). The default; pass `false` for a real model run.
    public var fake: Bool
    /// Hard spend cap for a live run.
    public var budgetUSD: Double
    private let runner: any CommandRunning

    public init(brainDir: URL, python: URL? = nil, outRoot: URL? = nil, fake: Bool = true, budgetUSD: Double = 0.45,
                runner: any CommandRunning = ProcessCommandRunner()) {
        self.brainDir = brainDir
        self.python = python ?? brainDir.appendingPathComponent(".venv/bin/python")
        self.outRoot = outRoot
        self.fake = fake
        self.budgetUSD = budgetUSD
        self.runner = runner
    }

    /// The prep command line, without the event file (exposed for tests).
    func arguments(eventFile: URL, repos: [URL], lang: String) -> [String] {
        var a = ["-m", "verse_brain.prep", "--from-event", eventFile.path, "--lang", lang]
        for r in repos { a += ["--repo", r.path] }
        if let outRoot { a += ["--out", outRoot.path] }
        if fake { a.append("--fake") } else { a += ["--budget-usd", String(budgetUSD)] }
        return a
    }

    /// Writes the event as JSON to a private temp file (removed afterwards), runs prep and returns the new session folder.
    public func makeSession(for event: MeetingEvent, repos: [URL] = [], lang: String = "en") async throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: brainDir.appendingPathComponent("verse_brain").path, isDirectory: &isDir), isDir.boolValue else {
            throw CalendarPrepError.brainDirNotFound(brainDir.path)
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw CalendarPrepError.pythonMissing(python.path) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("event.json")
        try event.jsonData().write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let r = try await runner.run(executable: python, arguments: arguments(eventFile: file, repos: repos, lang: lang), workingDirectory: brainDir)
        guard r.status == 0 else {
            let tail = String(r.stderr.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CalendarPrepError.prepFailed(status: r.status, stderrTail: tail)
        }
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.hasPrefix("session: ") }) else {
            throw CalendarPrepError.noSessionInOutput
        }
        return URL(fileURLWithPath: String(line.dropFirst("session: ".count)).trimmingCharacters(in: .whitespaces), isDirectory: true)
    }
}
