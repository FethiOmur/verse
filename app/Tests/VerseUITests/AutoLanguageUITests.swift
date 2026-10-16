import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Interim AUTO language (spec 2.1, 2.5): the setting value, the island and menu chips, and how the labels follow a switch.
@MainActor
final class AutoLanguageUITests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")! }

    // MARK: settings

    func testAutoIsTheDefaultCallLanguage() {
        let s = AppSettings(defaults: defaults())
        XCTAssertEqual(s.defaultCallLanguage, "auto")
        XCTAssertEqual(AppSettings.callLanguages, ["auto", "en", "it", "tr"], "AUTO first in the Settings popup")
        XCTAssertEqual(AppSettings.pinnableLanguages, ["en", "it", "tr"])
        XCTAssertEqual(StartRoutes.languageName("auto"), "Auto")
    }

    func testTheChoicePersistsAndAnUnknownValueFallsBackToAuto() {
        let d = defaults()
        let first = AppSettings(defaults: d)
        first.defaultCallLanguage = "it"
        XCTAssertEqual(AppSettings(defaults: d).defaultCallLanguage, "it", "a pinned language is kept")
        first.defaultCallLanguage = "auto"
        XCTAssertEqual(AppSettings(defaults: d).defaultCallLanguage, "auto")
        d.set("fr", forKey: "defaultCallLanguage")
        XCTAssertEqual(AppSettings(defaults: d).defaultCallLanguage, "auto")
    }

    func testAnEarlierInstallThatNeverChoseGetsAuto() {
        // Nothing was ever written (the old default "en" was not stored either).
        XCTAssertNil(defaults().string(forKey: "defaultCallLanguage"))
        XCTAssertEqual(AppSettings(defaults: defaults()).defaultCallLanguage, "auto")
    }

    func testTheChipsAndTheMenuSetTheDefaultBeforeACall() {
        let c = VerseController(settings: AppSettings(defaults: defaults()), launch: LaunchOptions(arguments: []))
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto")
        c.chooseLanguage("it")
        XCTAssertEqual(c.settings.defaultCallLanguage, "it", "a click on IT pins it for the next call")
        c.chooseLanguage("auto")
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto", "a click on AUTO turns it back on")
        c.chooseLanguage("fr")
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto", "only auto, en, it and tr")
        XCTAssertFalse(c.autoLanguage, "no call is running")
    }

    func testAnAutoStartPlanIsWrittenToTheSessionFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verse-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let now = ISO8601DateFormatter().date(from: "2026-10-16T14:32:10Z")!
        let name = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "auto", root: root, timeZone: TimeZone(identifier: "UTC")!)
        let meta = try String(contentsOf: root.appendingPathComponent(name).appendingPathComponent("meta.json"), encoding: .utf8)
        XCTAssertTrue(meta.contains("\"auto\""), meta)
    }

    // MARK: chips

    func testTheAutoChipShowsTheDetectedLanguage() {
        XCTAssertEqual(StartCardChips.autoLabel(auto: true, lang: "en"), "AUTO · EN")
        XCTAssertEqual(StartCardChips.autoLabel(auto: true, lang: "it"), "AUTO · IT")
        XCTAssertEqual(StartCardChips.autoLabel(auto: true, lang: "tr"), "AUTO · TR")
        XCTAssertEqual(StartCardChips.autoLabel(auto: false, lang: "it"), "AUTO", "pinned: the plain AUTO chip, unselected")
    }

    private func started(auto: Bool) -> OverlayModel {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        m.sessionStarting(lang: "en", session: "adhoc-20261016-1432-room", app: nil, route: .room, unprepared: true, auto: auto)
        return m
    }

    func testTheStartCardStartsInAutoOrPinned() {
        XCTAssertEqual(started(auto: true).state.startup?.autoLang, true)
        XCTAssertEqual(started(auto: false).state.startup?.autoLang, false)
        XCTAssertEqual(started(auto: true).state.startup?.lang, "en")
    }

    func testAnAutoSwitchMovesTheLabelAndKeepsAutoOn() {
        let m = started(auto: true)
        m.listeningChanged(route: .room, lang: "it", app: nil, auto: true)
        XCTAssertEqual(m.state.startup?.lang, "it")
        XCTAssertEqual(m.state.startup?.autoLang, true, "AUTO · IT")
        XCTAssertEqual(m.state.lang, "it")
    }

    func testAClickOnALanguagePinsAndAClickOnAutoTurnsItBackOn() {
        let m = started(auto: true)
        m.listeningChanged(route: .room, lang: "en", app: nil, auto: false)
        XCTAssertEqual(m.state.startup?.autoLang, false)
        XCTAssertEqual(m.state.startup?.lang, "en")
        m.listeningChanged(route: .room, lang: "en", app: nil, auto: true)
        XCTAssertEqual(m.state.startup?.autoLang, true)
    }

    func testARouteSwitchLeavesTheAutoStateAlone() {
        let m = started(auto: true)
        m.listeningChanged(route: .meeting, lang: "en", app: "Comet")
        XCTAssertEqual(m.state.startup?.autoLang, true)
        let pinned = started(auto: false)
        pinned.listeningChanged(route: .meeting, lang: "en", app: "Comet")
        XCTAssertEqual(pinned.state.startup?.autoLang, false)
    }

    func testTheAutoChipReachesTheController() {
        let m = OverlayModel(config: OverlayConfig(), clock: { 1000 })
        var seen: [StartChipAction] = []
        m.startChipActions = { seen.append($0) }
        m.startChipAction(.setLanguage("auto"))
        m.startChipAction(.setLanguage("it"))
        XCTAssertEqual(seen, [.setLanguage("auto"), .setLanguage("it")])
    }
}
