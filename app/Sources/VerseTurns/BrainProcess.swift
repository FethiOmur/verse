import Darwin
import Foundation
import os

public enum BrainError: Error, CustomStringConvertible {
    case brainDirNotFound(String)
    case pythonMissing(String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .brainDirNotFound(let m): return "brain directory not found: \(m)"
        case .pythonMissing(let p): return "brain python missing: \(p) (create brain/.venv first)"
        case .spawnFailed(let m): return "could not start the brain: \(m)"
        }
    }
}

/// The Python brain as a child process: `brain/.venv/bin/python -u -m verse_brain.runtime`, JSON lines both ways.
///
/// The API key never passes through here: the brain reads the Keychain itself. This type only moves lines.
/// Every started brain is registered so that `killAll()` (signal handlers, error paths) can end it from anywhere.
public final class BrainProcess: @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let lineContinuation: AsyncStream<String>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = OSAllocatedUnfairLock()
    private var buffer = Data()
    private var stdinClosed = false
    private var exited = false
    private let onStderr: @Sendable (String) -> Void

    /// Finds `brain/` the way the tools are laid out in the repo: `VERSE_BRAIN_DIR`, then upward from the executable.
    /// The working directory is deliberately not searched: a planted `brain/.venv/bin/python` there would run with
    /// Keychain access.
    public static func locateBrainDir(explicit: URL? = nil) throws -> URL {
        let fm = FileManager.default
        func isBrain(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("verse_brain").path) }
        if let e = explicit {
            guard isBrain(e) else { throw BrainError.brainDirNotFound(e.path) }
            return e
        }
        if let env = ProcessInfo.processInfo.environment["VERSE_BRAIN_DIR"], !env.isEmpty {
            let u = URL(fileURLWithPath: env)
            guard isBrain(u) else { throw BrainError.brainDirNotFound(env) }
            return u
        }
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL { starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        for s in starts {
            var dir = s
            for _ in 0..<12 {
                let cand = dir.appendingPathComponent("brain")
                if isBrain(cand) { return cand }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        throw BrainError.brainDirNotFound("set VERSE_BRAIN_DIR or pass --brain-dir")
    }

    /// - Parameters:
    ///   - extraArgs: appended to `python -u -m verse_brain.runtime` (`--fake`, `--budget-usd N`).
    ///   - onStderr: gets each stderr line of the brain (logs; never contains the key by construction).
    public init(brainDir: URL, extraArgs: [String] = [], onStderr: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let python = brainDir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw BrainError.pythonMissing(python.path) }
        (lines, lineContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.onStderr = onStderr
        process.executableURL = python
        process.arguments = ["-u", "-m", "verse_brain.runtime"] + extraArgs
        process.currentDirectoryURL = brainDir
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                self.flushRest()
                return
            }
            self.consume(d)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            for l in String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline) { self.onStderr(String(l)) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.withLockUnchecked { self.exited = true }
            BrainRegistry.remove(self)
        }
        do { try process.run() } catch { throw BrainError.spawnFailed("\(error)") }
        BrainRegistry.add(self)
    }

    private func consume(_ d: Data) {
        let complete: [Data] = lock.withLockUnchecked {
            buffer.append(d)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        for l in complete where !l.isEmpty { lineContinuation.yield(String(decoding: l, as: UTF8.self)) }
    }

    private func flushRest() {
        let rest: Data = lock.withLockUnchecked { defer { buffer.removeAll() }; return buffer }
        if !rest.isEmpty { lineContinuation.yield(String(decoding: rest, as: UTF8.self)) }
        lineContinuation.finish()
    }

    /// Writes one JSON line. Failures (the brain is gone) are ignored on purpose: the exit shows up as the end of `lines`.
    public func send(_ line: String) {
        let closed = lock.withLockUnchecked { stdinClosed }
        guard !closed else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    private func closeStdin() {
        let already = lock.withLockUnchecked { () -> Bool in let a = stdinClosed; stdinClosed = true; return a }
        if !already { try? stdin.fileHandleForWriting.close() }
    }

    /// Asks the brain to stop, closes its stdin, and escalates to SIGTERM and SIGKILL when it does not leave.
    /// Returns once the process is gone.
    public func shutdown(grace: TimeInterval = 3.0) async {
        guard process.processIdentifier > 0 else { return }
        if process.isRunning {
            send(BrainCommand.stop.jsonLine())
            closeStdin()
            if await !waitForExit(grace) {
                process.terminate()
                if await !waitForExit(1.5) { kill(process.processIdentifier, SIGKILL); _ = await waitForExit(2.0) }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lineContinuation.finish()
        BrainRegistry.remove(self)
    }

    private func waitForExit(_ seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Synchronous hard stop for signal handlers and fatal paths.
    func killNow() {
        let p = process.processIdentifier
        guard p > 0 else { return }
        closeStdin()
        if process.isRunning {
            kill(p, SIGTERM)
            usleep(150_000)
            if process.isRunning { kill(p, SIGKILL) }
        }
    }

    /// Ends every brain this process started. Safe to call from a signal handler's dispatch source.
    public static func killAll() { BrainRegistry.killAll() }
}

private enum BrainRegistry {
    private static let lock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: BrainProcess] = [:]

    static func add(_ b: BrainProcess) { lock.withLockUnchecked { live[ObjectIdentifier(b)] = b } }
    static func remove(_ b: BrainProcess) { lock.withLockUnchecked { _ = live.removeValue(forKey: ObjectIdentifier(b)) } }
    static func killAll() {
        let all = lock.withLockUnchecked { Array(live.values) }
        for b in all { b.killNow() }
    }
}
