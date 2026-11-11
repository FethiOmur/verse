import Foundation

public enum CalendarPrepError: Error, Sendable, Equatable, CustomStringConvertible {
    case pythonMissing(String)
    case brainDirNotFound(String)
    case prepFailed(status: Int32, stderrTail: String)
    case noSessionInOutput
    /// A live run found no Anthropic key in the Keychain (the brain reads it; Swift never does).
    case apiKeyMissing

    public var description: String {
        switch self {
        case .pythonMissing(let p): return "brain python missing: \(p) (create brain/.venv first)"
        case .brainDirNotFound(let p): return "brain directory not found: \(p)"
        case .prepFailed(let s, let t): return "prep failed (exit \(s)): \(t)"
        case .noSessionInOutput: return "prep finished but printed no session folder"
        case .apiKeyMissing: return "No Anthropic API key in the Keychain. Add it in Settings (Anthropic API key), then prepare again."
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
///
/// Cancelling the calling task stops the child (S2: dismissing "Preparing…" or quitting used to cancel only the Swift
/// task while the Python prep went on spending up to its budget). It gets SIGINT first, so the prep's own cleanup runs
/// (its `.<id>.tmp` folder is removed, nothing is renamed into a session), then SIGTERM and SIGKILL if it is still alive
/// after `graceSeconds` each. The call then throws `CancellationError`.
public struct ProcessCommandRunner: CommandRunning {
    public var graceSeconds: Double

    public init(graceSeconds: Double = 3) {
        self.graceSeconds = graceSeconds
    }

    /// The child of one run, shared between the reading thread and the cancellation handler.
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Records the started process; false when the run was cancelled first (the caller then stops it itself).
        func started(_ p: Process) -> Bool {
            lock.withLock { process = p; return !cancelled }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel(grace: Double) {
            let p: Process? = lock.withLock { cancelled = true; return process }
            if let p { Self.stop(p, grace: grace) }
        }

        static func stop(_ p: Process, grace: Double) {
            guard p.isRunning else { return }
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    public func run(executable: URL, arguments: [String], workingDirectory: URL) async throws -> CommandResult {
        let child = Child()
        let grace = graceSeconds
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Self.runBlocking(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                                     child: child, grace: grace)
            }.value
        } onCancel: {
            child.cancel(grace: grace)
        }
    }

    private static func runBlocking(executable: URL, arguments: [String], workingDirectory: URL,
                                    child: Child, grace: Double) throws -> CommandResult {
        if child.isCancelled { throw CancellationError() }
        do {
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
            if !child.started(process) { Child.stop(process, grace: grace) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if child.isCancelled { throw CancellationError() }
            let err = (try? Data(contentsOf: errURL)) ?? Data()
            return CommandResult(status: process.terminationStatus,
                                 stdout: String(decoding: data, as: UTF8.self),
                                 stderr: String(decoding: err, as: UTF8.self))
        }
    }
}

/// Builds a Verse session folder for a calendar event by running the brain's prep stage with `--from-event`.
public struct CalendarPrep: Sendable {
    public var brainDir: URL
    /// Defaults to `brainDir/.venv/bin/python`.
    public var python: URL
    /// Sessions root; nil keeps the prep default (`~/Library/Application Support/Verse/sessions`).
    public var outRoot: URL?
    /// Offline deterministic prep (no network, no spend). The library default; the app builds `CalendarPrep.live` instead.
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

    /// The real model run the app uses: not fake, with the default spend cap. Tests inject `CalendarPrep(... fake: true ...)` instead.
    public static func live(brainDir: URL, python: URL? = nil, outRoot: URL? = nil,
                            runner: any CommandRunning = ProcessCommandRunner()) -> CalendarPrep {
        CalendarPrep(brainDir: brainDir, python: python, outRoot: outRoot, fake: false, runner: runner)
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
            if !fake, r.stderr.contains("Keychain item") || r.stderr.contains("Keychain read failed") { throw CalendarPrepError.apiKeyMissing }
            throw CalendarPrepError.prepFailed(status: r.status, stderrTail: tail)
        }
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.hasPrefix("session: ") }) else {
            throw CalendarPrepError.noSessionInOutput
        }
        return URL(fileURLWithPath: String(line.dropFirst("session: ".count)).trimmingCharacters(in: .whitespaces), isDirectory: true)
    }
}
