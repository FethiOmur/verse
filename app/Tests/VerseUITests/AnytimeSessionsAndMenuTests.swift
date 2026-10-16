import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// The Sessions rows of unprepared calls, and the menu's route and language choices.
@MainActor
final class AnytimeSessionsAndMenuTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-16T14:32:10Z")! }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-adhoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Sessions rows

    func testAnAdhocSessionCarriesTheUnpreparedTagAndItsRoute() throws {
        let r = try root()
        let room = try SessionCatalog.createAdhoc(now: now, route: .room, lang: "en", root: r, timeZone: utc)
        let phone = try SessionCatalog.createAdhoc(now: now.addingTimeInterval(120), route: .phone, lang: "it", root: r, timeZone: utc)
        let meeting = try SessionCatalog.createAdhoc(now: now.addingTimeInterval(7200), route: .meeting, lang: "en", root: r, timeZone: utc)
        let model = HomeSessionsModel(root: r)
        let byName = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.name, $0) })
        XCTAssertEqual(byName[room]?.unprepared, true)
        XCTAssertEqual(byName[room]?.routeLabel, "Room")
        XCTAssertEqual(byName[phone]?.routeLabel, "Phone")
        XCTAssertEqual(byName[meeting]?.routeLabel, "Meeting")
        XCTAssertEqual(byName[room]?.kindText, "Room", "the row says the route where a prepared session says Meeting")
        XCTAssertEqual(byName[room]?.kind, .call)
        XCTAssertEqual(byName[room]?.title, "Call at 14:32")
        XCTAssertEqual(byName[meeting]?.title, "Call at 16:32")
    }

    func testTheRouteComesFromTheFolderNameWhenMetaIsMissing() throws {
        let r = try root()
        let dir = r.appendingPathComponent("adhoc-20261016-1432-room", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("pack.md"))
        let s = HomeSession.load(name: dir.lastPathComponent, root: r)
        XCTAssertTrue(s.unprepared)
        XCTAssertEqual(s.routeLabel, "Room")
        let second = HomeSession.load(name: "adhoc-20261016-1432-room-2", root: r)
        XCTAssertEqual(second.title, "Call at 14:32")
    }

    func testOrdinarySessionsAreNotTagged() throws {
        let r = try root()
        let dir = r.appendingPathComponent("mara-northwindlabs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("pack.md"))
        let s = HomeSession.load(name: "mara-northwindlabs", root: r)
        XCTAssertFalse(s.unprepared)
        XCTAssertNil(s.routeLabel)
        XCTAssertEqual(s.kindText, "Prepared")
    }

    // MARK: menu: route and language

    private func controller() -> VerseController {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        return VerseController(settings: settings, launch: LaunchOptions(arguments: []))
    }

    func testTheRouteChoiceBeforeAStartIsKeptUntilChangedBack() {
        let c = controller()
        XCTAssertNil(c.routeChoice)
        c.chooseRoute(.room)
        XCTAssertEqual(c.routeChoice, .room)
        c.chooseRoute(.phone)
        XCTAssertEqual(c.routeChoice, .room, "a phone route is heard through the room route until phase B")
        c.chooseRoute(.meeting)
        XCTAssertEqual(c.routeChoice, .meeting)
        c.chooseRoute(nil)
        XCTAssertNil(c.routeChoice, "back to automatic")
    }

    func testThePlanTakesTheRouteChosenByHandOverTheAutomaticOne() throws {
        let r = try root()
        let facts = QuickStart.RouteFacts(phoneCallActive: false, meetingAppHoldsMic: true)
        let auto = try QuickStart.plan(now: now, facts: facts, events: [], remembered: [:], sessions: [], lang: "en", root: r, timeZone: utc)
        XCTAssertEqual(auto.route, .meeting)
        let hand = try QuickStart.plan(now: now, facts: facts, events: [], remembered: [:], sessions: [], lang: "en", root: r,
                                       timeZone: utc, routeOverride: .room)
        XCTAssertEqual(hand.route, .room)
        XCTAssertTrue(hand.session.hasSuffix("-room"))
    }

    func testStartNowUsesTheChosenRouteOnceAndListsNoAdhocFolderAsASession() throws {
        let c = controller()
        let r = try root()
        c.sessionsRoot = r
        c.clock = { self.now }
        c.eventsAround = { _ in [] }
        c.routeFacts = { QuickStart.RouteFacts(phoneCallActive: false, meetingAppHoldsMic: true) }
        c.chooseRoute(.room)
        // The practice interview owns the microphone: nothing starts, so the choice is kept.
        c.startBlocked = { true }
        c.startNow()
        XCTAssertEqual(c.routeChoice, .room, "a blocked Start does not use the choice up")
        XCTAssertFalse(c.running)
    }

    func testUnpreparedFoldersAreNotSessionsToPick() throws {
        let r = try root()
        for name in ["adhoc-20261016-1432-room", "mara-northwindlabs"] {
            let d = r.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data().write(to: d.appendingPathComponent("pack.md"))
        }
        let c = controller()
        c.sessionsRoot = r
        c.refreshSessions()
        XCTAssertEqual(c.sessions, ["mara-northwindlabs"], "Start would run an adhoc folder as a prepared session")
        XCTAssertEqual(c.settings.sessionName, "mara-northwindlabs")
    }

    func testTheLanguageChoiceBeforeAStartIsTheDefaultCallLanguage() {
        let c = controller()
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto")
        c.chooseLanguage("tr")
        XCTAssertEqual(c.settings.defaultCallLanguage, "tr")
        c.chooseLanguage("fr")
        XCTAssertEqual(c.settings.defaultCallLanguage, "tr", "only auto, en, it and tr")
        c.chooseLanguage("it")
        XCTAssertEqual(c.settings.defaultCallLanguage, "it")
    }

    func testSwitchingDoesNothingWithoutARunningCall() async {
        let c = controller()
        await c.switchListening(route: .room, lang: "it")
        XCTAssertFalse(c.running)
        XCTAssertEqual(c.callLanguage, "en")
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto", "a switch never rewrites the default")
    }
}
