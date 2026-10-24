import Foundation
@testable import VerseSpeech
import XCTest

/// The startup self-clean of the Core ML compile cache: only dead, old `.tmp.<pid>_` bundles inside the cache roots go.
final class E5BundleCacheCleanerTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let deadPID: Int64 = 424_242
    private let livePID: Int64 = 515_151

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("e5rt-clean-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("cache/com.apple.e5rt.e5bundlecache", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: base) }

    /// `<root>/25G83/KEY/<name>` as a directory holding a 1000-byte payload, last modified `age` seconds before `t0`.
    @discardableResult
    private func bundle(_ name: String, age: TimeInterval, in key: String = "KEY", under top: URL? = nil) throws -> URL {
        let dir = (top ?? root).appendingPathComponent("25G83/\(key)/\(name)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("weights.bin"))
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: dir.path)
        return dir
    }

    private func cleaner(_ roots: [URL]? = nil) -> E5BundleCacheCleaner {
        let live = livePID, t = t0
        return E5BundleCacheCleaner(roots: roots ?? [root], now: { t }, isAlive: { $0 == live })
    }

    func testDeadAndOldIsRemovedAndCounted() throws {
        let tmp = try bundle("AB12.tmp.\(deadPID)_5000.bundle", age: 3600)
        let r = cleaner().run()
        XCTAssertFalse(fm.fileExists(atPath: tmp.path))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.removed, [tmp.path])
        XCTAssertGreaterThan(r.bytes, 0)
        XCTAssertEqual(r.failed, 0)
    }

    func testLivePidIsKept() throws {
        let tmp = try bundle("AB12.tmp.\(livePID)_5000.bundle", age: 3600)
        let r = cleaner().run()
        XCTAssertTrue(fm.fileExists(atPath: tmp.path))
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.keptLive, 1)
    }

    func testRecentEntryIsKeptEvenWithDeadPid() throws {
        let fresh = try bundle("AB12.tmp.\(deadPID)_1.bundle", age: 120)
        let edge = try bundle("AB12.tmp.\(deadPID)_2.bundle", age: 600)   // exactly 10 minutes: not older than
        let r = cleaner().run()
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: edge.path))
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.keptRecent, 2)
    }

    func testNonTmpNamesAreKept() throws {
        let committed = try bundle("AB12.bundle", age: 90_000)
        let lookalike = try bundle("AB12.tmp.bundle", age: 90_000)           // no pid
        let noUnderscore = try bundle("AB12.tmp.\(deadPID).bundle", age: 90_000)
        let milhash = root.appendingPathComponent("25G83/KEY/model.milhash")
        try Data("x".utf8).write(to: milhash)
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-90_000)], ofItemAtPath: milhash.path)
        let r = cleaner().run()
        for u in [committed, lookalike, noUnderscore, milhash] { XCTAssertTrue(fm.fileExists(atPath: u.path), u.lastPathComponent) }
        XCTAssertEqual(r.count, 0)
    }

    func testMixedDirectoryRemovesOnlyTheAbandonedOnes() throws {
        let dead = try bundle("H.tmp.\(deadPID)_1.bundle", age: 7200)
        let live = try bundle("H.tmp.\(livePID)_2.bundle", age: 7200)
        let fresh = try bundle("H.tmp.\(deadPID)_3.bundle", age: 5)
        let committed = try bundle("H.bundle", age: 7200)
        let r = cleaner().run()
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
        for u in [live, fresh, committed] { XCTAssertTrue(fm.fileExists(atPath: u.path), u.lastPathComponent) }
        XCTAssertEqual(r.count, 1)
    }

    func testSymlinkIsNotFollowedOutsideTheRoot() throws {
        // A directory outside the root with a perfectly removable-looking tmp bundle in it.
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let victim = outside.appendingPathComponent("KEY/X.tmp.\(deadPID)_9.bundle", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-90_000)], ofItemAtPath: victim.path)
        // 1) a symlinked directory inside the root pointing at it, 2) a tmp-named symlink pointing at it.
        try fm.createDirectory(at: root.appendingPathComponent("25G83"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("25G83/linked"), withDestinationURL: outside)
        let tmpLink = root.appendingPathComponent("25G83/H.tmp.\(deadPID)_1.bundle")
        try fm.createSymbolicLink(at: tmpLink, withDestinationURL: victim)
        let r = cleaner().run()
        XCTAssertTrue(fm.fileExists(atPath: victim.path), "target outside the root must survive")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: tmpLink.path), "the symlink itself is left alone too")
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.skippedSymlinks, 2)
    }

    func testOnlyTheGivenRootsAreTouched() throws {
        let other = base.appendingPathComponent("elsewhere/com.apple.e5rt.e5bundlecache", isDirectory: true)
        let outsideTmp = try bundle("H.tmp.\(deadPID)_1.bundle", age: 90_000, under: other)
        let inside = try bundle("H.tmp.\(deadPID)_1.bundle", age: 90_000)
        let r = cleaner().run()
        XCTAssertTrue(fm.fileExists(atPath: outsideTmp.path))
        XCTAssertFalse(fm.fileExists(atPath: inside.path))
        XCTAssertEqual(r.count, 1)
        // A root that does not exist is fine.
        XCTAssertEqual(cleaner([base.appendingPathComponent("nope")]).run().count, 0)
    }

    func testDryRunRemovesNothingButReportsTheSame() throws {
        let tmp = try bundle("H.tmp.\(deadPID)_1.bundle", age: 90_000)
        let dry = cleaner().run(dryRun: true)
        XCTAssertTrue(fm.fileExists(atPath: tmp.path))
        let real = cleaner().run()
        XCTAssertEqual(dry, real)
        XCTAssertFalse(fm.fileExists(atPath: tmp.path))
    }

    func testPidParsingAndLiveness() throws {
        XCTAssertEqual(E5BundleCacheCleaner.tmpPID(in: "D9E6.tmp.38554_51255182080.bundle"), 38554)
        XCTAssertNil(E5BundleCacheCleaner.tmpPID(in: "D9E6.bundle"))
        XCTAssertNil(E5BundleCacheCleaner.tmpPID(in: "model.milhash"))
        XCTAssertTrue(E5BundleCacheCleaner.processIsAlive(Int64(getpid())))
        XCTAssertTrue(E5BundleCacheCleaner.processIsAlive(0), "never address a process group")
        XCTAssertTrue(E5BundleCacheCleaner.processIsAlive(Int64.max))
        // A child that has exited and been reaped is gone (ESRCH).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        XCTAssertFalse(E5BundleCacheCleaner.processIsAlive(Int64(p.processIdentifier)))
    }

    func testDefaultRootsAreTheThreeVerseCaches() {
        let paths = E5BundleCacheCleaner.defaultRoots().map { $0.path }
        XCTAssertEqual(paths.count, 3)
        for id in ["dev.example.verse", "dev.verse.run", "dev.verse.listen"] {
            XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Caches/\(id)/com.apple.e5rt.e5bundlecache") }, id)
        }
    }
}
