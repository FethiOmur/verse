import XCTest
@testable import VerseVoice

/// U3: a save is confirmed by the new key's last 4, not by "an item exists". A fake `security` runner stands in for the
/// real one, so these tests never touch the Keychain. The keys are dummies and never printed.
final class VoiceKeysSaveTests: XCTestCase {
    private let newKey = "sk_" + String(repeating: "n", count: 24) + "AbCd"      // last 4: AbCd
    private let oldLast4 = "wxyz"

    /// A runner whose `add-generic-password -U` does (or does not) update the stored comment.
    private func runner(stored: Locked<String?>, updateWorks: Bool) -> VoiceKeys.SecurityRunner {
        return { args, stdin in
            if args == ["-i"] {
                if updateWorks, let line = stdin, let r = line.range(of: "verse-last4:") {
                    stored.with { $0 = String(line[r.upperBound...].prefix(4)) }
                }
                return .init(status: 0, stdout: "", stderr: updateWorks ? "" : "security: SecKeychainItemModifyContent: User interaction is not allowed.")
            }
            if args.first == "find-generic-password" {
                guard let l = stored.with({ $0 }) else { return .init(status: 44, stdout: "", stderr: "not found") }
                return .init(status: 0, stdout: "    \"icmt\"<blob>=\"verse-last4:\(l)\"\n", stderr: "")
            }
            return .init(status: 1, stdout: "", stderr: "unexpected")
        }
    }

    func testSaveThrowsWhenTheUpdateFailedAndTheOldItemRemains() {
        let stored = Locked<String?>(oldLast4)
        XCTAssertThrowsError(try VoiceKeys.save(newKey, service: "verse-fake-TEST", account: "tester", runner: runner(stored: stored, updateWorks: false))) { error in
            guard case VoiceKeyError.failed(let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertFalse(message.contains(newKey), "the key must not appear in the error")
        }
    }

    func testSaveSucceedsWhenTheStoredLast4IsTheNewKeys() throws {
        let stored = Locked<String?>(oldLast4)
        try VoiceKeys.save(newKey, service: "verse-fake-TEST", account: "tester", runner: runner(stored: stored, updateWorks: true))
        XCTAssertEqual(stored.with { $0 }, "AbCd")
    }

    func testFirstSaveWithNoItemThrowsWhenNothingWasStored() {
        let stored = Locked<String?>(nil)
        XCTAssertThrowsError(try VoiceKeys.save(newKey, service: "verse-fake-TEST", account: "tester", runner: runner(stored: stored, updateWorks: false)))
    }
}
