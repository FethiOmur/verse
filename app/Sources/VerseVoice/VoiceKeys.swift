import Foundation

public enum VoiceKeyError: Error, Equatable, CustomStringConvertible {
    case invalidKey
    case notApplicable
    case failed(String)

    public var description: String {
        switch self {
        case .invalidKey: return "That does not look like an API key (letters, digits, - and _ only)."
        case .notApplicable: return "This voice does not use a key."
        case .failed(let m): return m
        }
    }
}

/// The ElevenLabs and OpenAI keys in the login Keychain: services `verse-elevenlabs` and `verse-openai`, account = the login
/// user name (the same rule as `verse-anthropic`, see `app/Sources/VerseUI/KeychainStore.swift`, whose pattern this mirrors).
///
/// Every write goes through `/usr/bin/security` with the command on its stdin (`security -i`), so the key never appears on
/// a command line (`ps`), in the environment, in a file or in a log, and the item is created by `security` (no prompt when
/// the engines read it back the same way). `hasKey` and `last4` use only the item's attributes (the last 4 characters are kept
/// in its comment); `read` is the one call that returns the secret, for the engines at speak time.
public enum VoiceKeys {
    /// The account the brain and the app use: `$USER`, else the login name.
    public static var account: String {
        let env = ProcessInfo.processInfo.environment["USER"] ?? ""
        return env.isEmpty ? NSUserName() : env
    }

    /// nil for the kinds that need no key (Apple, text).
    public static func service(for kind: VoiceKind) -> String? {
        switch kind {
        case .elevenlabs: return "verse-elevenlabs"
        case .openai: return "verse-openai"
        case .apple, .text: return nil
        }
    }

    // MARK: plan interface (the real services)

    public static func save(_ key: String, for kind: VoiceKind) throws {
        guard let s = service(for: kind) else { throw VoiceKeyError.notApplicable }
        try save(key, service: s)
    }
    public static func remove(_ kind: VoiceKind) throws {
        guard let s = service(for: kind) else { return }
        try remove(service: s)
    }
    public static func hasKey(_ kind: VoiceKind) -> Bool { service(for: kind).map { hasKey(service: $0) } ?? false }
    public static func last4(_ kind: VoiceKind) -> String? { service(for: kind).flatMap { last4(service: $0) } }
    /// The key itself, for the engines. nil when there is none.
    public static func read(_ kind: VoiceKind) -> String? { service(for: kind).flatMap { read(service: $0) } }

    // MARK: any service (tests use a TEST service name)

    /// Adds or replaces the item.
    public static func save(_ key: String, service: String, account: String = account) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausible(k) else { throw VoiceKeyError.invalidKey }
        guard isSafeToken(service), isSafeToken(account) else { throw VoiceKeyError.failed("unsupported service or account name") }
        let cmd = "add-generic-password -U -a \(account) -s \(service) -l \(service) -j \(commentPrefix)\(k.suffix(4)) -w \(k)\n"
        let r = run(["-i"], stdin: cmd)
        // `security -i` reports errors on stderr and exits 0 either way, so check the result.
        guard hasKey(service: service, account: account) else {
            throw VoiceKeyError.failed("the Keychain did not accept the key (\(r.stderr.isEmpty ? "exit \(r.status)" : sanitized(r.stderr, removing: k)))")
        }
    }

    public static func remove(service: String, account: String = account) throws {
        guard isSafeToken(service), isSafeToken(account) else { throw VoiceKeyError.failed("unsupported service or account name") }
        guard hasKey(service: service, account: account) else { return }
        let r = run(["delete-generic-password", "-a", account, "-s", service])
        if r.status != 0 || hasKey(service: service, account: account) {
            throw VoiceKeyError.failed("the Keychain item could not be removed (exit \(r.status))")
        }
    }

    public static func hasKey(service: String, account: String = account) -> Bool {
        guard isSafeToken(service), isSafeToken(account) else { return false }
        return run(["find-generic-password", "-a", account, "-s", service]).status == 0
    }

    /// The last 4 characters, when this app saved the key (nil for an item made elsewhere, or no item).
    public static func last4(service: String, account: String = account) -> String? {
        guard isSafeToken(service), isSafeToken(account) else { return nil }
        let r = run(["find-generic-password", "-a", account, "-s", service])
        guard r.status == 0 else { return nil }
        // Attribute dump only (no -w): `"icmt"<blob>="verse-last4:abcd"`.
        for line in (r.stdout + "\n" + r.stderr).split(separator: "\n") where line.contains("\"icmt\"") {
            guard let range = line.range(of: commentPrefix) else { continue }
            let rest = line[range.upperBound...].prefix { $0 != "\"" }
            if rest.count == 4 { return String(rest) }
        }
        return nil
    }

    /// The secret, read the way the brain reads its key (`security find-generic-password -w`): over a pipe, never in a log.
    public static func read(service: String, account: String = account) -> String? {
        guard isSafeToken(service), isSafeToken(account) else { return nil }
        let r = run(["find-generic-password", "-a", account, "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        let k = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    // MARK: helpers

    private static let securityTool = "/usr/bin/security"
    private static let commentPrefix = "verse-last4:"

    /// Provider keys are letters, digits, `-` and `_` (`sk-proj-...`, `sk_...`). Nothing else may reach the `security -i` line.
    static func isPlausible(_ k: String) -> Bool {
        k.count >= 20 && k.count <= 400
            && k.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }

    private static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.@".unicodeScalars.contains($0) }
    }

    private static func sanitized(_ s: String, removing key: String) -> String {
        s.replacingOccurrences(of: key, with: "[key]").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Result { var status: Int32; var stdout: String; var stderr: String }

    private static func run(_ args: [String], stdin: String? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: securityTool)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return Result(status: -1, stdout: "", stderr: "\(error)") }
        if let stdin {
            try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}
