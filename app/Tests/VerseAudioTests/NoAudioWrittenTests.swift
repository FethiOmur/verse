import CoreServices
import Foundation
import os
import VerseAudio
import VerseSpeech
import XCTest

/// Records every file created, renamed or modified under the watched roots while it runs (FSEvents, file-level).
final class FileWatcher: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var paths: [String] = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "verse.test.fsevents")

    init(roots: [String]) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            let wanted = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
            for i in 0..<count where flags[i] & wanted != 0 && flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                if let p = arr[i] as? String { me.lock.withLockUnchecked { me.paths.append(p) } }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, cb, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    var started: Bool { stream != nil }

    func stop() -> [String] {
        if let s = stream {
            FSEventStreamFlushSync(s)
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        return lock.withLockUnchecked { paths }
    }
}

final class NoAudioWrittenTests: XCTestCase {
    static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "m4a", "mp3", "mp4", "aac",
                                               "flac", "pcm", "opus", "ogg", "amr", "3gp", "snd", "au"]

    static func audioFiles(under root: String, modifiedAfter: Date, excluding: String) -> [String] {
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                      options: [], errorHandler: { _, _ in true }) else { return [] }
        var out: [String] = []
        for case let u as URL in en {
            guard audioExtensions.contains(u.pathExtension.lowercased()), !u.path.hasPrefix(excluding) else { continue }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if v?.isRegularFile == true, let m = v?.contentModificationDate, m >= modifiedAfter { out.append(u.path) }
        }
        return out
    }

    /// Runs the file source for about 5 s while watching the temp dirs, Application Support/Verse and the package
    /// dir: no audio file may appear (the fixture's own directory is excluded; it was created before the watch).
    func testNoAudioWritten() async throws {
        let fixture = try SayFixture.make(voice: "Samantha",
                                          text: "Tell me about the budget for the next quarter and who signs it off.")
        defer { fixture.delete() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let roots = [
            URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path,
            "/private/tmp",
            home + "/Library/Application Support/Verse",
            home + "/Library/Caches",
            packageDir,
        ].filter { FileManager.default.fileExists(atPath: $0) }
        let fixtureDir = fixture.dir.resolvingSymlinksInPath().path

        let t0 = Date()
        let watcher = FileWatcher(roots: roots)
        XCTAssertTrue(watcher.started, "FSEvents stream did not start")

        let clip = try PCMClip.read(fixture.file)
        var config = ListenConfig(lang: "en", micEnabled: false, source: .file(fixture.file))
        config.clipTailSeconds = max(0, 5.0 - clip.duration)
        let session = ListenSession(config: config)
        let stream = try await session.start()
        var events = 0
        for await _ in stream { events += 1 }

        try await Task.sleep(for: .milliseconds(300))
        let changed = watcher.stop()
        let elapsed = Date().timeIntervalSince(t0)
        let audioChanged = changed.filter {
            Self.audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && !$0.hasPrefix(fixtureDir)
                && !$0.hasPrefix(fixture.dir.path)
        }
        let scanned = roots.flatMap { Self.audioFiles(under: $0, modifiedAfter: t0, excluding: fixtureDir) }
            .filter { !$0.hasPrefix(fixture.dir.path) }
        print(String(format: "[testNoAudioWritten] ran %.1f s, %d events; watched %d roots; %d file events in total, %d audio; scan found %d new audio files",
                     elapsed, events, roots.count, changed.count, audioChanged.count, scanned.count))
        XCTAssertGreaterThanOrEqual(elapsed, 5.0)
        XCTAssertGreaterThan(events, 0)
        XCTAssertEqual(audioChanged, [], "audio files appeared: \(audioChanged)")
        XCTAssertEqual(scanned, [], "audio files appeared: \(scanned)")
    }
}
