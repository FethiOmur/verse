import Foundation
import VerseTurns
import VerseVoice
@testable import VerseUI
import XCTest

/// Wave 2 file-handling fixes: U3 (keychain save confirmed by the new value), V12 (key status off the main thread),
/// U5 (pipe drain, cancel before start), U8 (seed failure), U9 (lenient UTF-8), U10 (recording session keeps its index
/// rows). Nothing here touches the real Keychain, the network or `/Applications/Verse.app`.
@MainActor
final class Wave2FilesTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-wave2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: U3

    private let dummyKey = "sk-ant-" + String(repeating: "q", count: 20) + "WxYz"       // last 4: WxYz

    private func fakeSecurity(stored: W2Box<String?>, updateWorks: Bool) -> KeychainStore.SecurityRunner {
        return { args, stdin in
            if args == ["-i"] {
                if updateWorks, let line = stdin, let r = line.range(of: "verse-last4:") {
                    stored.with { $0 = String(line[r.upperBound...].prefix(4)) }
                }
                return .init(status: 0, stdout: "", stderr: updateWorks ? "" : "security: update not allowed")
            }
            if args.first == "find-generic-password" {
                guard let l = stored.with({ $0 }) else { return .init(status: 44, stdout: "", stderr: "not found") }
                return .init(status: 0, stdout: "    \"icmt\"<blob>=\"verse-last4:\(l)\"\n", stderr: "")
            }
            return .init(status: 1, stdout: "", stderr: "unexpected")
        }
    }

    func testKeychainSaveThrowsWhenTheUpdateFailedAndTheOldItemRemains() {
        let stored = W2Box<String?>("abcd")
        XCTAssertThrowsError(try KeychainStore.save(dummyKey, service: "verse-fake-TEST", account: "tester",
                                                    runner: fakeSecurity(stored: stored, updateWorks: false))) { error in
            guard case KeychainError.failed(let m) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertFalse(m.contains(dummyKey))
        }
    }

    func testKeychainSaveSucceedsWhenTheStoredLast4IsTheNewKeys() throws {
        let stored = W2Box<String?>("abcd")
        try KeychainStore.save(dummyKey, service: "verse-fake-TEST", account: "tester", runner: fakeSecurity(stored: stored, updateWorks: true))
        XCTAssertEqual(stored.with { $0 }, "WxYz")
    }

    // MARK: V12

    func testKeyStatusIsReadOffTheMainThread() async {
        let ranOnMain = W2Box<Bool?>(nil)
        let v = await HomeKeyStatusReader.read { () -> Int in ranOnMain.with { $0 = Thread.isMainThread }; return 7 }
        XCTAssertEqual(v, 7)
        XCTAssertEqual(ranOnMain.with { $0 }, false, "the `security` calls must not run on the main thread")
    }

    func testVoiceKeyAvailabilityPublishesAfterAnOffMainRead() async {
        let ranOnMain = W2Box<Bool?>(nil)
        let model = HomeVoiceKeyAvailability(read: { ranOnMain.with { $0 = Thread.isMainThread }; return [.openai] })
        model.refresh()
        XCTAssertFalse(model.isAvailable(.openai), "refresh() returns at once; the read has not published yet")
        let ok = await eventually(5) { model.isAvailable(.openai) }
        XCTAssertTrue(ok)
        XCTAssertEqual(ranOnMain.with { $0 }, false)
        XCTAssertFalse(model.isAvailable(.elevenlabs))
    }

    // MARK: U5

    private func script(_ dir: URL, _ body: String) throws -> URL {
        let u = dir.appendingPathComponent("fake-python-\(UUID().uuidString.prefix(6))")
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    func testPipeDrainWaitsForEOFSoALateLastWriteIsNotLost() async throws {
        let pipe = Pipe()
        let got = W2Box<Data>(Data())
        let drain = PipeDrain(pipe) { d in got.with { $0.append(d) } }
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data("first\n".utf8))
            Thread.sleep(forTimeInterval: 0.25)            // longer than the old fixed 50 ms
            try? writer.write(contentsOf: Data("last".utf8))
            try? writer.close()
        }
        await drain.waitForEOF(timeout: .seconds(5))
        drain.stop()
        XCTAssertEqual(String(decoding: got.with { $0 }, as: UTF8.self), "first\nlast")
    }

    func testMePrepKeepsTheLastStdoutLineAndAllStderrLines() async throws {
        let dir = try tempDir()
        let py = try script(dir, "echo progress-1 >&2\nprintf 'profile-folder-line'\necho progress-2 >&2\nprintf 'tail-no-newline' >&2")
        let lines = W2Box<[String]>([])
        let outcome = await MePrep(python: py).run(.build, profileDir: dir, brainDir: dir, fake: true, onLine: { l in lines.with { $0.append(l) } })
        XCTAssertEqual(outcome, .done(stdout: "profile-folder-line", log: ["progress-1", "progress-2", "tail-no-newline"]))
        // Since 193cd76 the page never shows prep's raw English lines: each line it does not know becomes the catalog's
        // "Working…" (the raw text goes to verse.log), while the outcome's log keeps every raw line.
        XCTAssertEqual(lines.with { $0 }, Array(repeating: L10n.tr("Working…"), count: 3))
    }

    func testMePrepCancelBeforeRunStartsNothing() async throws {
        let dir = try tempDir()
        let marker = dir.appendingPathComponent("started")
        let py = try script(dir, "touch '\(marker.path)'\necho x")
        let prep = MePrep(python: py)
        prep.cancel()
        let outcome = await prep.run(.build, profileDir: dir, brainDir: dir, fake: true, onLine: { _ in })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a cancel that came first must stop the process from starting")
    }

    // MARK: U8

    func testSeedReturnsFalseWhenACopyFails() throws {
        let root = try tempDir()
        let src = root.appendingPathComponent("general-core", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "# pack\n".write(to: src.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("no-such-folder", isDirectory: true)       // every copy into it fails
        XCTAssertFalse(GeneralPrep.seed(into: missing, root: root))
        let ok = root.appendingPathComponent("adhoc-ok", isDirectory: true)
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        XCTAssertTrue(GeneralPrep.seed(into: ok, root: root))
        XCTAssertEqual(try String(contentsOf: ok.appendingPathComponent("pack.md"), encoding: .utf8), "# pack\n")
    }

    // MARK: U9

    /// The bytes of two complete lines and a third cut in the middle of "é" (0xC3 0xA9).
    private func cutMidCharacter(_ lines: [String]) -> Data {
        var d = Data((lines.joined(separator: "\n") + "\n").utf8)
        d.append(Data(#"{"type":"q","id":"q9","text":"caf"#.utf8))
        d.append(0xC3)
        return d
    }

    func testChatLogLoadsTheCompleteLinesWhenTheLastOneIsCutMidCharacter() throws {
        let dir = try tempDir()
        let d = cutMidCharacter([#"{"type":"q","id":"q1","text":"first?","model":"m"}"#, #"{"type":"q","id":"q2","text":"second?","model":"m"}"#])
        try d.write(to: ChatLog.url(sessionDir: dir))
        let loaded = ChatLog.load(sessionDir: dir)
        XCTAssertEqual(loaded.turns.map(\.id), ["q1", "q2"])
        XCTAssertEqual(loaded.nextIndex, 3, "ids must continue, not restart at q1")
    }

    func testTranscriptReadersSurviveAPartialTrailingCharacter() throws {
        let dir = try tempDir()
        let d = cutMidCharacter([#"{"turn_id":"t1","speaker":"me","text":"hello","t_audio_end":1.0}"#, #"{"turn_id":"t2","speaker":"remote","text":"hi there","t_audio_end":2.0}"#])
        let url = dir.appendingPathComponent("transcript.jsonl")
        try d.write(to: url)
        XCTAssertEqual(TranscriptDocument.readTranscript(url).map(\.turnID), ["t1", "t2"])
    }

    // MARK: U10

    func testTheRecordingSessionKeepsItsIndexRowsDuringACall() async throws {
        let scratch = try MemoryFixtures.scratch()
        defer { scratch.remove() }
        let brains = MemBox<[ScriptedIndexBrain]>([])
        let s = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { MemoryFixtures.owner },
                              makeBrain: { let b = ScriptedIndexBrain(); brains.value.append(b); return b })
        s.busyRetryDelay = .milliseconds(50)
        s.indexStall = .seconds(10)

        _ = await s.syncNow(timeout: .seconds(10))                              // the index learns the three sessions
        s.recordingSession = { "corvo-design-call" }
        _ = await s.syncNow(timeout: .seconds(10))                              // a sync during that call
        XCTAssertEqual(brains.value.count, 2)
        XCTAssertFalse(brains.value[1].sentTypes.contains("drop"), "the recording session's rows must stay")
        XCTAssertEqual(brains.value[1].syncedNames, ["halden-kickoff", "halden-weekly-prep"])

        s.recordingSession = { nil }
        _ = await s.syncNow(timeout: .seconds(10))
        XCTAssertEqual(brains.value[2].syncedNames, ["corvo-design-call", "halden-kickoff", "halden-weekly-prep"])
        XCTAssertFalse(brains.value[2].sentTypes.contains("drop"))
    }
}

/// Thread-safe box for values written from a background thread.
final class W2Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
