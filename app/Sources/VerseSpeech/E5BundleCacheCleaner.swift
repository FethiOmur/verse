import Darwin
import Foundation
import os

/// Startup self-clean of the Core ML / ANE compile cache.
///
/// CoreML compiles the Nemotron encoder for the Neural Engine into `<root>/<os build>/<key>/<hash>.tmp.<pid>_<n>.bundle` and
/// renames it to `<hash>.bundle` only when the compile finishes. A process that is killed mid-compile (a short replay
/// that is stopped, a timeout, a crash) leaves the `.tmp.` bundle behind and nothing ever removes it: 84 of them were
/// 32 GB once. This removes only the entries that are provably abandoned:
///
/// - the name has the `.tmp.<pid>_` shape (committed `<hash>.bundle` and `model.milhash` are never touched),
/// - `<pid>` is not a live process (`kill(pid, 0)` fails with ESRCH),
/// - the entry was last modified more than `minAge` ago (10 minutes), so a compile that just started is safe even if the
///   pid check is fooled,
/// - it sits inside one of the `roots` (symlinks are neither followed nor removed).
///
/// Deleting inside our own cache directory is the feature, so it uses plain `FileManager.removeItem`.
public struct E5BundleCacheCleaner: Sendable {
    /// The directory name Core ML uses inside an app's `~/Library/Caches/<bundle id>/`.
    public static let cacheDirName = "com.apple.e5rt.e5bundlecache"
    /// Verse's own processes: the menu-bar app, `verse-run` and `verse-listen`. Each one has its own cache root (Core ML keys
    /// it by the bundle id embedded in the executable), and each one cleans all of them: the liveness check keeps whatever a
    /// running sibling is compiling.
    public static let defaultBundleIDs = ["dev.fethiverse.verse", "dev.verse.run", "dev.verse.listen"]
    /// An abandoned bundle must be at least this old.
    public static let defaultMinAge: TimeInterval = 600
    /// `<root>/<os build>/<key>/<bundle>`: the bundles are three levels below the root.
    static let maxDepth = 3

    public struct Report: Sendable, Equatable {
        /// Paths removed (or, in a dry run, that would be).
        public var removed: [String] = []
        public var bytes: Int64 = 0
        public var keptLive = 0
        public var keptRecent = 0
        public var skippedSymlinks = 0
        public var failed = 0
        public var count: Int { removed.count }
    }

    public let roots: [URL]
    public let minAge: TimeInterval
    private let now: @Sendable () -> Date
    private let isAlive: @Sendable (Int64) -> Bool

    public init(roots: [URL],
                minAge: TimeInterval = E5BundleCacheCleaner.defaultMinAge,
                now: @escaping @Sendable () -> Date = { Date() },
                isAlive: @escaping @Sendable (Int64) -> Bool = E5BundleCacheCleaner.processIsAlive) {
        self.roots = roots
        self.minAge = minAge
        self.now = now
        self.isAlive = isAlive
    }

    // MARK: names and pids

    /// `<hash>.tmp.<pid>_<n>.bundle` -> `<pid>`; nil for every other name.
    static func tmpPID(in name: String) -> Int64? {
        guard let m = name.firstMatch(of: /\.tmp\.([0-9]{1,18})_/) else { return nil }
        return Int64(m.output.1)
    }

    /// True unless the process is certainly gone. `kill(pid, 0)` sends nothing: ESRCH means no such process, EPERM means it
    /// exists and belongs to someone else. A pid that cannot be a real one (<= 0, beyond Int32) counts as alive, so the
    /// entry is kept; `kill(0, …)` would otherwise address a whole process group.
    public static func processIsAlive(_ pid: Int64) -> Bool {
        guard pid > 0, pid <= Int64(Int32.max) else { return true }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno != ESRCH
    }

    // MARK: roots

    /// `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache` for each of Verse's bundle ids.
    public static func defaultRoots(bundleIDs: [String] = defaultBundleIDs) -> [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return bundleIDs.map { caches.appendingPathComponent($0, isDirectory: true).appendingPathComponent(cacheDirName, isDirectory: true) }
    }

    // MARK: clean

    /// Removes the abandoned bundles (or, with `dryRun`, only counts them).
    @discardableResult
    public func run(dryRun: Bool = false) -> Report {
        var report = Report()
        for root in roots { walk(root, root: root, depth: 1, dryRun: dryRun, report: &report) }
        return report
    }

    private func walk(_ dir: URL, root: URL, depth: Int, dryRun: Bool, report: inout Report) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let url = dir.appendingPathComponent(name)
            // lstat semantics: a symlink reports itself, so it is never followed (into or out of the root).
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let type = attrs[.type] as? FileAttributeType else { continue }
            if type == .typeSymbolicLink { report.skippedSymlinks += 1; continue }
            if let pid = Self.tmpPID(in: name) {
                consider(url, pid: pid, modified: attrs[.modificationDate] as? Date, root: root, dryRun: dryRun, report: &report)
            } else if type == .typeDirectory, depth < Self.maxDepth {
                walk(url, root: root, depth: depth + 1, dryRun: dryRun, report: &report)
            }
        }
    }

    private func consider(_ url: URL, pid: Int64, modified: Date?, root: URL, dryRun: Bool, report: inout Report) {
        guard url.path.hasPrefix(root.path + "/") else { return }
        guard let modified, now().timeIntervalSince(modified) > minAge else { report.keptRecent += 1; return }
        guard !isAlive(pid) else { report.keptLive += 1; return }
        let size = Self.allocatedSize(of: url)
        if !dryRun {
            do { try FileManager.default.removeItem(at: url) } catch { report.failed += 1; return }
        }
        report.removed.append(url.path)
        report.bytes += size
    }

    /// Disk bytes under `url` (symlinks inside are not followed).
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isSymbolicLinkKey]
        var total: Int64 = 0
        func add(_ u: URL) {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return }
            total += Int64(v.fileAllocatedSize ?? 0)
        }
        add(url)
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let u as URL in e { add(u) }
        }
        return total
    }

    // MARK: once per process

    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// Runs one clean of Verse's own cache roots on a background queue, the first time it is called in this process; later calls
    /// do nothing. `log` gets one line when something was removed or could not be.
    public static func startOnce(roots: [URL] = defaultRoots(), log: @escaping @Sendable (String) -> Void) {
        let first = started.withLock { s -> Bool in
            if s { return false }
            s = true
            return true
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            let r = E5BundleCacheCleaner(roots: roots).run()
            guard r.count > 0 || r.failed > 0 else { return }
            let mb = Double(r.bytes) / 1_048_576
            log("e5rt cache: removed \(r.count) abandoned compile bundle(s), \(String(format: "%.1f", mb)) MB freed" + (r.failed > 0 ? ", \(r.failed) could not be removed" : ""))
        }
    }
}
