import Foundation
@testable import VerseUI
import XCTest

/// The manifest the app sends the index (memory spec 2.1): which sessions, and the fingerprint that says whether the index copy is current.
final class MemoryManifestTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!

    override func setUpWithError() throws { scratch = try MemoryFixtures.scratch() }
    override func tearDownWithError() throws { scratch.remove() }

    private var kickoff: URL { scratch.sessions.appendingPathComponent("halden-kickoff", isDirectory: true) }

    private func fp(_ dir: URL? = nil, owner: String = MemoryFixtures.owner) -> String {
        MemoryManifest.fingerprint(dir: dir ?? kickoff, ownerName: owner)
    }

    // MARK: fingerprint

    func testFingerprintIsAHexSHA256AndStable() {
        let a = fp()
        XCTAssertEqual(a.count, 64)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))
        XCTAssertEqual(a, fp())
    }

    func testEachOfTheSixFilesChangesTheFingerprintBySizeAndByMtime() throws {
        XCTAssertEqual(MemoryManifest.fingerprintFiles.count, 6)
        let t0 = Date(timeIntervalSince1970: 1_792_300_000)
        for f in MemoryManifest.fingerprintFiles {
            let url = kickoff.appendingPathComponent(f)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the fixture has \(f)")
            try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
            let base = fp()
            // mtime alone
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(37)], ofItemAtPath: url.path)
            XCTAssertNotEqual(fp(), base, "\(f): mtime")
            try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
            XCTAssertEqual(fp(), base, "\(f): the same size and mtime give the same fingerprint")
            // size alone (the mtime put back)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
            XCTAssertNotEqual(fp(), base, "\(f): size")
        }
    }

    func testTheOwnerNameChangesItBecauseSpeakerLabelsDependOnIt() {
        XCTAssertNotEqual(fp(owner: "Dana"), fp(owner: "Alex"))
    }

    func testAFileOutsideTheSixDoesNotChangeIt() throws {
        let before = fp()
        try MemoryFixtures.write("# review\n", to: kickoff.appendingPathComponent("review.md"))
        try MemoryFixtures.write("{}", to: kickoff.appendingPathComponent("spend.json"))
        XCTAssertEqual(fp(), before)
    }

    func testAMissingFileIsStableAndDiffersFromAPresentOne() throws {
        let corvo = scratch.sessions.appendingPathComponent("corvo-design-call", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corvo.appendingPathComponent("chat.jsonl").path))
        let before = fp(corvo)
        XCTAssertEqual(fp(corvo), before)
        try MemoryFixtures.write("{\"type\":\"reset\"}\n", to: corvo.appendingPathComponent("chat.jsonl"))
        XCTAssertNotEqual(fp(corvo), before, "the file appearing is a change")
    }

    func testTheFormatVersionIsPartOfIt() {
        XCTAssertEqual(MemoryIndexFormat.version, 1)
    }

    // MARK: manifest

    func testPracticeGeneralAndTheRecordingSessionAreLeftOut() throws {
        for name in ["sim-20261015-0930-brightwave", "general-core"] {
            try MemoryFixtures.write("# pack\n", to: scratch.sessions.appendingPathComponent(name).appendingPathComponent("pack.md"))
        }
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil, labels: { _ in [] })
        XCTAssertEqual(m.entries.map(\.name), ["corvo-design-call", "halden-kickoff", "halden-weekly-prep"])

        let recording = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: "corvo-design-call", labels: { _ in [] })
        XCTAssertEqual(recording.entries.map(\.name), ["halden-kickoff", "halden-weekly-prep"], "the call being recorded joins after Stop")
    }

    func testKindsAreMeetingCallAndPrepared() throws {
        try MemoryFixtures.write("", to: scratch.sessions.appendingPathComponent("adhoc-20261016-1432-room/pack.md"))
        try MemoryFixtures.write("{\"type\":\"x\"}\n", to: scratch.sessions.appendingPathComponent("adhoc-20261016-1432-room/transcript.jsonl"))
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil, labels: { _ in [] })
        let kinds = Dictionary(uniqueKeysWithValues: m.entries.map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds["halden-kickoff"], "meeting")
        XCTAssertEqual(kinds["corvo-design-call"], "meeting")
        XCTAssertEqual(kinds["halden-weekly-prep"], "prepared", "a pack without a summary is a prepared session")
        XCTAssertEqual(kinds["adhoc-20261016-1432-room"], "call")
    }

    func testLabelsComeFromTheClosureAndLanguageFromMeta() {
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil,
                                     labels: { $0.hasPrefix("halden") ? ["Marta Velin", "Halden Works"] : [] })
        let kick = m.entries.first { $0.name == "halden-kickoff" }
        XCTAssertEqual(kick?.labels, ["Marta Velin", "Halden Works"])
        XCTAssertEqual(kick?.lang, "en")
        XCTAssertEqual(kick?.title, "Halden Kickoff")
        XCTAssertEqual(m.entries.first { $0.name == "corvo-design-call" }?.labels, [])
        XCTAssertEqual(m.entries.first { $0.name == "corvo-design-call" }?.lang, "it")
    }

    func testLanguageIsEmptyWithoutMeta() throws {
        try FileManager.default.removeItem(at: scratch.sessions.appendingPathComponent("halden-weekly-prep/meta.json"))
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil, labels: { _ in [] })
        XCTAssertEqual(m.entries.first { $0.name == "halden-weekly-prep" }?.lang, "")
    }

    func testDateIsISO8601WithTheLocalOffset() {
        let tz = TimeZone(secondsFromGMT: 2 * 3600)!
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil, labels: { _ in [] }, timeZone: tz)
        for e in m.entries {
            XCTAssertNotNil(e.date.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+02:00$"#, options: .regularExpression), e.date)
        }
    }

    func testTheFingerprintInTheManifestIsTheSessionsOwn() {
        let m = MemoryManifest.build(root: scratch.sessions, ownerName: "Dana", recording: nil, labels: { _ in [] })
        XCTAssertEqual(m.entries.first { $0.name == "halden-kickoff" }?.fp, fp())
    }

    // MARK: wire

    func testSyncLineGolden() {
        let m = MemoryManifest(entries: [
            .init(name: "halden-kickoff", fp: "9c1e", labels: ["Marta Velin", "Halden Works"], title: "Halden Kickoff", date: "2026-10-19T17:00:00+02:00", kind: "meeting", lang: "en"),
            .init(name: "corvo-design-call", fp: "00ab", labels: [], title: "Corvo Design Call", date: "2026-10-20T10:00:00+02:00", kind: "meeting", lang: "it"),
        ])
        XCTAssertEqual(m.syncLine(), #"{"sessions":[{"fp":"9c1e","labels":["Marta Velin","Halden Works"],"name":"halden-kickoff"},{"fp":"00ab","labels":[],"name":"corvo-design-call"}],"type":"sync"}"#)
    }

    func testPutLineGolden() {
        let e = MemoryManifest.Entry(name: "halden-kickoff", fp: "9c1e", labels: ["Marta Velin"], title: "Halden Kickoff",
                                     date: "2026-10-19T17:00:00+02:00", kind: "meeting", lang: "en")
        let line = MemoryIndexer.putLine(e, dir: URL(fileURLWithPath: "/tmp/sessions/halden-kickoff"), rows: [AskRow(stamp: "0:18", speaker: "Dana", text: "Hello.")])
        XCTAssertEqual(line, #"{"date":"2026-10-19T17:00:00+02:00","dir":"/tmp/sessions/halden-kickoff","fp":"9c1e","kind":"meeting","labels":["Marta Velin"],"lang":"en","name":"halden-kickoff","rows":[{"speaker":"Dana","stamp":"0:18","text":"Hello."}],"title":"Halden Kickoff","type":"put"}"#)
    }

    func testEventParsing() {
        XCTAssertEqual(MemoryIndexEvent.parse(#"{"type":"sync_plan","need":["a"],"dropped":["b"],"relabelled":3}"#), .syncPlan(need: ["a"], dropped: ["b"], relabelled: 3))
        XCTAssertEqual(MemoryIndexEvent.parse(#"{"type":"put_done","name":"a","key":"sk3f9qa","chunks":61,"ms":38}"#), .putDone(name: "a", key: "sk3f9qa", chunks: 61))
        XCTAssertEqual(MemoryIndexEvent.parse(#"{"type":"embed_progress","done":120,"total":183}"#), .embedProgress(done: 120, total: 183))
        XCTAssertEqual(MemoryIndexEvent.parse(#"{"type":"status","state":"done","context":{"sessions":12,"chunks":744,"vectors":744,"embed":"on"}}"#),
                       .status(state: "done", message: "", sessions: 12, chunks: 744, vectors: 744, embed: "on"))
        XCTAssertNil(MemoryIndexEvent.parse(#"{"type":"ask_delta"}"#))
        XCTAssertNil(MemoryIndexEvent.parse("not json"))
    }
}
