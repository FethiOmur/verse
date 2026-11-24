import Foundation
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// The menu-bar menu (owner decisions 1-8, 24 Nov 2026): the Start row is a pure preview of what ⌥⌘V does, Start unprepared leaves
/// the selection alone, the Session submenu is capped, and every start path runs in Settings' call language (Auto by default).
/// Fictional sessions in a temp folder, an injected clock and calendar, launches recorded instead of run.
@MainActor
final class MenuBarStartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verse-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ id: String, inMinutes m: Double, title: String = "Design review") -> MeetingEvent {
        MeetingEvent(id: id, title: title, start: now.addingTimeInterval(m * 60), end: now.addingTimeInterval((m + 30) * 60))
    }

    /// A controller over a temp sessions folder with `sessions`, its event links in a temp file, `events` as the calendar, and its
    /// launches recorded.
    private func controller(sessions: [String], meta: [String: String] = [:], events: [MeetingEvent] = [],
                            links: [String: String] = [:]) throws -> (VerseController, () -> [LaunchRequest]) {
        let root = try tempDir()
        for (i, name) in sessions.enumerated() {
            let d = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data().write(to: d.appendingPathComponent("pack.md"))
            let created = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(i - sessions.count) * 3600))
            try Data((meta[name] ?? #"{"created_at":"\#(created)"}"#).utf8).write(to: d.appendingPathComponent("meta.json"))
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let c = VerseController(settings: settings, launch: LaunchOptions(arguments: []))
        c.sessionsRoot = root
        c.clock = { self.now }
        c.calendar = Calendar(identifier: .gregorian)
        c.eventSessions = EventSessionMap(url: root.appendingPathComponent("event-sessions.json"))
        for (k, v) in links { c.eventSessions.remember(eventID: k, session: v) }
        c.eventsAround = { _ in events }
        c.routeFacts = { QuickStart.RouteFacts(phoneCallActive: false, meetingAppHoldsMic: true) }
        c.refreshSessions()
        var launches: [LaunchRequest] = []
        c.launchOverride = { launches.append($0) }
        return (c, { launches })
    }

    // MARK: Start row = the real plan

    /// For the same inputs the Start row's preview and the start that follows are one decision: a session within 60 minutes,
    /// a manual pick, nothing (and the boundary: a meeting 90 minutes away is not used).
    func testTheStartRowPreviewsExactlyWhatStartDoes() throws {
        struct Case { var name: String; var events: [Int]; var manual: String?; var expected: QuickStart.SessionChoice }
        let cases = [
            Case(name: "the next meeting's session within 60 min", events: [45], manual: nil, expected: .prepared("mara-design")),
            Case(name: "a manual pick while the meeting is 90 min away", events: [90], manual: "other-call", expected: .prepared("other-call")),
            Case(name: "the meeting is 90 min away and nothing is picked", events: [90], manual: nil, expected: .adhoc),
            Case(name: "no meeting, no pick", events: [], manual: nil, expected: .adhoc),
        ]
        for k in cases {
            let evs = k.events.map { event("e\($0)", inMinutes: Double($0)) }
            let (c, launches) = try controller(sessions: ["mara-design", "other-call"], events: evs,
                                               links: Dictionary(uniqueKeysWithValues: evs.map { ($0.occurrenceKey, "mara-design") }))
            if let m = k.manual { c.selector.choose(m) }
            let selectedBefore = c.settings.sessionName
            let preview = c.startPreview()
            XCTAssertEqual(preview.choice, k.expected, k.name)
            c.startNow()
            let l = try XCTUnwrap(launches().last, k.name)
            switch preview.choice {
            case .prepared(let s):
                XCTAssertEqual(l.mode, .prepared, k.name)
                XCTAssertEqual(l.name, s, k.name)
                XCTAssertEqual(preview.title, "Start · \(s)", k.name)
                XCTAssertTrue(preview.showsUnpreparedRow, k.name)
            case .adhoc:
                XCTAssertEqual(l.mode, .unprepared, k.name)
                XCTAssertTrue(SessionCatalog.isAdhoc(l.name), k.name)
                XCTAssertEqual(preview.title, "Start · unprepared", k.name)
                XCTAssertFalse(preview.showsUnpreparedRow, "the second row would do the same: \(k.name)")
                XCTAssertEqual(c.settings.sessionName, selectedBefore, "an unprepared start changes no selection: \(k.name)")
            }
        }
    }

    // MARK: Start unprepared

    func testStartUnpreparedLeavesTheSelectionAndTheManualPickAlone() throws {
        let (c, launches) = try controller(sessions: ["mara-design", "other-call"], events: [event("e1", inMinutes: 20)],
                                           links: [event("e1", inMinutes: 20).occurrenceKey: "mara-design"])
        c.selector.choose("other-call")
        let manual = c.settings.sessionPickManual
        XCTAssertEqual(c.startPreview().choice, .prepared("mara-design"), "the meeting in 20 minutes wins over the pick")
        c.startUnprepared()
        let l = try XCTUnwrap(launches().last)
        XCTAssertEqual(l.mode, .unprepared)
        XCTAssertTrue(SessionCatalog.isAdhoc(l.name))
        XCTAssertEqual(c.settings.sessionName, "other-call", "the selection is untouched")
        XCTAssertEqual(c.settings.sessionPickManual, manual, "the manual pick is untouched")
        XCTAssertFalse(c.sessions.contains(l.name), "the unprepared folder is no session to pick")
        // The hot key does the same, and nothing while a call runs.
        c.startUnpreparedKeyPressed()
        XCTAssertEqual(launches().count, 2)
        XCTAssertEqual(launches().last?.mode, .unprepared)
    }

    func testTheUnpreparedKeyIsOptionShiftCommandVAndStaysOnLikeStartStop() {
        XCTAssertEqual(HotKeySpec.startUnprepared.keyCode, HotKeySpec.startStop.keyCode, "V")
        XCTAssertEqual(HotKeySpec.startUnprepared.modifiers, UInt32(0x0800 | 0x0200 | 0x0100), "option + shift + command")
        let reg = QuickStartTests.FakeRegistrar()
        var presses: [String] = []
        let keys = GlobalHotKeys(registrar: reg, onStartStop: { presses.append("start") }, onCardNow: {},
                                 onStartUnprepared: { presses.append("unprepared") }, lessThanKeyCodes: { [50] })
        XCTAssertTrue(keys.registerStartStop())
        XCTAssertTrue(keys.registerStartUnprepared())
        XCTAssertTrue(keys.registerStartUnprepared(), "registering twice keeps the one key")
        XCTAssertEqual(Set(reg.live.values.map(\.id)), [GlobalHotKeys.startStopID, GlobalHotKeys.startUnpreparedID])
        keys.setSessionRunning(true)
        keys.setSessionRunning(false)
        XCTAssertTrue(keys.startUnpreparedRegistered, "a session's end does not take it away")
        reg.press(GlobalHotKeys.startUnpreparedID)
        XCTAssertEqual(presses, ["unprepared"])
        keys.unregisterAll()
        XCTAssertFalse(keys.startUnpreparedRegistered)
        XCTAssertTrue(reg.live.isEmpty)

        let taken = QuickStartTests.FakeRegistrar()
        taken.refuse = [GlobalHotKeys.startUnpreparedID]
        let k2 = GlobalHotKeys(registrar: taken, onStartStop: {}, onCardNow: {}, lessThanKeyCodes: { [50] })
        XCTAssertFalse(k2.registerStartUnprepared())
        XCTAssertTrue(k2.registerStartStop(), "the other key is independent")
    }

    // MARK: Session submenu cap

    func testTheSessionSubmenuShowsTheNewestEightAndAlwaysTheSelectedOne() {
        func row(_ s: String) -> SessionPickerModel.Row { .init(session: s, label: s, mark: nil, event: nil) }
        let others = (1...10).map { row("s\($0)") }        // newest first, as the picker orders them
        let full = SessionPickerModel(nextMeetings: [row("n1")], others: others, notPrepared: nil)
        let table: [(String, String, [String])] = [
            ("the newest eight, next meeting first", "s2", ["n1", "s1", "s2", "s3", "s4", "s5", "s6", "s7"]),
            ("a selection past the cap takes the last place", "s10", ["n1", "s1", "s2", "s3", "s4", "s5", "s6", "s10"]),
            ("an unknown selection changes nothing", "gone", ["n1", "s1", "s2", "s3", "s4", "s5", "s6", "s7"]),
        ]
        for (name, selected, expected) in table {
            let capped = full.capped(selected: selected)
            XCTAssertEqual(capped.rows.map(\.session), expected, name)
            XCTAssertEqual(capped.nextMeetings.map(\.session), ["n1"], name)
        }
        XCTAssertEqual(SessionPickerModel.menuLimit, 8)
        let small = SessionPickerModel(nextMeetings: [], others: Array(others.prefix(5)), notPrepared: nil)
        XCTAssertEqual(small.capped(selected: "s1"), small, "five sessions: all of them")
    }

    // MARK: next meeting rows

    func testTheNextMeetingRowsSayWhetherItsSessionIsReady() {
        let cal = Calendar(identifier: .gregorian)
        let e = event("e1", inMinutes: 120, title: "Budget sync")
        let empty = SessionPickerModel(nextMeetings: [], others: [], notPrepared: nil)
        XCTAssertNil(NextMeetingRows.make(target: nil, picker: empty, now: now, calendar: cal), "no meeting: no info rows")
        let ready = NextMeetingRows.make(target: e, picker: empty, now: now, calendar: cal)
        XCTAssertEqual(ready?.state, .ready)
        XCTAssertEqual(ready?.offersPrepare, false)
        XCTAssertTrue(ready?.meeting.hasSuffix("· Budget sync") == true, ready?.meeting ?? "")
        XCTAssertTrue(ready?.meeting.hasPrefix("Next meeting: ") == true)
        func picker(preparing: Bool) -> SessionPickerModel {
            SessionPickerModel(nextMeetings: [], others: [], notPrepared: .init(event: e, preparing: preparing, label: ""))
        }
        XCTAssertEqual(NextMeetingRows.make(target: e, picker: picker(preparing: true), now: now, calendar: cal)?.state, .preparing)
        XCTAssertEqual(NextMeetingRows.make(target: e, picker: picker(preparing: true), now: now, calendar: cal)?.offersPrepare, false)
        let none = NextMeetingRows.make(target: e, picker: picker(preparing: false), now: now, calendar: cal)
        XCTAssertEqual(none?.state, .notPrepared)
        XCTAssertEqual(none?.offersPrepare, true)
        XCTAssertEqual(none?.stateText, "Session: not prepared")
    }

    // MARK: language

    func testCallLanguageAtStart() {
        let table: [(String, String?, CallLanguage.Start)] = [
            ("auto", nil, .init(engine: "en", auto: true, hint: nil)),
            ("auto", "it", .init(engine: "it", auto: true, hint: "it")),
            ("auto", "tr", .init(engine: "tr", auto: true, hint: "tr")),
            ("auto", "fr", .init(engine: "en", auto: true, hint: nil)),
            ("it", "en", .init(engine: "it", auto: false, hint: nil)),
            ("xx", nil, .init(engine: "en", auto: false, hint: nil)),
        ]
        for (requested, prepared, expected) in table {
            XCTAssertEqual(CallLanguage.start(requested: requested, prepared: prepared), expected, "\(requested) / \(prepared ?? "-")")
        }
    }

    func testThePreparedLanguageComesFromMetaJSON() throws {
        let root = try tempDir()
        let table: [(String?, String?)] = [
            (#"{"languages":["it","en"]}"#, "it"),
            (#"{"languages":["EN"]}"#, "en"),
            (#"{"kind":"adhoc","lang":"auto"}"#, nil),
            (#"{"kind":"adhoc","lang":"tr"}"#, "tr"),
            (#"{"languages":["de"]}"#, nil),
            ("not json", nil),
            (nil, nil),
        ]
        for (i, (meta, expected)) in table.enumerated() {
            let d = root.appendingPathComponent("s\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let meta { try Data(meta.utf8).write(to: d.appendingPathComponent("meta.json")) }
            XCTAssertEqual(CallLanguage.prepared(sessionDir: d), expected, meta ?? "no meta.json")
        }
    }

    /// Owner decision 7: Start, Start unprepared, the meeting prompt's start and autostart (`start()`) all run in Settings' call
    /// language, Auto by default, never the Meeting language.
    func testEveryStartPathRunsInTheCallLanguage() throws {
        let (c, launches) = try controller(sessions: ["mara-design"])
        c.settings.language = "it"                  // the Meeting language (prep, dictation) is not the call's
        XCTAssertEqual(c.settings.defaultCallLanguage, "auto")
        c.start()
        c.startNow()
        c.startUnprepared()
        XCTAssertEqual(launches().map(\.lang), ["auto", "auto", "auto"])
        c.settings.defaultCallLanguage = "tr"       // the override in Settings
        c.start()
        c.startUnprepared()
        XCTAssertEqual(launches().suffix(2).map(\.lang), ["tr", "tr"])
    }

    // MARK: exposed for a later regenerate

    func testTheDominantLanguageAndTheAnswerLanguageReachTheOverlay() {
        var r = OverlayReducer()
        r.sessionStarting(lang: "en")
        func brain(_ json: String) { r.apply(.brain(JSONValue.decodeObject(json)!), now: 1) }
        XCTAssertNil(r.state.dominantLang)
        brain(#"{"type":"metric","turn_id":"","stage":"lang_dominant","lang":"en","prev":null,"reason":"start","t":1}"#)
        XCTAssertEqual(r.state.dominantLang, "en")
        r.apply(.outbound(JSONValue.decodeObject(#"{"type":"turn","turn_id":"r1","speaker":"remote","text":"Mi parli del progetto di cui va orgoglioso.","addressee":"me","kind":"question","t_audio_end":1,"dir":"to_brain"}"#)!), now: 1)
        brain(#"{"type":"metric","turn_id":"r1","stage":"answer_lang","lang":"it","dominant":"en","t":1}"#)
        brain(#"{"type":"delta","id":"f1","turn_id":"r1","tier":"F","text":"SAY: Certo, il progetto di cui vado più fiero.","line_done":true}"#)
        XCTAssertEqual(r.state.card?.answerLang, "it", "the language of the answer on screen")
        brain(#"{"type":"metric","turn_id":"","stage":"lang_dominant","lang":"it","prev":"en","reason":"sustained","t":2}"#)
        XCTAssertEqual(r.state.dominantLang, "it")
        brain(#"{"type":"metric","turn_id":"","stage":"lang_dominant","lang":"fr","t":3}"#)
        XCTAssertEqual(r.state.dominantLang, "it", "an unknown language is ignored")
        brain(#"{"type":"metric","turn_id":"","stage":"lang_auto","on":false,"lang":"it","t":4}"#)
        XCTAssertNil(r.state.dominantLang, "AUTO off: there is no dominant language")
    }
}
