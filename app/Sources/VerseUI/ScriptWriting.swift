import Foundation
import VersePrompter

/// What a script is for; the brain writes pages differently for each.
public enum ScriptUse: String, CaseIterable, Identifiable, Sendable {
    case recording, talk
    public var id: String { rawValue }
    public var title: String { self == .recording ? L10n.tr("Recording") : L10n.tr("Talk") }
}

/// The brain's answer: the text (pages split by a `---` line, optional `[cues]`) and what it cost.
public struct ScriptDraft: Equatable, Sendable {
    public var text: String
    public var words: Int
    public var pages: Int
    public var targetWords: Int
    /// The voice profile was used. False: plain spoken English.
    public var usedVoiceProfile: Bool
    public var spendUSD: Double?
    public var warnings: [String]

    public init(text: String, words: Int, pages: Int, targetWords: Int, usedVoiceProfile: Bool, spendUSD: Double? = nil,
                warnings: [String] = []) {
        self.text = text
        self.words = words
        self.pages = pages
        self.targetWords = targetWords
        self.usedVoiceProfile = usedVoiceProfile
        self.spendUSD = spendUSD
        self.warnings = warnings
    }

    /// One JSON object as `python -m verse_brain.prep script --json` prints it.
    static func parse(_ data: Data) throws -> ScriptDraft {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptWriteError.badOutput
        }
        return ScriptDraft(text: text,
                           words: object["words"] as? Int ?? 0,
                           pages: object["pages"] as? Int ?? 1,
                           targetWords: object["target_words"] as? Int ?? 0,
                           usedVoiceProfile: object["voice"] as? Bool ?? false,
                           spendUSD: object["spend_usd"] as? Double,
                           warnings: object["warnings"] as? [String] ?? [])
    }
}

public enum ScriptWriteError: Error, LocalizedError, Equatable {
    case brainMissing(String)
    case failed(String)
    case badOutput
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .brainMissing(let detail): return L10n.tr("Verse could not find its brain: \(detail)")
        case .failed(let detail): return detail
        case .badOutput: return L10n.tr("The brain returned no script.")
        case .timedOut: return L10n.tr("Writing the script took too long and was stopped.")
        }
    }
}

public protocol ScriptWriting: Sendable {
    func write(topic: String, seconds: Int, use: ScriptUse) async throws -> ScriptDraft
}

/// Runs `brain/.venv/bin/python -m verse_brain.prep script ... --json` as a one-shot child process (the brain reads the
/// API key from the Keychain itself) and returns its JSON line. A script is written on demand, outside any meeting, so
/// it does not go through the long-lived runtime brain.
public struct BrainScriptWriter: ScriptWriting {
    /// The brain folder; nil: not found.
    var brainDir: @Sendable () async -> URL? = { await MainActor.run { VerseController.brainDir() } }
    /// Offline canned script (tests): no key, no network.
    var fake = false
    var timeout: TimeInterval = 240

    public init() {}

    init(brainDir: @escaping @Sendable () async -> URL?, fake: Bool = false, timeout: TimeInterval = 240) {
        self.brainDir = brainDir
        self.fake = fake
        self.timeout = timeout
    }

    static func arguments(topicFile: URL, seconds: Int, use: ScriptUse, fake: Bool) -> [String] {
        var args = ["-u", "-m", "verse_brain.prep", "script", "--topic-file", topicFile.path,
                    "--seconds", String(seconds), "--use", use.rawValue, "--json"]
        if fake { args += ["--fake"] }
        return args
    }

    public func write(topic: String, seconds: Int, use: ScriptUse) async throws -> ScriptDraft {
        guard let dir = await brainDir() else { throw ScriptWriteError.brainMissing("set VERSE_BRAIN_DIR") }
        let python = dir.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw ScriptWriteError.brainMissing("\(python.path) is missing (create brain/.venv first)")
        }
        // The topic goes through a private temp file, not the command line, where `ps` would show it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("verse-topic-\(UUID().uuidString).txt")
        try Data(topic.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await ChildProcess.run(executable: python, arguments: Self.arguments(topicFile: file, seconds: seconds, use: use, fake: fake),
                                                workingDirectory: dir, timeout: timeout)
        if result.timedOut { throw ScriptWriteError.timedOut }
        guard result.status == 0 else {
            let line = result.stderr.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("error:") }
                ?? result.stderr.split(whereSeparator: \.isNewline).map(String.init).last ?? "exit \(result.status)"
            throw ScriptWriteError.failed(line.hasPrefix("error: ") ? String(line.dropFirst(7)) : line)
        }
        return try ScriptDraft.parse(result.stdout)
    }
}

/// A short-lived child process whose output is collected whole. Used for the script command only.
enum ChildProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var timedOut: Bool
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func run(executable: URL, arguments: [String], workingDirectory: URL, timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONUNBUFFERED"] = "1"
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: ScriptWriteError.failed(L10n.tr("could not start the brain: \(error.localizedDescription)")))
                    return
                }
                let timedOut = Box(false)
                let watchdog = DispatchWorkItem {
                    if process.isRunning { timedOut.value = true; process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let errData = Box(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.value = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                group.wait()
                watchdog.cancel()
                continuation.resume(returning: Result(status: process.terminationStatus, stdout: outData,
                                                      stderr: String(decoding: errData.value, as: UTF8.self), timedOut: timedOut.value))
            }
        }
    }
}
