import Foundation
import VerseAudio
import VerseSpeech
import XCTest

/// Word error rate: word-level edit distance / reference length.
func wer(reference: [String], hypothesis: [String]) -> Double {
    guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
    var prev = Array(0...hypothesis.count)
    for i in 1...reference.count {
        var cur = [i] + [Int](repeating: 0, count: hypothesis.count)
        for j in stride(from: 1, through: hypothesis.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[hypothesis.count]) / Double(reference.count)
}

/// End to end through the REAL capture path: a child `verse-listen --play-test-file` (bundle ID dev.verse.listen)
/// plays known English speech; a bundle-ID process tap (muted, so nothing is heard) feeds ListenSession exactly as
/// in a meeting (48 kHz tap -> converter -> bestAvailableAudioFormat). Compared with the file path on the same audio.
final class TapPathTranscriptionTests: XCTestCase {
    static let script = "Could you explain how the new caching layer reduces latency for the mobile app, " +
        "and what happens when the cache is cold after a deploy?"

    func transcribe(_ session: ListenSession, during: () async throws -> Void) async throws -> [TranscriptEvent] {
        let stream = try await session.start()
        let collector = Task { var out: [TranscriptEvent] = []; for await e in stream { out.append(e) }; return out }
        try await during()
        await session.stop()
        return await collector.value
    }

    func testTapPathMatchesFilePathOnKnownScript() async throws {
        let fixture = try SayFixture.make(voice: "Samantha", text: Self.script)
        defer { fixture.delete() }
        let clip = try PCMClip.read(fixture.file)
        let reference = words(Self.script)

        // 1. File path.
        let fileSession = ListenSession(config: ListenConfig(lang: "en", micEnabled: false, source: .file(fixture.file)))
        let fileEvents = try await transcribe(fileSession) { await fileSession.waitUntilFinished() }
        let fileText = fileEvents.filter(\.isFinal).map(\.text).joined(separator: " ")
        let fileWER = wer(reference: reference, hypothesis: words(fileText))

        // 2. Real tap path (bundle ID, process restore, muted so the speakers/AirPods stay silent).
        let tap = ProcessTapSource(bundleIDs: ["dev.verse.listen"], preference: .bundleID, muteBehavior: .muted)
        let env = ListenEnvironment(permissions: FixedPermissions(), makeRemoteSource: { _ in tap },
                                    makeMicSource: { _ in nil }, makeEngine: ListenEnvironment.system.makeEngine)
        let tapSession = ListenSession(config: ListenConfig(lang: "en", micEnabled: false, source: .live), environment: env)
        let child = Process()
        child.executableURL = try ProcessTapTests.listenBinary()
        child.arguments = ["--play-test-file", fixture.file.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let tapEvents = try await transcribe(tapSession) {
            try await Task.sleep(for: .milliseconds(300))
            try child.run()
            let deadline = Date().addingTimeInterval(clip.duration + 5)
            while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try await Task.sleep(for: .seconds(2))   // let the recognizer settle on the pumped silence
        }
        let tapFinal = tapEvents.filter(\.isFinal).map(\.text).joined(separator: " ")
        let tapWER = wer(reference: reference, hypothesis: words(tapFinal))
        let tapVolatile = tapEvents.filter { !$0.isFinal }
        let gaps = zip(tapVolatile.dropFirst(), tapVolatile).map { $0.emittedAt - $1.emittedAt }
        let lv = await tapSession.levels(window: 60)

        print(String(format: "[tapPath] file path WER %.1f%% (%d events); tap path WER %.1f%% (%d events, %d volatile, max gap between volatile updates %.2f s); tap route: %@, tap format %@, chunks %d",
                     fileWER * 100, fileEvents.count, tapWER * 100, tapEvents.count, tapVolatile.count, gaps.max() ?? -1,
                     tap.routeDescription, tap.tapFormatDescription, lv[.remote]?.chunksTotal ?? -1))
        print("[tapPath] file final: \(fileText)")
        print("[tapPath] tap final:  \(tapFinal)")
        XCTAssertLessThanOrEqual(tapWER, 0.10, "tap path WER too high: \(tapFinal)")
        XCTAssertLessThanOrEqual(tapWER, fileWER + 0.05, "tap path is worse than the file path on the same audio")
        XCTAssertGreaterThanOrEqual(tapVolatile.count, 5, "volatile results were not streamed")
        XCTAssertLessThan(gaps.max() ?? 99, 2.0, "volatile results stalled while speech was playing")
    }
}
