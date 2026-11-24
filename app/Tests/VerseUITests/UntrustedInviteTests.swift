import Foundation
import VerseMeet
@testable import VerseUI
import XCTest

/// An invite anyone can send shows in the owner's calendar before he answers it, and its title and attendee names are the
/// sender's words. Such an event never starts a paid background prep, and never picks a prepared session by its name; the
/// background prep is capped per local day; Prepare by hand is never limited. Invented names only; time and calendar injected.
@MainActor
final class UntrustedInviteTests: XCTestCase {
    /// 2026-11-24 10:00:00 UTC.
    private let ten = Date(timeIntervalSince1970: 1_795_514_400)
    private func at(_ minutes: Double) -> Date { ten.addingTimeInterval(minutes * 60) }
    private let guest = Attendee(name: "Rowan Pell", email: "rowan@example.com")
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func invite(_ id: String, _ title: String = "Intro call", start: Double, _ p: Participation?) -> MeetingEvent {
        MeetingEvent(id: id, title: title, start: at(start), end: at(start + 30), attendees: [guest], participation: p)
    }

    // MARK: the background prep gate (finding 1)

    func testOnlyAMeetingHeOrganisesOrAcceptedIsPreparedInTheBackground() {
        let table: [(Participation?, Bool, String)] = [
            (nil, false, "status not known"),
            (.pending, false, "an invite he has not answered"),
            (.tentative, false, "maybe"),
            (.unknown, false, "not on the invite / read-only calendar"),
            (.accepted, true, "accepted"),
            (.organizer, true, "he organises it"),
        ]
        for (p, prepared, why) in table {
            let e = invite("ev", start: 60, p)
            let got = AutoPrepGate.candidate(now: ten, enabled: true, busy: false, upcoming: [e], matched: [], attempted: [], inFlight: [])
            XCTAssertEqual(got?.id, prepared ? "ev" : nil, why)
        }
        // An unanswered invite that starts sooner does not block the accepted meeting after it.
        let soon = invite("stranger", start: 10, .pending), later = invite("mine", start: 120, .accepted)
        XCTAssertEqual(AutoPrepGate.candidate(now: ten, enabled: true, busy: false, upcoming: [soon, later], matched: [], attempted: [],
                                              inFlight: [])?.id, "mine")
    }

    func testTheDailyCapCountsTheLocalDay() {
        let runs = [at(-60 * 9), at(0), at(60)]          // 01:00, 10:00, 11:00 UTC on the 24th
        XCTAssertEqual(AutoPrepGate.runsToday(runs, now: at(120), calendar: utc), 3)
        XCTAssertTrue(AutoPrepGate.capReached(runs, now: at(120), calendar: utc, cap: 3))
        XCTAssertFalse(AutoPrepGate.capReached(runs, now: at(14 * 60 + 1), calendar: utc, cap: 3), "00:01 on the 25th: a new day")
        XCTAssertEqual(AutoPrepGate.dailyCap, 5)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    private func autoPrep(suite: String, calls: Calls, logs: @escaping (String) -> Void = { _ in }) -> (MeetingAutoPrep, MeetingSettings) {
        let settings = MeetingSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.useCalendar = true
        let prep = MeetingAutoPrep(settings: settings, prepare: { event, _ in
            calls.add(event.id)
            return URL(fileURLWithPath: "/nonexistent/\(event.id)")
        }, language: { "en" }, onPrepared: { _, _ in }, log: logs, calendar: utc)
        return (prep, settings)
    }

    private func settle(_ prep: MeetingAutoPrep) async {
        for _ in 0..<200 where !prep.inFlight.isEmpty { await Task.yield() }
    }

    func testTheCapStopsTheSixthBackgroundPrepSurvivesARelaunchAndResetsTheNextDay() async {
        let suite = "verse.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let calls = Calls()
        var logs: [String] = []
        let (prep, settings) = autoPrep(suite: suite, calls: calls, logs: { logs.append($0) })
        // Seven accepted meetings tomorrow at noon and after: within the 36 h lookahead today and still ahead tomorrow at 10:00.
        let meetings = (0..<7).map { invite("m\($0)", start: Double(26 * 60 + $0 * 10), .accepted) }
        for i in 0..<5 {
            XCTAssertEqual(prep.consider(now: ten, busy: false, upcoming: meetings, matched: [])?.id, "m\(i)")
            await settle(prep)
        }
        XCTAssertNil(prep.consider(now: ten, busy: false, upcoming: meetings, matched: []), "the sixth today: capped")
        XCTAssertNil(prep.consider(now: at(1), busy: false, upcoming: meetings, matched: []))
        XCTAssertEqual(calls.all, ["m0", "m1", "m2", "m3", "m4"])
        XCTAssertEqual(logs.filter { $0.contains("daily cap") }.count, 1, "one line, not one per tick")
        XCTAssertEqual(settings.autoPrepAttempted["m5@\(Int(meetings[5].start.timeIntervalSince1970))"], nil,
                       "a capped meeting is not marked tried: it may be prepared once the day turns")
        // A relaunch reads the count back.
        let (relaunched, _) = autoPrep(suite: suite, calls: calls)
        XCTAssertNil(relaunched.consider(now: at(2), busy: false, upcoming: meetings, matched: []), "relaunch: still capped")
        // The next local day: allowed again.
        let tomorrow = at(24 * 60)
        XCTAssertEqual(relaunched.consider(now: tomorrow, busy: false, upcoming: meetings, matched: [])?.id, "m5")
        await settle(relaunched)
        XCTAssertEqual(calls.all.last, "m5")
    }

    func testPrepareByHandIgnoresHisAnswerAndTheCapAndIsNotCounted() async {
        let suite = "verse.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let (prep, settings) = autoPrep(suite: suite, calls: calls)
        settings.autoPrepBackgroundRuns = Array(repeating: at(-5), count: AutoPrepGate.dailyCap)   // the cap is reached
        let stranger = invite("stranger", start: 60, .pending)
        XCTAssertNil(prep.consider(now: ten, busy: false, upcoming: [stranger], matched: []), "not in the background")
        prep.prepareNow(stranger, now: ten)
        await settle(prep)
        let capped = invite("accepted", start: 90, .accepted)
        XCTAssertNil(prep.consider(now: ten, busy: false, upcoming: [capped], matched: []), "capped in the background")
        prep.prepareNow(capped, now: ten)
        await settle(prep)
        XCTAssertEqual(calls.all, ["stranger", "accepted"])
        XCTAssertEqual(settings.autoPrepBackgroundRuns.count, AutoPrepGate.dailyCap, "preps by hand do not count against the cap")
    }

    // MARK: the session name rule (finding 2)

    func testTheNameRuleMatchesOnlyAMeetingHeOrganisesOrAccepted() {
        let sessions = ["rowan-pell", "other-prep"]
        let table: [(Participation?, Bool, String)] = [
            (nil, false, "status not known"),
            (.pending, false, "an unanswered invite whose title names a session"),
            (.tentative, false, "maybe"),
            (.unknown, false, "unknown"),
            (.accepted, true, "accepted"),
            (.organizer, true, "he organises it"),
        ]
        for (p, matches, why) in table {
            let e = invite("ev", "Rowan Pell intro", start: 30, p)
            let m = MeetingSessionResolver.match(e, sessions: sessions, links: [:])
            XCTAssertEqual(m, matches ? SessionMatch(session: "rowan-pell", source: .name) : nil, why)
            XCTAssertEqual(MeetingSessionResolver.suggestion(e, sessions: sessions, links: [:]), matches ? nil : "rowan-pell",
                           "only a suggestion: " + why)
        }
        // The attendee's display name is the sender's words too.
        let byName = MeetingEvent(id: "ev2", title: "Catch-up", start: at(30), end: at(60),
                                  attendees: [Attendee(name: "Other Prep", email: "x@example.com")], participation: .pending)
        XCTAssertNil(MeetingSessionResolver.match(byName, sessions: sessions, links: [:]))
    }

    func testAnUnansweredInviteWithAMatchingTitleDrivesNoAutoSelectStartOrPrompt() {
        let e = invite("ev", "Rowan Pell intro", start: 10, .pending)
        let matcher = SessionMatcher(sessions: ["rowan-pell"])
        XCTAssertEqual(SessionAutoSelect.pick(now: ten, events: [e], matcher: matcher, manual: nil).select, nil, "auto-select")
        XCTAssertEqual(QuickStart.pickSession(now: ten, events: [e], matcher: matcher), .adhoc, "Start now")
        XCTAssertEqual(MeetingSessionResolver.plan(for: e, sessions: ["rowan-pell"], remembered: [:], selected: nil), .unprepared,
                       "the meeting prompt")
        XCTAssertEqual(matcher.suggestion(e), "rowan-pell", "the UI may still offer it")
    }

    func testLinksAndSidecarsVerseWroteHoldForAnUnansweredInvite() {
        var e = invite("ev", "Anything", start: 10, .pending)
        e.isRecurring = false
        XCTAssertEqual(MeetingSessionResolver.match(e, sessions: ["chosen"], links: [e.occurrenceKey: "chosen"])?.source, .occurrenceLink)
        XCTAssertEqual(MeetingSessionResolver.match(e, sessions: ["chosen"], links: ["ev": "chosen"])?.source, .seriesLink)
        XCTAssertEqual(MeetingSessionResolver.match(e, sessions: ["prepped"], links: [:], sidecars: ["prepped": EventSidecar(event: e)])?.source,
                       .sidecar)
    }
}
