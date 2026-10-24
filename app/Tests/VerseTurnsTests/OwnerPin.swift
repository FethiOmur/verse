import Foundation
import XCTest

/// Pins the owner profile of the test process to the generic one ("the user", no vault, no key note), whatever
/// `~/Library/Application Support/Verse/owner.json` or `VERSE_OWNER_FILE` holds on this machine. `OwnerProfile.current` is
/// read once, on first use, so the override has to be in place before any test runs: XCTest builds the suite of every test
/// class (`defaultTestSuite`) before it runs the first test, and this class's override sets the environment at that point.
final class OwnerPin: XCTestCase {
    private static let pinned: Void = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-tests-owner-\(ProcessInfo.processInfo.processIdentifier).json")
        try? Data("{}".utf8).write(to: url)
        setenv("VERSE_OWNER_FILE", url.path, 1)
    }()

    override class var defaultTestSuite: XCTestSuite {
        _ = pinned
        return super.defaultTestSuite
    }

    func testOwnerProfileIsPinnedToTheGenericOne() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["VERSE_OWNER_FILE"]?.hasSuffix(".json"), true)
    }
}
