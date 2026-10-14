import Foundation

public enum KeychainError: Error, CustomStringConvertible, Equatable {
    case invalidKey
    case failed(String)

    public var description: String {
        switch self {
        case .invalidKey: return "That does not look like an Anthropic API key (letters, digits, - and _ only)."
        case .failed(let m): return m
        }
    }
}

/// The API key in the login Keychain, where the brain reads it (`brain/verse_brain/prep/keychain.py`:
/// `security find-generic-password -a $USER -s verse-anthropic -w`).
///
/// Every write goes through `/usr/bin/security` itself, with the command on its stdin (`security -i`), so:
/// - the item's creator and trusted application is `security`, and the brain's read needs no password prompt
///   (an item created by this app through SecItemAdd would trust only this app and prompt when `security` reads it);
/// - the key never appears on a command line (`ps`), in the environment, in a file or in a log.
/// The value is never read back: `hasKey` and `last4` use the item's attributes (the last 4 characters are kept in
/// its comment when this app saves it).
public struct KeychainStore {
    public static let service = "verse-anthropic"

    /// The account the brain uses: `$USER`, else the login name.
    public static var account: String {
        let env = ProcessInfo.processInfo.environment["USER"] ?? ""
        return env.isEmpty ? NSUserName() : env
    }

    private static let securityTool = "/usr/bin/security"
    private static let commentPrefix = "verse-last4:"

    // MARK: plan interface (the real service)

    public static func save(_ key: String) throws { try save(key, service: service) }
    public static func remove() throws { try remove(service: service) }
    public static var hasKey: Bool { hasKey(service: service) }
    public static var last4: String? { last4(service: service) }

    // MARK: any service (tests use a TEST service name)

    /// Adds or replaces the item.
    public static func save(_ key: String, service: String, account: String = account) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausible(k) else { throw KeychainError.invalidKey }
        guard isSafeToken(service), isSafeToken(account) else { throw KeychainError.failed("unsupported service or account name") }
        let last = String(k.suffix(4))
        let cmd = "add-generic-password -U -a \(account) -s \(service) -l \(service) -j \(commentPrefix)\(last) -w \(k)\n"
        let r = run(["-i"], stdin: cmd)
        // `security -i` prints a prompt and reports errors on stderr; it exits 0 either way, so check the result.
        guard hasKey(service: service, account: account) else {
            throw KeychainError.failed("the Keychain did not accept the key (\(r.stderr.isEmpty ? "exit \(r.status)" : sanitized(r.stderr, removing: k)))")
        }
    }

    public static func remove(service: String, account: String = account) throws {
        guard isSafeToken(service), isSafeToken(account) else { throw KeychainError.failed("unsupported service or account name") }
        guard hasKey(service: service, account: account) else { return }
        let r = run(["delete-generic-password", "-a", account, "-s", service])
        if r.status != 0 || hasKey(service: service, account: account) {
            throw KeychainError.failed("the Keychain item could not be removed (exit \(r.status))")
        }
    }

    public static func hasKey(service: String, account: String = account) -> Bool {
        run(["find-generic-password", "-a", account, "-s", service]).status == 0
    }

    /// The last 4 characters, when this app saved the key (nil for an item made elsewhere, or no item).
    public static func last4(service: String, account: String = account) -> String? {
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

    // MARK: helpers

    /// Anthropic keys are `sk-ant-...`: letters, digits, `-` and `_`. Nothing else may reach the `security -i` line.
    static func isPlausible(_ k: String) -> Bool {
        k.count >= 20 && k.count <= 400 && k.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
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
