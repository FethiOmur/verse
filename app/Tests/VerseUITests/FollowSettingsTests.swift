import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Settings → Meetings → "Follow my answer", and how it reaches the brain's `start`.
@MainActor
final class FollowSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")! }

    func testDefaultsOnAndSurvivesANewInstance() {
        let d = defaults()
        let first = MeetingSettings(defaults: d)
        XCTAssertTrue(first.followMyAnswer, "default on")
        first.followMyAnswer = false
        XCTAssertFalse(MeetingSettings(defaults: d).followMyAnswer, "off is remembered")
        first.followMyAnswer = true
        XCTAssertTrue(MeetingSettings(defaults: d).followMyAnswer)
        // Older installs have no such key: on.
        XCTAssertTrue(MeetingSettings(defaults: defaults()).followMyAnswer)
        // Its other settings are untouched.
        XCTAssertTrue(MeetingSettings(defaults: defaults()).detectMeetings)
        XCTAssertFalse(MeetingSettings(defaults: defaults()).offerSummaryToVault)
    }

    func testTheStartFlagFollowsTheSetting() {
        let settings = AppSettings(defaults: defaults())
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        XCTAssertFalse(VerseController.runOptions(sessionDir: dir, settings: settings, fakeBrain: true, testFile: nil).follow,
                       "without the argument a run is exactly what it was")
        let on = VerseController.runOptions(sessionDir: dir, settings: settings, fakeBrain: true, testFile: nil, follow: true)
        XCTAssertTrue(on.follow)
        XCTAssertTrue(BrainCommand.start(sessionDir: dir.path, lang: on.lang, follow: on.follow).jsonLine().contains("\"follow\":true"))
        let off = VerseController.runOptions(sessionDir: dir, settings: settings, fakeBrain: true, testFile: nil, follow: false)
        XCTAssertTrue(BrainCommand.start(sessionDir: dir.path, lang: off.lang, follow: off.follow).jsonLine().contains("\"follow\":false"))
    }
}
