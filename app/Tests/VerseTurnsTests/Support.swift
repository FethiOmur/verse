import Foundation
import VerseSpeech
import VerseTurns
import XCTest

/// Synthetic speech fixtures made with `say` (CLI, no window) in a fresh temp directory. Test fixtures, not meeting
/// audio: every test deletes them before it ends, and the deletion is printed and asserted.
struct SayFixture {
    let dir: URL
    let file: URL

    static func make(voice: String, text: String) throws -> SayFixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fixture.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            try? FileManager.default.removeItem(at: dir)
            throw NSError(domain: "SayFixture", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "say -v \(voice) failed"])
        }
        return SayFixture(dir: dir, file: file)
    }

    func delete(file: StaticString = #filePath, line: UInt = #line) {
        try? FileManager.default.removeItem(at: dir)
        let gone = !FileManager.default.fileExists(atPath: dir.path)
        print("[fixture] deleted \(dir.lastPathComponent): \(gone ? "yes" : "NO")")
        XCTAssertTrue(gone, "fixture directory still exists: \(dir.path)", file: file, line: line)
    }
}

/// A transcript event at session time `t`. Volatile results cover [start, t] like the real recognizer's do.
func ev(_ text: String, at t: Double, channel: Channel = .remote, final: Bool = false, start: Double = 0, end: Double? = nil) -> TranscriptEvent {
    TranscriptEvent(channel: channel, text: text, isFinal: final, audioStart: start, audioEnd: end ?? t, emittedAt: t, lang: "en")
}

extension Array where Element == TurnEngine.Timed {
    var turns: [(at: Double, id: String, speaker: Speaker, text: String, addressee: Addressee)] {
        compactMap {
            if case .turn(let id, let sp, let text, let who, _) = $0.event { return ($0.at, id, sp, text, who) }
            return nil
        }
    }
    var partials: [(id: String, text: String, cue: Bool)] {
        compactMap {
            if case .partial(let id, _, let text, let cue, _) = $0.event { return (id, text, cue) }
            return nil
        }
    }
    var bankHits: [(id: String, bank: String, score: Double)] {
        compactMap {
            if case .bankHit(let id, let b, let s) = $0.event { return (id, b, s) }
            return nil
        }
    }
    var chips: [(kind: String, text: String, ref: String, factID: String)] {
        compactMap {
            if case .chip(_, let k, let t, let r, let f) = $0.event { return (k, t, r, f) }
            return nil
        }
    }
}

/// A small session folder in a temp dir (deleted by the caller).
struct TempSession {
    let dir: URL

    init(bank: [(id: String, question: String, paraphrases: [String])] = [], facts: [String] = [], glossary: [String] = []) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# pack\nTest pack.\n".write(to: dir.appendingPathComponent("pack.md"), atomically: true, encoding: .utf8)
        let bankLines = bank.map { b -> String in
            let para = b.paraphrases.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"id\":\"\(b.id)\",\"lang\":\"en\",\"question\":\"\(b.question)\",\"paraphrases\":{\"en\":[\(para)]},\"opener\":\"Sure.\",\"points\":[\"a\",\"b\",\"c\"],\"deep\":\"d\",\"sources\":[]}"
        }
        try (bankLines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("bank.jsonl"), atomically: true, encoding: .utf8)
        try (facts.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("facts.jsonl"), atomically: true, encoding: .utf8)
        try (glossary.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("glossary.jsonl"), atomically: true, encoding: .utf8)
    }

    func delete() { try? FileManager.default.removeItem(at: dir) }
}

/// The repo's `brain/` folder, found the way the product finds it.
func brainDir(file: StaticString = #filePath) throws -> URL {
    // Tests resolve brain/ from this source file's location (repo/app/Tests/VerseTurnsTests/ → repo/brain).
    let repo = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try BrainProcess.locateBrainDir(explicit: repo.appendingPathComponent("brain"))
}
