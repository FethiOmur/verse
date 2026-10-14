import Foundation
import VerseAudio
import XCTest

/// Synthetic speech fixtures made with `say` (CLI, no window) in a fresh temp directory. They are test fixtures,
/// not meeting audio, and every test deletes them before it ends; the deletion is printed and asserted.
/// (Same helper exists in VerseSpeechTests; test targets cannot share files without a support target.)
struct SayFixture {
    let dir: URL
    let file: URL

    static func make(voice: String, text: String) throws -> SayFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-fixture-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "SayFixture", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "say -v \(voice) failed"])
        }
        return SayFixture(dir: dir, file: file)
    }

    /// Deletes the fixture directory and records that it is gone.
    func delete(file: StaticString = #filePath, line: UInt = #line) {
        try? FileManager.default.removeItem(at: dir)
        let gone = !FileManager.default.fileExists(atPath: dir.path)
        print("[fixture] deleted \(dir.lastPathComponent): \(gone ? "yes" : "NO")")
        XCTAssertTrue(gone, "fixture directory still exists: \(dir.path)", file: file, line: line)
    }

    /// Renders, reads into memory and deletes at once.
    static func clip(voice: String, text: String) throws -> PCMClip {
        let f = try make(voice: voice, text: text)
        defer { f.delete() }
        return try PCMClip.read(f.file)
    }
}

/// Lowercased words without punctuation, for "did this word appear yet" checks.
func words(_ s: String, locale: Locale = Locale(identifier: "en_US")) -> [String] {
    s.lowercased(with: locale)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}
