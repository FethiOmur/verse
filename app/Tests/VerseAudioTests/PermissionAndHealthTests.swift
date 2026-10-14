import Foundation
import os
import VerseAudio
import VerseSpeech
import XCTest

/// Permission answers that can change during a run (models a grant revoked mid-call).
final class MutablePermissions: PermissionChecking, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var values: [PermissionKind: PermissionStatus]
    init(audioCapture: PermissionStatus, microphone: PermissionStatus) {
        values = [.audioCapture: audioCapture, .microphone: microphone]
    }
    func set(_ k: PermissionKind, _ s: PermissionStatus) { lock.withLockUnchecked { values[k] = s } }
    func status(_ kind: PermissionKind) -> PermissionStatus { lock.withLockUnchecked { values[kind] ?? .unknown } }
    func request(_ kind: PermissionKind) async -> PermissionStatus { status(kind) }
}

final class PermissionAndHealthTests: XCTestCase {

    func environment(_ perms: any PermissionChecking, remote: (any AudioCaptureSource)?,
                     mic: (any AudioCaptureSource)? = nil) -> ListenEnvironment {
        ListenEnvironment(permissions: perms,
                          makeRemoteSource: { _ in remote },
                          makeMicSource: { _ in mic },
                          makeEngine: ListenEnvironment.system.makeEngine)
    }

    /// Collects events and issues for `seconds`, then stops.
    func collect(_ session: ListenSession, seconds: Double) async throws -> ([TranscriptEvent], [ListenError]) {
        let stream = try await session.start()
        let issuesTask = Task { var out: [ListenError] = []; for await i in session.issues { out.append(i) }; return out }
        let eventsTask = Task { var out: [TranscriptEvent] = []; for await e in stream { out.append(e) }; return out }
        try await Task.sleep(for: .seconds(seconds))
        await session.stop()
        return (await eventsTask.value, await issuesTask.value)
    }

    func testPermissionDeniedVsSilence() async throws {
        // 1. TCC denied for system audio recording -> permissionDenied, before any audio flows.
        let denied = ListenSession(config: ListenConfig(lang: "en", micEnabled: false),
                                   environment: environment(FixedPermissions(audioCapture: .denied), remote: SilentSource()))
        do {
            _ = try await denied.start()
            XCTFail("expected permissionDenied(.audioCapture)")
        } catch let e as ListenError {
            XCTAssertEqual(e, .permissionDenied(.audioCapture))
        }

        // 2. Microphone denied -> permissionDenied(.microphone).
        let micDenied = ListenSession(config: ListenConfig(lang: "en", micEnabled: true),
                                      environment: environment(FixedPermissions(audioCapture: .granted, microphone: .denied),
                                                               remote: SilentSource(), mic: SilentSource()))
        do {
            _ = try await micDenied.start()
            XCTFail("expected permissionDenied(.microphone)")
        } catch let e as ListenError {
            XCTAssertEqual(e, .permissionDenied(.microphone))
        }

        // 3. Granted, the meeting app is silent (exact zeros, app not producing output) -> no error, no events.
        let silent = ListenSession(config: ListenConfig(lang: "en", micEnabled: false),
                                   environment: environment(FixedPermissions(), remote: SilentSource(simulatedTargetOutput: false)))
        let (events, issues) = try await collect(silent, seconds: 2.5)
        print("[testPermissionDeniedVsSilence] silence: \(events.count) events, issues \(issues)")
        XCTAssertTrue(events.isEmpty, "silence produced events: \(events.map(\.text))")
        XCTAssertTrue(issues.isEmpty, "silence produced issues: \(issues)")
    }

    /// Exact zeros for >= 1 s while the app is producing output -> deadStream; if TCC now says denied ->
    /// permissionDenied instead.
    func testDeadStreamWhileAppPlays() async throws {
        let source = SilentSource(simulatedTargetOutput: true)
        let session = ListenSession(config: ListenConfig(lang: "en", micEnabled: false),
                                    environment: environment(FixedPermissions(), remote: source))
        let (_, issues) = try await collect(session, seconds: 2.0)
        print("[testDeadStreamWhileAppPlays] issues \(issues)")
        XCTAssertEqual(issues.first, .deadStream(.remote))
        XCTAssertEqual(issues.count, 1, "dead stream should be reported once until audio returns")

        let perms = MutablePermissions(audioCapture: .notDetermined, microphone: .granted)
        let revoked = ListenSession(config: ListenConfig(lang: "en", micEnabled: false),
                                    environment: environment(perms, remote: SilentSource(simulatedTargetOutput: true)))
        let stream = try await revoked.start()
        perms.set(.audioCapture, .denied)
        let issuesTask = Task { var out: [ListenError] = []; for await i in revoked.issues { out.append(i) }; return out }
        try await Task.sleep(for: .seconds(2.0))
        await revoked.stop()
        for await _ in stream {}
        let revokedIssues = await issuesTask.value
        print("[testDeadStreamWhileAppPlays] revoked issues \(revokedIssues)")
        XCTAssertEqual(revokedIssues.first, .permissionDenied(.audioCapture))
    }

    func testDeadStreamDetectorRules() {
        var d = DeadStreamDetector()
        let zero = AudioChunk(samples: [Float](repeating: 0, count: 480), sampleRate: 48000, startTime: 0)
        d.observe(zero)
        XCTAssertEqual(d.check(now: 0.5, startedAt: 0, targetProducing: { true }), .ok)
        XCTAssertEqual(d.check(now: 1.1, startedAt: 0, targetProducing: { false }), .silence)
        XCTAssertEqual(d.check(now: 1.1, startedAt: 0, targetProducing: { true }), .dead)
        XCTAssertEqual(d.check(now: 1.5, startedAt: 0, targetProducing: { true }), .ok, "reported once")
        d.observe(AudioChunk(samples: [0.1] + [Float](repeating: 0, count: 479), sampleRate: 48000, startTime: 1.5))
        XCTAssertEqual(d.check(now: 1.52, startedAt: 0, targetProducing: { true }), .ok)
        // No callbacks at all for >= 1 s also counts.
        XCTAssertEqual(d.check(now: 2.6, startedAt: 0, targetProducing: { true }), .dead)
    }
}
