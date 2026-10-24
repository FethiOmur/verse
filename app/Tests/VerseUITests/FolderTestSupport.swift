import CryptoKit
import Foundation
@testable import VerseUI

/// Scratch sessions roots for the folder tests. Every name here is fictional; nothing reads or writes the user's real
/// `~/Library/Application Support/Verse/sessions`.
enum FolderFixtures {
    static func scratch() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("verse-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A session folder with a `pack.md`, optional extra files, and `summary.md`'s date set to `date`.
    @discardableResult
    static func session(_ name: String, in root: URL, at date: Date = Date(), pack: String = "", files: [String: String] = [:]) throws -> URL {
        let fm = FileManager.default
        let d = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(pack.utf8).write(to: d.appendingPathComponent("pack.md"))
        var all = files
        if all["summary.md"] == nil, !name.hasPrefix("sim-") { all["summary.md"] = "# Meeting summary\n\n## Summary\n\nA fictional call.\n" }
        for (f, text) in all {
            let u = d.appendingPathComponent(f)
            try Data(text.utf8).write(to: u)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        return d
    }

    static func defaults() -> (UserDefaults, () -> Void) {
        let suite = "dev.example.verse.test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    /// Every file under `dir` (relative path -> SHA-256 of its bytes), plus the directory names.
    static func snapshot(_ dir: URL) throws -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        let base = dir.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for case let u as URL in e {
            let rel = String(u.resolvingSymlinksInPath().path.dropFirst(base.count))
            if (try u.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { out[rel] = "dir"; continue }
            out[rel] = SHA256.hash(data: try Data(contentsOf: u)).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}
