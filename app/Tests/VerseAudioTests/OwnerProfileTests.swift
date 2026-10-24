import Foundation
import VerseAudio
import XCTest

/// The owner profile (`OwnerProfile`): no personal value is hard-coded; names, tags and paths come from owner.json.
final class OwnerProfileTests: XCTestCase {

    private func write(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owner-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("owner.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    private static let alex = """
    {"display_name": "Alex Rivera", "vault_path": "~/Notes/AcmeVault", "vault_script": "retrieve.py",
     "api_key_note": "From Alex's personal API org."}
    """

    func testProfileFileIsRead() throws {
        let p = OwnerProfile.load(from: try write(Self.alex))
        XCTAssertEqual(p.displayName, "Alex Rivera")
        XCTAssertTrue(p.named)
        XCTAssertEqual(p.addresseeName, "Alex Rivera")
        XCTAssertEqual(p.vaultPath, "~/Notes/AcmeVault")
        XCTAssertEqual(p.apiKeyNote, "From Alex's personal API org.")
        XCTAssertEqual(p.sourceTag, "alex-rivera")
        XCTAssertEqual(p.notesHeading, "ALEX RIVERA'S NOTES")
    }

    func testMissingOrBrokenFileGivesTheGenericProfile() throws {
        for content in [nil, "", "not json", "[1, 2]", "{\"display_name\": 5}", "{\"display_name\": \"  \"}"] {
            let p = OwnerProfile.load(from: try write(content))
            XCTAssertEqual(p, OwnerProfile(), "content: \(content ?? "nil")")
            XCTAssertEqual(p.displayName, "the user")
            XCTAssertFalse(p.named)
            XCTAssertEqual(p.addresseeName, "", "a generic label must never be matched against what the other side says")
            XCTAssertNil(p.vaultPath)
            XCTAssertNil(p.apiKeyNote)
            XCTAssertEqual(p.sourceTag, "owner")
            XCTAssertEqual(p.notesHeading, "MY NOTES")
        }
    }

    func testSourceTagIsALowercaseSlugOfTheName() {
        XCTAssertEqual(OwnerProfile(displayName: "Alex  Rivera-Smith", named: true).sourceTag, "alex-rivera-smith")
        XCTAssertEqual(OwnerProfile(displayName: "Zoë", named: true).sourceTag, "zo")
        XCTAssertEqual(OwnerProfile(displayName: "!!!", named: true).sourceTag, "owner")
    }

    func testFileLocationFollowsTheEnvironmentOverride() {
        // The test process may or may not have the override; either way the URL is the one `current` was read from.
        let url = OwnerProfile.fileURL
        if let env = ProcessInfo.processInfo.environment[OwnerProfile.environmentKey], !env.isEmpty {
            XCTAssertEqual(url.path, (env as NSString).expandingTildeInPath)
        } else {
            XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Verse/owner.json"), url.path)
        }
        XCTAssertEqual(OwnerProfile.current, OwnerProfile.load(from: url))
    }
}
