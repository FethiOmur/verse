import Foundation
import VerseAudio
import VerseSpeech
import XCTest

/// The menu's "Play test file as remote…": a file on the remote channel while the real microphone stays "me".
final class RemoteFileMicTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/interviewer.wav")

    private func config(micWithFile: Bool) -> ListenConfig {
        var c = ListenConfig(lang: "en", micEnabled: true, source: .file(file))
        c.micWithFile = micWithFile
        return c
    }

    /// The real environment builds a microphone source for a file run only when asked to (nothing is started here).
    func testSystemEnvironmentOpensTheMicOnlyWhenAsked() throws {
        XCTAssertNil(try ListenEnvironment.system.makeMicSource(config(micWithFile: false)), "--file stays remote-only")
        XCTAssertTrue(try ListenEnvironment.system.makeMicSource(config(micWithFile: true)) is MicSource)
        var off = config(micWithFile: true)
        off.micEnabled = false
        XCTAssertNil(try ListenEnvironment.system.makeMicSource(off), "micEnabled=false wins")
    }

    private func environment(_ perms: any PermissionChecking, micFactoryCalls: Box) -> ListenEnvironment {
        ListenEnvironment(permissions: perms,
                          makeRemoteSource: { _ in SilentSource() },
                          makeMicSource: { cfg in
                              micFactoryCalls.n += 1
                              return cfg.micEnabled && cfg.micWithFile ? SilentSource() : nil
                          },
                          makeEngine: ListenEnvironment.system.makeEngine)
    }

    final class Box: @unchecked Sendable { var n = 0 }

    /// A file run with the microphone checks the microphone permission, like a live run does.
    func testFileWithMicChecksMicrophonePermission() async {
        let calls = Box()
        let denied = ListenSession(config: config(micWithFile: true),
                                   environment: environment(FixedPermissions(audioCapture: .denied, microphone: .denied), micFactoryCalls: calls))
        do {
            _ = try await denied.start()
            XCTFail("expected permissionDenied(.microphone)")
        } catch let e as ListenError {
            XCTAssertEqual(e, .permissionDenied(.microphone), "system audio is not needed for a file, the microphone is")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(calls.n, 1)
    }

    /// A plain file run (today's `--file`) never touches the microphone permission.
    func testPlainFileRunNeverChecksTheMicrophone() async throws {
        let calls = Box()
        let session = ListenSession(config: config(micWithFile: false),
                                    environment: environment(FixedPermissions(audioCapture: .denied, microphone: .denied), micFactoryCalls: calls))
        _ = try await session.start()
        await session.stop()
    }
}
