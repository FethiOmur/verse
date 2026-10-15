import Foundation
import Synchronization
@testable import VersePrompter
import VerseSpeech

final class ManualClock: PrompterClock {
    private let time = Mutex(0.0)
    func now() -> TimeInterval { time.withLock { $0 } }
    func set(_ t: TimeInterval) { time.withLock { $0 = t } }
    func sleep(until deadline: TimeInterval) async throws { try await Task.sleep(for: .milliseconds(5)) }
}

func event(_ text: String, channel: Channel = .me, final: Bool = false) -> TranscriptEvent {
    TranscriptEvent(channel: channel, text: text, isFinal: final, audioStart: 0, audioEnd: 0, emittedAt: 0, lang: "en")
}

/// Polls until `condition` holds (the session's input pumps are asynchronous). Fails after ~3 s.
func eventually(_ message: String = "condition", _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct ThrowingTranscriptSource: TranscriptSource {
    struct Failure: Error {}
    func events() async throws -> AsyncStream<TranscriptEvent> { throw Failure() }
    func stop() async {}
}

struct ThrowingLevelSource: LevelSource {
    struct Failure: Error {}
    func samples() async throws -> AsyncStream<Double> { throw Failure() }
    func stop() async {}
}

/// Transcript source the test feeds by hand.
final class FeedTranscriptSource: TranscriptSource {
    let broadcaster = TranscriptBroadcaster()
    func events() async throws -> AsyncStream<TranscriptEvent> { broadcaster.subscribe() }
    func stop() async { broadcaster.finish() }
}

/// Builds a minimal .pptx (a ZIP with ppt/notesSlides/notesSlideN.xml) with the system `zip`.
enum PPTXFixture {
    static func notesXML(_ paragraphs: [String], slideNumber: String? = "1") -> String {
        let body = paragraphs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        let number = slideNumber.map {
            "<p:sp><p:nvSpPr><p:nvPr><p:ph type=\"sldNum\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\($0)</a:t></a:r></a:p></p:txBody></p:sp>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp>\
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody>\(body)</p:txBody></p:sp>\(number)\
        </p:spTree></p:cSld></p:notes>
        """
    }

    /// `slides`: notes paragraphs per slide, in order. Returns the file URL inside a fresh temp directory.
    static func make(slides: [[String]], in directory: URL) throws -> URL {
        let work = directory.appendingPathComponent("pptx-src")
        let notes = work.appendingPathComponent("ppt/notesSlides")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for (i, paragraphs) in slides.enumerated() {
            try notesXML(paragraphs, slideNumber: "\(i + 1)")
                .write(to: notes.appendingPathComponent("notesSlide\(i + 1).xml"), atomically: true, encoding: .utf8)
        }
        let out = directory.appendingPathComponent("deck.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-r", "-q", out.path, "ppt"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(zip.terminationStatus)) }
        return out
    }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("VersePrompterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
