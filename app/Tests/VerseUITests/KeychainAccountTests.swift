import Foundation
import VerseVoice
import XCTest
@testable import VerseUI

/// The Keychain account is the macOS user running the process (`$USER`, else the login name); no user name is in the source.
final class KeychainAccountTests: XCTestCase {
    func testAccountIsTheCurrentUser() {
        let env = ProcessInfo.processInfo.environment["USER"] ?? ""
        let expected = env.isEmpty ? NSUserName() : env
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(KeychainStore.account, expected)
        XCTAssertEqual(VoiceKeys.account, expected)
    }
}
