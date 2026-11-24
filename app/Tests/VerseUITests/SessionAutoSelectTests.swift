import AppKit
import Foundation
import VerseMeet
@testable import VerseUI
import XCTest

/// Calendar-aware session selection: the shared matcher, occurrence keys, the shared ranking, the auto-select rule, the manual
/// override, the fallback when the selection disappears and Start now's three branches. Invented names only; time is injected.
@MainActor
final class SessionAutoSelectTests: XCTestCase {
    /// 2026-11-24 10:00:00 UTC.
    private let ten = Date(timeIntervalSince1970: 1_795_514_400)
    private func at(_ minutes: Double) -> Date { ten.addingTimeInterval(minutes * 60) }

    private let guest = Attendee(name: "Dana Quill", email: "dana@example.com")

    /// A real meeting (someone else is on the invite), `minutes` long from `start` minutes after 10:00.
    private func meeting(_ id: String, _ title: String = "Weekly sync", start: Double, minutes: Double = 30,
                         attendees: [Attendee]? = nil) -> MeetingEvent {
        MeetingEvent(id: id, title: title, start: at(start), end: at(start + minutes), attendees: attendees ?? [guest])
    }

    // MARK: occurrence keys (G10)

    func testOccurrenceKeyIsIdAtStartSecondsAndTheIdComesBackOut() {
        let e = meeting("series-1", start: 0)
        XCTAssertEqual(e.occurrenceKey, "series-1@1795514400")
        XCTAssertNotEqual(meeting("series-1", start: 7 * 24 * 60).occurrenceKey, e.occurrenceKey, "next week's occurrence")
        let table: [(String, String)] = [
            ("series-1@1795514400", "series-1"),
            ("series-1", "series-1"),                       // a legacy bare id
            ("A1B2:C3D4@1795514400", "A1B2:C3D4"),
            ("odd@name", "odd@name"),                       // not a time after the @
            ("trailing@", "trailing@"),
        ]
        for (key, id) in table { XCTAssertEqual(MeetingEvent.eventID(fromLinkKey: key), id, key) }
    }

    // MARK: the matcher (G3)

    func testMatchOrderOccurrenceThenSeriesThenSidecarThenName() {
        let e = meeting("ev", "Quarterly review with Ironwood", start: 60)
        let sessions = ["by-occurrence", "by-series", "by-sidecar", "ironwood-quarterly"]
        let sidecar = ["by-sidecar": EventSidecar(event: e)]
        func m(_ links: [String: String], _ sidecars: [String: EventSidecar] = [:]) -> SessionMatch? {
            MeetingSessionResolver.match(e, sessions: sessions, links: links, sidecars: sidecars)
        }
        XCTAssertEqual(m([e.occurrenceKey: "by-occurrence", "ev": "by-series"], sidecar), SessionMatch(session: "by-occurrence", source: .occurrenceLink))
        XCTAssertEqual(m(["ev": "by-series"], sidecar), SessionMatch(session: "by-series", source: .seriesLink))
        XCTAssertEqual(m([:], sidecar), SessionMatch(session: "by-sidecar", source: .sidecar))
        XCTAssertEqual(m([:]), SessionMatch(session: "ironwood-quarterly", source: .name))
        // A link to a folder that is gone falls through to the next rule.
        XCTAssertEqual(m([e.occurrenceKey: "gone"], sidecar)?.source, .sidecar)
    }

    func testALegacyBareIdLinkStillMatchesEveryOccurrence() {
        let monday = meeting("weekly", start: 0), nextMonday = meeting("weekly", start: 7 * 24 * 60)
        let links = ["weekly": "weekly-sync-prep"]
        for e in [monday, nextMonday] {
            XCTAssertEqual(MeetingSessionResolver.match(e, sessions: ["weekly-sync-prep"], links: links)?.source, .seriesLink)
        }
    }

    func testTwoOccurrencesLinkedToDifferentSessionsResolveSeparately() {
        let first = meeting("interviews", "Interview", start: 0), second = meeting("interviews", "Interview", start: 24 * 60)
        let third = meeting("interviews", "Interview", start: 48 * 60)
        let links = [first.occurrenceKey: "candidate-one", second.occurrenceKey: "candidate-two"]
        let sessions = ["candidate-one", "candidate-two"]
        XCTAssertEqual(MeetingSessionResolver.match(first, sessions: sessions, links: links)?.session, "candidate-one")
        XCTAssertEqual(MeetingSessionResolver.match(second, sessions: sessions, links: links)?.session, "candidate-two")
        XCTAssertNil(MeetingSessionResolver.match(third, sessions: sessions, links: links), "two sessions in the series: no guess")
    }

    func testAMovedOneOffEventKeepsItsOnlyOccurrenceLink() {
        var planned = meeting("one-off", "Budget", start: 0)
        planned.isRecurring = false
        var moved = meeting("one-off", "Budget", start: 90)
        moved.isRecurring = false
        let links = [planned.occurrenceKey: "budget-prep"]
        XCTAssertEqual(MeetingSessionResolver.match(moved, sessions: ["budget-prep"], links: links),
                       SessionMatch(session: "budget-prep", source: .seriesLink))
    }

    /// G10 and owner decision 3: last week's prep (an occurrence link plus its `event.json`) is not this week's session, so the
    /// next occurrence stays unmatched and gets its own background prep.
    func testAPrepForOneOccurrenceOfARepeatingMeetingDoesNotMatchTheNextOne() {
        for recurring in [true, nil] as [Bool?] {
            var monday = meeting("weekly", "Weekly sync", start: 0)
            monday.isRecurring = recurring
            var nextMonday = meeting("weekly", "Weekly sync", start: 7 * 24 * 60)
            nextMonday.isRecurring = recurring
            let links = [monday.occurrenceKey: "mon-prep"]
            let sidecars = ["mon-prep": EventSidecar(event: monday)]
            let why = "isRecurring \(String(describing: recurring))"
            XCTAssertNil(MeetingSessionResolver.match(nextMonday, sessions: ["mon-prep"], links: links), "link: " + why)
            XCTAssertNil(MeetingSessionResolver.match(nextMonday, sessions: ["mon-prep"], links: [:], sidecars: sidecars), "sidecar: " + why)
            XCTAssertNil(MeetingSessionResolver.match(nextMonday, sessions: ["mon-prep"], links: links, sidecars: sidecars), "both: " + why)
            XCTAssertEqual(MeetingSessionResolver.match(monday, sessions: ["mon-prep"], links: links, sidecars: sidecars)?.session,
                           "mon-prep", "its own occurrence: " + why)
            let matched = SessionMatcher(sessions: ["mon-prep"], links: links, sidecars: sidecars).match(nextMonday)
                .map { _ in Set([nextMonday.occurrenceKey]) } ?? []
            let gate = AutoPrepGate.candidate(now: at(7 * 24 * 60 - 60), enabled: true, busy: false, upcoming: [nextMonday],
                                              matched: matched, attempted: [monday.occurrenceKey], inFlight: [])
            XCTAssertEqual(gate?.occurrenceKey, nextMonday.occurrenceKey, "the next occurrence is prepared: " + why)
        }
    }

    func testSidecarByOccurrenceThenByIdAndOnlyWhenUnique() {
        var e = meeting("ev", "Kickoff", start: 0)
        e.isRecurring = false
        var other = meeting("ev", "Kickoff", start: 90)
        other.isRecurring = false
        let s1 = EventSidecar(event: e), s2 = EventSidecar(event: other)
        func m(_ sidecars: [String: EventSidecar], sessions: [String]) -> String? {
            MeetingSessionResolver.match(e, sessions: sessions, links: [:], sidecars: sidecars)?.session
        }
        XCTAssertEqual(m(["a-prep": s1, "b-prep": s2], sessions: ["a-prep", "b-prep"]), "a-prep", "the occurrence beats the series")
        XCTAssertEqual(m(["b-prep": s2], sessions: ["b-prep"]), "b-prep", "the same one-off event id (moved)")
        XCTAssertNil(m(["a-prep": s2, "b-prep": s2], sessions: ["a-prep", "b-prep"]), "two folders carry the series: no guess")
        XCTAssertNil(m(["a-prep": s1], sessions: ["b-prep"]), "a folder that is not a session")
    }

    func testNameTokensInAnyOrderAndUniqueness() {
        let table: [(title: String, attendees: [Attendee], sessions: [String], want: String?, why: String)] = [
            ("Lena Hart / Corvid Labs", [], ["corvid-lena-hart", "sample-interview"], "corvid-lena-hart", "another word order"),
            ("Mara / Northwind Labs call", [], ["mara-northwindlabs"], "mara-northwindlabs", "two words written together"),
            ("Intro call", [Attendee(name: "Lena Hart")], ["lena-hart"], "lena-hart", "an attendee's name counts"),
            ("Corvid Labs sync", [], ["corvid-labs", "corvid-labs-sync"], nil, "two candidates: no match"),
            ("Corvid Labs", [], ["corvid-lena-hart"], nil, "a folder token is missing"),
            ("Q3 plan", [], ["q3"], nil, "a folder with no token of 3+ characters never matches"),
            ("Café Ölçü", [], ["cafe-olcu"], "cafe-olcu", "accents folded"),
            ("Custom report", [], ["tom"], nil, "a token is a whole word, not part of one"),
        ]
        for row in table {
            let e = MeetingEvent(id: "x", title: row.title, start: at(0), end: at(30), attendees: row.attendees)
            XCTAssertEqual(MeetingSessionResolver.match(e, sessions: row.sessions, links: [:])?.session, row.want, row.why)
        }
    }

    func testPrepFromAnInviteWritesAnOccurrenceKeyAndASeriesLinkOnlyOnPurpose() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let map = EventSessionMap(url: dir.appendingPathComponent("event-sessions.json"))
        let e = meeting("weekly", start: 0)
        map.link(e, session: "this-week")
        XCTAssertEqual(map.load(), [e.occurrenceKey: "this-week"])
        map.linkSeries(e, session: "standing")
        XCTAssertEqual(map.load()["weekly"], "standing")
        XCTAssertEqual(map.forget(session: "this-week"), [e.occurrenceKey], "removing a session drops its occurrence key too")
    }

    func testSidecarRoundTripsThroughTheSessionFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("kickoff-prep", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = meeting("ev", "Kickoff", start: 0)
        try EventSidecar(event: e).write(sessionDir: dir)
        XCTAssertEqual(EventSidecar.read(sessionDir: dir), EventSidecar(event: e))
        XCTAssertEqual(EventSidecar.loadAll(sessions: ["kickoff-prep", "other"], root: root).keys.sorted(), ["kickoff-prep"])
    }

    // MARK: the shared ranking (G9)

    func testBackToBackHandover() {
        let r = meeting("r", start: 0, minutes: 60)          // 10:00-11:00
        let n = meeting("n", start: 60, minutes: 30)         // 11:00-11:30
        XCTAssertEqual(MeetingRanking.best([n, r], now: at(49))?.id, "r", "10:49: the running one")
        XCTAssertEqual(MeetingRanking.best([n, r], now: at(50))?.id, "n", "10:50: ten minutes left, the next starts in ten")
        let long = meeting("long", start: 0, minutes: 120)   // 10:00-12:00
        let soon = meeting("soon", start: 55)
        XCTAssertEqual(MeetingRanking.best([long, soon], now: at(44))?.id, "long", "started 44 min ago")
        XCTAssertEqual(MeetingRanking.best([long, soon], now: at(46))?.id, "soon", "started 46 min ago and the next starts in 9")
        let fresh = meeting("fresh", start: -10, minutes: 60)
        XCTAssertEqual(MeetingRanking.best([fresh, meeting("next", start: 5)], now: ten)?.id, "fresh", "running with 50 min left")
        XCTAssertEqual(MeetingRanking.best([meeting("a", start: 12), meeting("b", start: -6, minutes: 5)], now: ten)?.id, "b",
                       "nothing running: the nearest start")
    }

    // MARK: the target

    func testTheTargetIsARealMeetingWithinTheLookahead() {
        let focus = meeting("focus", "Focus block", start: 0, minutes: 120, attendees: [])
        let call = meeting("call", start: 30)
        XCTAssertEqual(SessionAutoSelect.target(now: ten, events: [focus, call])?.id, "call", "a focus block is never the target")
        XCTAssertNil(SessionAutoSelect.target(now: ten, events: [focus]))
        let linked = MeetingEvent(id: "zoom", title: "Solo with a link", start: at(5), end: at(35), url: URL(string: "https://zoom.us/j/1"), provider: .zoom)
        XCTAssertEqual(SessionAutoSelect.target(now: ten, events: [linked])?.id, "zoom", "a call link makes it real")
        let owner = Attendee(name: "Me", email: "me@example.com")
        let solo = MeetingEvent(id: "solo", title: "Solo", start: at(5), end: at(35), attendees: [owner], currentUser: owner)
        XCTAssertNil(SessionAutoSelect.target(now: ten, events: [solo]), "only the owner on the invite")
        XCTAssertEqual(SessionAutoSelect.target(now: ten, events: [meeting("far", start: 36 * 60)])?.id, "far", "36 h ahead")
        XCTAssertNil(SessionAutoSelect.target(now: ten, events: [meeting("farther", start: 36 * 60 + 1)]))
        XCTAssertNil(SessionAutoSelect.target(now: ten, events: [meeting("over", start: -60, minutes: 30)]), "already over")
    }

    // MARK: auto-select (G1) and the manual override

    private let sessions = ["lena-prep", "omar-prep", "old-prep"]

    private func pick(_ events: [MeetingEvent], links: [String: String] = [:], manual: ManualChoice? = nil, now: Date? = nil) -> SessionAutoSelect.Decision {
        SessionAutoSelect.pick(now: now ?? ten, events: events, matcher: SessionMatcher(sessions: sessions, links: links), manual: manual)
    }

    func testTheNextMeetingsSessionIsSelected() {
        let e = meeting("lena", start: 90)
        let d = pick([e], links: [e.occurrenceKey: "lena-prep"])
        XCTAssertEqual(d.select, "lena-prep")
        XCTAssertEqual(d.reason, .nextMeeting(e.occurrenceKey))
        XCTAssertEqual(d.target?.id, "lena")
        XCTAssertEqual(d.match?.source, .occurrenceLink)
    }

    func testANextMeetingWithoutASessionOrNoMeetingKeepsTheSelection() {
        let e = meeting("unprepared", "Board call", start: 90)
        XCTAssertEqual(pick([e]), SessionAutoSelect.Decision(select: nil, reason: .notPrepared(e.occurrenceKey), target: e, match: nil))
        XCTAssertEqual(pick([]), SessionAutoSelect.Decision(select: nil, reason: .noMeeting, target: nil, match: nil))
    }

    func testAManualPickHoldsWhileItsMeetingIsTheTargetAndEndsWhenTheTargetChanges() {
        let lena = meeting("lena", start: 30), omar = meeting("omar", start: 90)
        let links = [lena.occurrenceKey: "lena-prep", omar.occurrenceKey: "omar-prep"]
        let manual = ManualChoice(session: "old-prep", targetKey: lena.occurrenceKey, at: at(0))
        XCTAssertEqual(pick([lena, omar], links: links, manual: manual).reason, .manual)
        XCTAssertNil(pick([lena, omar], links: links, manual: manual).select)
        // Lena's call ended: Omar's is the target, the pick is over.
        let later = pick([lena, omar], links: links, manual: manual, now: at(61))
        XCTAssertEqual(later.select, "omar-prep")
        XCTAssertEqual(later.reason, .nextMeeting(omar.occurrenceKey))
        // Lena's call was deleted: another meeting is the target, the pick is over.
        XCTAssertEqual(pick([omar], links: links, manual: manual).select, "omar-prep")
        // A pick of a folder that is gone does not hold.
        XCTAssertEqual(pick([lena], links: links, manual: ManualChoice(session: "gone", targetKey: lena.occurrenceKey, at: ten)).select, "lena-prep")
    }

    func testAManualPickWithNoMeetingAheadLastsTwelveHoursOrUntilOneAppears() {
        let manual = ManualChoice(session: "old-prep", targetKey: nil, at: ten)
        XCTAssertTrue(manual.isActive(now: at(11 * 60 + 59), targetKey: nil))
        XCTAssertFalse(manual.isActive(now: at(12 * 60), targetKey: nil), "12 hours later")
        let e = meeting("lena", start: 13 * 60)
        XCTAssertEqual(pick([e], links: [e.occurrenceKey: "lena-prep"], manual: manual, now: at(60)).select, "lena-prep",
                       "a meeting appeared within the lookahead")
    }

    // MARK: the fallback when the selection disappears (G7)

    func testFallbackIsTheTargetsSessionElseTheNewestElseNone() {
        let e = meeting("lena", start: 30)
        let created = ["lena-prep": at(-3000), "omar-prep": at(-10), "old-prep": at(-5000)]
        let matcher = SessionMatcher(sessions: sessions, links: [e.occurrenceKey: "lena-prep"])
        XCTAssertEqual(SessionAutoSelect.fallback(now: ten, events: [e], matcher: matcher, createdAt: created), "lena-prep")
        XCTAssertEqual(SessionAutoSelect.fallback(now: ten, events: [], matcher: matcher, createdAt: created), "omar-prep", "newest, not A-Z first")
        XCTAssertEqual(SessionAutoSelect.newest(["b-call", "a-call"], createdAt: [:]), "a-call", "no dates: A-Z first")
        XCTAssertEqual(SessionAutoSelect.newest(["b-call", "a-call"], createdAt: ["a-call": ten, "b-call": ten]), "a-call", "a tie: A-Z")
        XCTAssertNil(SessionAutoSelect.fallback(now: ten, events: [e], matcher: SessionMatcher(sessions: []), createdAt: [:]))
    }

    func testCreatedAtReadsMetaThenFileTimes() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["with-meta", "without-meta"] {
            let d = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data().write(to: d.appendingPathComponent("pack.md"))
        }
        try #"{"created_at":"2026-01-02T03:04:05Z"}"#.write(to: root.appendingPathComponent("with-meta/meta.json"), atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent("without-meta/pack.md").path)
        let c = SessionAutoSelect.createdAt(sessions: ["with-meta", "without-meta"], root: root)
        XCTAssertEqual(c["with-meta"], ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(c["without-meta"], old)
    }

    // MARK: Start now (G4)

    func testStartNowUsesTheMeetingAroundNowElseTheManualPickElseAdhoc() {
        let near = meeting("near", start: 10)
        let far = meeting("far", start: 3 * 60)
        let matcher = SessionMatcher(sessions: sessions, links: [near.occurrenceKey: "lena-prep", far.occurrenceKey: "omar-prep"])
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [near], matcher: matcher, manualSession: "old-prep"), .prepared("lena-prep"),
                       "1: the meeting within 15 minutes beats the manual pick")
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [far], matcher: matcher, manualSession: "old-prep"), .prepared("old-prep"),
                       "2: no meeting near, the manual pick")
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [far], matcher: matcher, manualSession: nil), .adhoc,
                       "3: a meeting hours away never takes an impromptu call")
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [], matcher: matcher, manualSession: "gone"), .adhoc, "a manual pick that is gone")
        // The name rule counts for Start now too.
        let named = meeting("x", "Omar intro", start: 0, attendees: [Attendee(name: "Omar")])
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [named], matcher: SessionMatcher(sessions: ["omar-prep2", "omar"])), .prepared("omar"))
    }

    // MARK: SessionSelector

    private final class Box {
        var busy = false
        var events: [MeetingEvent] = []
        var reads = 0
        var now: Date
        var logs: [String] = []
        init(now: Date) { self.now = now }
    }

    private func selector(_ box: Box, sessions: [String]? = nil, links: [String: String] = [:],
                          created: [String: Date] = [:]) -> (SessionSelector, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "verse.tests.\(UUID().uuidString)")!)
        let names = sessions ?? self.sessions
        let s = SessionSelector(settings: settings, busy: { box.busy }, sessions: { names },
                                readEvents: { _ in box.reads += 1; return box.events },
                                loadMatcher: { SessionMatcher(sessions: $0, links: links) },
                                createdAt: { _ in created }, clock: { box.now }, log: { box.logs.append($0) })
        return (s, settings)
    }

    func testTheSelectorWritesOnlyWhenNothingIsUnderWayAndLogsOneLinePerChange() {
        let box = Box(now: ten)
        let e = meeting("lena", start: 60)
        box.events = [e]
        let (s, settings) = selector(box, links: [e.occurrenceKey: "lena-prep"])
        settings.sessionName = "old-prep"
        box.busy = true
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "old-prep", "a run, a practice or a prompt: nothing changes")
        XCTAssertEqual(box.reads, 0, "and the calendar is not read")
        box.busy = false
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "lena-prep")
        XCTAssertEqual(s.target?.id, "lena")
        XCTAssertEqual(s.targetMatch?.session, "lena-prep")
        XCTAssertEqual(s.matches[e.occurrenceKey]?.session, "lena-prep")
        XCTAssertEqual(s.reason, .nextMeeting(e.occurrenceKey))
        s.reevaluate()
        XCTAssertEqual(box.logs.filter { $0.hasPrefix("session auto-selected") }, ["session auto-selected lena-prep for \(e.occurrenceKey)"])
    }

    func testAManualChoiceIsPersistedHoldsAndEndsWhenTheTargetChanges() {
        let box = Box(now: ten)
        let lena = meeting("lena", start: 30), omar = meeting("omar", start: 120)
        box.events = [lena, omar]
        let links = [lena.occurrenceKey: "lena-prep", omar.occurrenceKey: "omar-prep"]
        let (s, settings) = selector(box, links: links)
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "lena-prep")
        s.choose("old-prep")
        XCTAssertEqual(settings.sessionPickManual, ManualChoice(session: "old-prep", targetKey: lena.occurrenceKey, at: ten))
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "old-prep", "the hand pick holds for Lena's call")
        XCTAssertEqual(s.manualSession(now: ten), "old-prep")
        box.now = at(61)   // Lena's call is over
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "omar-prep")
        XCTAssertNil(settings.sessionPickManual, "the ended pick is dropped")
        XCTAssertNil(s.manualSession(now: box.now))
    }

    func testTheStartWindowChangesWhenTheClockCrossesTheLeadTimeOrAPickChanges() {
        // The menu's Start row observes the selector: it is labelled again only when something published changes (owner decision 3).
        let box = Box(now: ten)
        let lena = meeting("lena", start: 61)
        box.events = [lena]
        let (s, _) = selector(box, links: [lena.occurrenceKey: "lena-prep"])
        s.reevaluate()
        XCTAssertEqual(s.startWindow, .init(events: [], manual: nil), "61 minutes ahead: outside the 60-minute lead")
        let target = s.target, reason = s.reason
        box.now = at(2)                                                   // one 60 s tick later, nothing else changed
        s.reevaluate()
        XCTAssertEqual(s.target, target)
        XCTAssertEqual(s.reason, reason, "target and reason stay the same at T-60 ...")
        XCTAssertEqual(s.startWindow.events, [lena.occurrenceKey], "... the start window does not")
        box.now = at(61 + 30 + 16)                                        // 16 minutes after the end
        s.reevaluate()
        XCTAssertEqual(s.startWindow.events, [], "past the 15 minutes after the end")
        // A second pick by hand while the reason is already manual still changes what Start uses.
        box.now = ten
        s.reevaluate()
        s.choose("old-prep")
        XCTAssertEqual(s.startWindow.manual, "old-prep")
        s.choose("lena-prep")
        XCTAssertEqual(s.reason, .manual)
        XCTAssertEqual(s.startWindow.manual, "lena-prep")
    }

    func testAProgrammaticWriteIsNotAManualPick() {
        let box = Box(now: ten)
        let e = meeting("lena", start: 30)
        box.events = [e]
        let (s, settings) = selector(box, links: [e.occurrenceKey: "lena-prep"])
        settings.sessionName = "old-prep"   // Start now, the prompt, Retry write it this way
        XCTAssertNil(settings.sessionPickManual)
        s.reevaluate()
        XCTAssertEqual(settings.sessionName, "lena-prep")
    }

    func testARelaunchKeepsALiveManualPickAndDropsAnEndedOne() {
        let suite = "verse.tests.\(UUID().uuidString)"
        let lena = meeting("lena", start: 30)
        let links = [lena.occurrenceKey: "lena-prep"]
        func launch(now: Date, events: [MeetingEvent]) -> AppSettings {
            let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
            let s = SessionSelector(settings: settings, busy: { false }, sessions: { self.sessions }, readEvents: { _ in events },
                                    loadMatcher: { SessionMatcher(sessions: $0, links: links) }, createdAt: { _ in [:] },
                                    clock: { now }, log: { _ in })
            s.reevaluate()
            return settings
        }
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.sessionName = "old-prep"
        first.sessionPickManual = ManualChoice(session: "old-prep", targetKey: lena.occurrenceKey, at: ten)
        XCTAssertEqual(launch(now: at(5), events: [lena]).sessionName, "old-prep", "still Lena's call: the pick holds")
        let afterwards = launch(now: at(5), events: [meeting("omar", start: 20)])
        XCTAssertEqual(afterwards.sessionName, "old-prep", "another meeting without a session: kept, but no longer manual")
        XCTAssertNil(afterwards.sessionPickManual)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testAFinishedPrepTakesTheSelectionOnlyForTheTargetOrWithNoTarget() {
        let box = Box(now: ten)
        let lena = meeting("lena", start: 30)
        box.events = [lena]
        let (s, settings) = selector(box, sessions: ["lena-prep", "tomorrow-prep", "old-prep"], links: [lena.occurrenceKey: "lena-prep"])
        settings.sessionName = "lena-prep"
        XCTAssertFalse(s.didPrepare("tomorrow-prep"), "prepared for a later meeting")
        XCTAssertEqual(settings.sessionName, "lena-prep")
        XCTAssertTrue(s.didPrepare("lena-prep", event: lena), "prepared for the target")
        box.events = []
        XCTAssertTrue(s.didPrepare("tomorrow-prep"), "no meeting ahead: today's behaviour")
        XCTAssertEqual(settings.sessionName, "tomorrow-prep")
        box.busy = true
        XCTAssertFalse(s.didPrepare("old-prep"), "never during a call")
        XCTAssertEqual(settings.sessionName, "tomorrow-prep")
    }

    func testAMissingSelectionTakesTheTargetsSessionFromTheLastReadElseTheNewest() {
        let box = Box(now: ten)
        let lena = meeting("lena", start: 30)
        box.events = [lena]
        let (s, settings) = selector(box, sessions: ["lena-prep", "omar-prep"], links: [lena.occurrenceKey: "lena-prep"],
                                     created: ["omar-prep": at(-1)])
        s.reevaluate()
        settings.sessionPickManual = ManualChoice(session: "trashed", targetKey: nil, at: ten)
        settings.sessionName = "trashed"
        let reads = box.reads
        s.selectionMissing()
        XCTAssertEqual(settings.sessionName, "lena-prep")
        XCTAssertNil(settings.sessionPickManual)
        XCTAssertEqual(box.reads, reads, "no calendar read inside a refresh")
        let (cold, coldSettings) = selector(Box(now: ten), sessions: ["lena-prep", "omar-prep"], created: ["omar-prep": at(-1)])
        coldSettings.sessionName = "trashed"
        cold.selectionMissing()
        XCTAssertEqual(coldSettings.sessionName, "omar-prep", "no meeting known: the newest session")
    }

    // MARK: CalendarWatcher (G11)

    func testTheWatcherFiresOnTheStoreChangeAndKeepsTheAuthorization() async {
        let center = NotificationCenter()
        var auth = CalendarAuthorization.fullAccess
        let w = CalendarWatcher(authorization: { auth }, center: center, workspaceCenter: center, tickSeconds: 3600)
        var got: [CalendarWatcher.Trigger] = []
        let sub = w.changes.sink { got.append($0) }
        defer { sub.cancel(); w.stop() }
        w.start()
        XCTAssertTrue(w.isWatching)
        center.post(name: CalendarSource.storeChangedNotification, object: nil)
        center.post(name: .NSCalendarDayChanged, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<50 where got.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(got, [.storeChanged, .dayChanged, .wake])
        auth = .denied
        w.fire(.tick)
        XCTAssertEqual(w.authorization, .denied, "a revoked permission is told apart from an empty calendar")
    }
}
