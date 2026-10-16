import Foundation
@testable import VerseSpeech
import XCTest

/// `ListenConfig.micAsRemote` (anytime calls, room route): the one microphone is the remote pipeline.
final class RoomRouteSessionTests: XCTestCase {
    private func clip(_ seconds: Double) -> PCMClip {
        PCMClip(samples: GateDoubleTalkTests.voice(seconds: seconds, seed: 5), sampleRate: GateDoubleTalkTests.sr)
    }

    private func env(perms: FixedPermissions = FixedPermissions(), scripts: [Channel: [EngineResult]]) -> ListenEnvironment {
        ListenEnvironment(permissions: perms, makeRemoteSource: ListenEnvironment.system.makeRemoteSource,
                          makeMicSource: ListenEnvironment.system.makeMicSource,
                          makeEngine: { _ in ScriptedEngine(scripts: scripts) })
    }

    /// A mic-only memory clip arrives on the remote channel only: no `me` pipeline, no gate.
    func testMicClipIsTheRemoteChannelAndThereIsNoMe() async throws {
        let script: [Channel: [EngineResult]] = [
            .remote: [EngineResult(text: "can you walk me through it", isFinal: true, start: 0.4, end: 2.0)],
            .me: [EngineResult(text: "must never appear", isFinal: true, start: 0.4, end: 2.0)],
        ]
        var cfg = ListenConfig(lang: "en", source: .memory(remote: nil, me: clip(3)))
        cfg.micAsRemote = true
        let session = ListenSession(config: cfg, environment: env(scripts: script))
        let stream = try await session.start()
        var events: [TranscriptEvent] = []
        for await e in stream { events.append(e) }
        XCTAssertEqual(events.map(\.text), ["can you walk me through it"])
        XCTAssertEqual(Set(events.map(\.channel)), [.remote])
        let me = await session.channelOrigin(.me)
        let remote = await session.channelOrigin(.remote)
        XCTAssertNil(me)
        XCTAssertNotNil(remote)
        XCTAssertTrue(session.gateDecisions.isEmpty, "nothing plays on the Mac to bleed into the microphone")
    }

    /// Without the flag the same clip is `me`, as before.
    func testWithoutTheFlagTheMicClipIsMe() async throws {
        let script: [Channel: [EngineResult]] = [.me: [EngineResult(text: "my answer", isFinal: true, start: 0.4, end: 2.0)]]
        let cfg = ListenConfig(lang: "en", source: .memory(remote: nil, me: clip(3)))
        let session = ListenSession(config: cfg, environment: env(scripts: script))
        var events: [TranscriptEvent] = []
        for await e in try await session.start() { events.append(e) }
        XCTAssertEqual(Set(events.map(\.channel)), [.me])
    }

    /// The room route needs the microphone permission and not the system-audio one.
    func testRoomRouteChecksTheMicrophoneNotTheTap() async throws {
        func session(_ perms: FixedPermissions) -> ListenSession {
            var cfg = ListenConfig(lang: "en", source: .live)
            cfg.micAsRemote = true
            // A memory source stands in for the real microphone so no device is opened.
            let standIn = self.clip(1)
            let e = ListenEnvironment(permissions: perms,
                                      makeRemoteSource: { _ in MemorySource(clip: standIn, tailSeconds: 0.1, name: "stand-in mic") },
                                      makeMicSource: ListenEnvironment.system.makeMicSource,
                                      makeEngine: { _ in ScriptedEngine(scripts: [:]) })
            return ListenSession(config: cfg, environment: e)
        }
        // System-audio recording denied: irrelevant to the room route.
        let ok = session(FixedPermissions(audioCapture: .denied, microphone: .granted))
        var n = 0
        for await _ in try await ok.start() { n += 1 }
        // Microphone denied: the room route cannot listen.
        let denied = session(FixedPermissions(audioCapture: .granted, microphone: .denied))
        do {
            _ = try await denied.start()
            XCTFail("expected permissionDenied(.microphone)")
        } catch let e as ListenError {
            XCTAssertEqual(e.code, "permission_denied")
            XCTAssertEqual(e.description.contains("microphone"), true, e.description)
        }
    }
}
