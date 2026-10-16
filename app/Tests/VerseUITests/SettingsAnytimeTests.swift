import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Settings of the anytime-calls spec (2.2 toggle, default call language, room auto cards) and how they reach the runner.
@MainActor
final class SettingsAnytimeTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")! }

    func testDefaults() {
        let s = AppSettings(defaults: defaults())
        XCTAssertTrue(s.useMeProfile, "Use my profile in every session: on")
        XCTAssertEqual(s.defaultCallLanguage, "en")
        XCTAssertTrue(s.roomAutoCards)
        XCTAssertEqual(s.roomAuto, .questions)
    }

    func testTheyPersistAcrossInstances() {
        let d = defaults()
        let first = AppSettings(defaults: d)
        first.useMeProfile = false
        first.defaultCallLanguage = "tr"
        first.roomAutoCards = false
        let second = AppSettings(defaults: d)
        XCTAssertFalse(second.useMeProfile)
        XCTAssertEqual(second.defaultCallLanguage, "tr")
        XCTAssertFalse(second.roomAutoCards)
        XCTAssertEqual(second.roomAuto, .off)
        first.useMeProfile = true
        first.defaultCallLanguage = "it"
        first.roomAutoCards = true
        let third = AppSettings(defaults: d)
        XCTAssertTrue(third.useMeProfile)
        XCTAssertEqual(third.defaultCallLanguage, "it")
        XCTAssertEqual(third.roomAuto, .questions)
    }

    func testAnUnknownStoredLanguageFallsBackToEnglish() {
        let d = defaults()
        d.set("fr", forKey: "defaultCallLanguage")
        XCTAssertEqual(AppSettings(defaults: d).defaultCallLanguage, "en")
    }

    func testOtherSettingsAreUntouched() {
        let s = AppSettings(defaults: defaults())
        XCTAssertEqual(s.language, "en")
        XCTAssertEqual(s.ownerName, "Alex")
        XCTAssertEqual(s.matchThreshold, 0.55)
    }

    // MARK: run options

    private func profileDir(withMe: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withMe { try "# me\n".write(to: url.appendingPathComponent("me.md"), atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRunOptionsCarryModeRouteLanguageAndTheMeLayer() throws {
        let s = AppSettings(defaults: defaults())
        let profile = try profileDir(withMe: true)
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        let o = VerseController.runOptions(sessionDir: dir, settings: s, fakeBrain: true, testFile: nil, follow: true,
                                           mode: .unprepared, route: .room, lang: "it", meProfile: profile)
        XCTAssertEqual(o.mode, .unprepared)
        XCTAssertEqual(o.route, .room)
        XCTAssertEqual(o.lang, "it")
        XCTAssertTrue(o.follow, "the room route follows too: the brain tells his words by text")
        XCTAssertEqual(o.roomAuto, .questions)
        XCTAssertEqual(o.me?.core, profile.appendingPathComponent("me.md").path)
        XCTAssertEqual(o.me?.library, profile.appendingPathComponent("me.library.jsonl").path)
        XCTAssertEqual(o.me?.facts, profile.appendingPathComponent("me.facts.jsonl").path)
    }

    func testTheToggleAndAMissingProfileSendNoMeLayer() throws {
        let s = AppSettings(defaults: defaults())
        let dir = URL(fileURLWithPath: "/tmp/verse-session")
        let withMe = try profileDir(withMe: true)
        s.useMeProfile = false
        XCTAssertNil(VerseController.runOptions(sessionDir: dir, settings: s, fakeBrain: true, testFile: nil, meProfile: withMe).me,
                     "off: start.me is null")
        s.useMeProfile = true
        XCTAssertNil(VerseController.runOptions(sessionDir: dir, settings: s, fakeBrain: true, testFile: nil,
                                                meProfile: try profileDir(withMe: false)).me, "not built yet: nothing to send")
    }

    func testAPreparedMeetingRunIsWhatItWas() throws {
        let s = AppSettings(defaults: defaults())
        let o = VerseController.runOptions(sessionDir: URL(fileURLWithPath: "/tmp/s"), settings: s, fakeBrain: true, testFile: nil,
                                           follow: true, meProfile: try profileDir(withMe: false))
        XCTAssertEqual(o.mode, .prepared)
        XCTAssertEqual(o.route, .meeting)
        XCTAssertTrue(o.follow)
        XCTAssertEqual(o.lang, "en")
        XCTAssertNil(o.me)
        s.roomAutoCards = false
        XCTAssertEqual(VerseController.runOptions(sessionDir: URL(fileURLWithPath: "/tmp/s"), settings: s, fakeBrain: true,
                                                  testFile: nil, route: .room).roomAuto, .off)
    }
}
