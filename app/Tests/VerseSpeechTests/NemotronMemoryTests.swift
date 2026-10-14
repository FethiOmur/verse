import Darwin
import Foundation
import VerseAudio
import XCTest
@testable import VerseSpeech

/// Memory and concurrency of the local engine. FluidAudio keeps a stream's state inside the manager, so two
/// channels need two managers (two copies of the 590 MB int8 encoder). These tests measure what that costs.
/// Run each in its own process for clean numbers (`--filter NemotronMemoryTests/testOneChannelFootprint`).
final class NemotronMemoryTests: XCTestCase {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func peakRssMB() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_maxrss) / 1_048_576          // bytes on macOS
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(NemotronModel.isInstalled(), "Nemotron model not installed")
    }

    private func run(channels: Int) async throws {
        let remote = try SayFixture.clip(voice: "Samantha", text: "What is the main risk in the current release plan?")
        let me = try SayFixture.clip(voice: "Alex", text: "I think the migration is the biggest risk for us.")
        let pad = PCMClip(samples: [Float](repeating: 0, count: Int(0.3 * me.sampleRate)) + me.samples, sampleRate: me.sampleRate)
        let before = Self.footprintMB()

        var config = ListenConfig(lang: "en", micEnabled: channels == 2,
                                  source: .memory(remote: remote, me: channels == 2 ? pad : nil))
        config.engineKind = .nemotron
        config.statusSink = nil
        let session = ListenSession(config: config)
        let t0 = Date()
        let stream = try await session.start()
        let loadSec = Date().timeIntervalSince(t0)
        let afterLoad = Self.footprintMB()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        let afterRun = Self.footprintMB()
        let remoteText = events.filter { $0.channel == .remote && $0.isFinal }.map(\.text).joined(separator: " ")
        let meText = events.filter { $0.channel == .me && $0.isFinal }.map(\.text).joined(separator: " ")
        print(String(format: "[NemotronMemory] channels=%d load %.1f s; footprint before %.0f MB, after load %.0f MB, after run %.0f MB; peak RSS %.0f MB; remote: '%@'; me: '%@'",
                     channels, loadSec, before, afterLoad, afterRun, Self.peakRssMB(), remoteText, meText))
        XCTAssertTrue(words(remoteText).contains("plan"), "remote text: \(remoteText)")
        if channels == 2 {
            // The two clips overlap in time on purpose (both decoders busy at once), so the bleed gate may drop
            // some `.me` events as echo; the channel must have produced text or have been gated, never be dead.
            XCTAssertTrue(!meText.isEmpty || session.droppedEchoEvents > 0, "me channel produced nothing: \(meText)")
        }
    }

    func testOneChannelFootprint() async throws { try await run(channels: 1) }
    func testTwoChannelsFootprint() async throws { try await run(channels: 2) }
}
