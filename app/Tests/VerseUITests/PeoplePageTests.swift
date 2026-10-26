import Foundation
import AppKit
import SwiftUI
import VerseMeet
import XCTest
@testable import VerseUI

/// The People page's model (list order, search, hidden, entity page states) and the brief's layout. Fictional people only.
@MainActor
final class PeoplePageTests: XCTestCase {
    private var env: PeopleEnv!

    override func setUpWithError() throws { env = try PeopleEnv() }
    override func tearDown() { env.cleanUp() }

    private struct World {
        var file: PeopleFile
        var folders: FoldersFile
        var sessions: [HomeSession]
    }

    /// Marta (Halden Works, 2 meetings, last 2 days ago), Giulia (Corvo Studio, 1 meeting, 5 days ago), Emre (Tarla Labs, one meeting, 9 days ago,
    /// hidden), Joe (no meeting at all) and a company without anything.
    private func world() throws -> World {
        let s = [try env.session("h-kickoff", daysAgo: 8, summary: "# Meeting summary\n\n## Summary\n\nMarta described the backlog. The pilot starts in November.\n"),
                 try env.session("h-review", daysAgo: 2), try env.session("c-call", daysAgo: 5), try env.session("t-intro", daysAgo: 9)]
        var f = PeopleFile()
        f.entities = [
            MemoryEntity(id: "e-marta", kind: .person, name: "Marta Velin", emails: ["marta@halden.example"], aliases: ["MV"], company: "e-halden", createdAt: env.when),
            MemoryEntity(id: "e-halden", kind: .company, name: "Halden Works", domains: ["halden.example"], createdAt: env.when),
            MemoryEntity(id: "e-giulia", kind: .person, name: "Giulia Ferri", emails: ["giulia@corvo.example"], company: "e-corvo", createdAt: env.when),
            MemoryEntity(id: "e-corvo", kind: .company, name: "Corvo Studio", domains: ["corvo.example"], createdAt: env.when),
            MemoryEntity(id: "e-emre", kind: .person, name: "Emre Kaya", emails: ["emre@tarla.example"], hidden: true, createdAt: env.when),
            MemoryEntity(id: "e-joe", kind: .person, name: "Joe Arkwright", emails: ["joe@halden.example"], company: "e-halden", createdAt: env.when),
            MemoryEntity(id: "e-quiet", kind: .company, name: "Quiet Co", createdAt: env.when),
        ]
        f.attendees = ["h-kickoff": [PeopleEnv.marta], "h-review": [PeopleEnv.marta], "c-call": [PeopleEnv.giulia],
                       "t-intro": [Attendee(name: "Emre Kaya", email: "emre@tarla.example")]]
        return World(file: f, folders: FoldersFile(), sessions: s)
    }

    private func list(_ w: World, upcoming: [HomeUpNextItem] = [], query: String = "") -> PeopleModel.List {
        PeopleModel.list(file: w.file, folders: w.folders, sessions: w.sessions, upcoming: upcoming, query: query)
    }

    // MARK: list

    func testListOrderIsLastMetNewestFirstAndAnEntityWithNothingIsNotListed() throws {
        let l = list(try world())
        XCTAssertEqual(l.people.map(\.name), ["Marta Velin", "Giulia Ferri"], "Joe has no session, Emre is hidden")
        XCTAssertEqual(l.companies.map(\.name), ["Halden Works", "Corvo Studio"], "Quiet Co has nothing")
        XCTAssertEqual(l.hidden.map(\.name), ["Emre Kaya"])
        XCTAssertEqual(l.people[0].meetings, 2)
        XCTAssertEqual(l.people[0].companyName, "Halden Works")
        XCTAssertEqual(l.companies[0].people, 1, "only listed people count")
        XCTAssertFalse(l.isEmpty)
    }

    func testAnUpcomingMeetingPutsAnEntityFirstAndShowsItsTime() throws {
        let w = try world()
        let event = env.event(attendees: [PeopleEnv.giulia])
        let item = HomeUpNextItem(id: event.id, title: event.title, meta: "", session: nil, event: event)
        let l = list(w, upcoming: [item])
        XCTAssertEqual(l.people.map(\.name), ["Giulia Ferri", "Marta Velin"], "upcoming first, then last met")
        XCTAssertEqual(l.people[0].next, event.start)
        XCTAssertEqual(l.companies.first?.name, "Corvo Studio")
        // An entity with only an upcoming event is listed.
        let joe = env.event("Halden intro", attendees: [PeopleEnv.joe])
        let l2 = list(w, upcoming: [HomeUpNextItem(id: joe.id, title: joe.title, meta: "", session: nil, event: joe)])
        XCTAssertTrue(l2.people.contains { $0.name == "Joe Arkwright" })
        let line = PeopleModel.secondLine(l.people[0])
        XCTAssertTrue(line.upcoming)
        XCTAssertNotNil(line.tail)
    }

    func testSearchFindsAliasEmailDomainAndCompany() throws {
        let w = try world()
        XCTAssertEqual(list(w, query: "mv").people.map(\.name), ["Marta Velin"], "by alias")
        XCTAssertEqual(list(w, query: "GIULIA@corvo").people.map(\.name), ["Giulia Ferri"], "by email, any case")
        XCTAssertEqual(list(w, query: "halden").people.map(\.name), ["Marta Velin"], "a person by company; Joe has no session")
        XCTAssertEqual(list(w, query: "halden").companies.map(\.name), ["Halden Works"])
        XCTAssertEqual(list(w, query: "corvo.example").companies.map(\.name), ["Corvo Studio"], "by domain")
        XCTAssertTrue(list(w, query: "zzz").isEmpty)
        // Hidden ones are searched too.
        XCTAssertEqual(list(w, query: "emre").hidden.map(\.name), ["Emre Kaya"])
        // Accents and Turkish dots fold.
        var f = w.file
        f.entities[0].name = "Marta Velín"
        XCTAssertEqual(PeopleModel.list(file: f, folders: w.folders, sessions: w.sessions, upcoming: [], query: "velin").people.map(\.name), ["Marta Velín"])
    }

    func testArrowOrderSkipsACollapsedHiddenSection() throws {
        let l = list(try world())
        XCTAssertEqual(l.order(includingHidden: false), ["e-marta", "e-giulia", "e-halden", "e-corvo"])
        XCTAssertEqual(l.order(includingHidden: true).last, "e-emre")
    }

    func testTextHelpers() {
        XCTAssertEqual(PeopleModel.initials("Marta Velin"), "MV")
        XCTAssertEqual(PeopleModel.initials("halden"), "H")
        XCTAssertEqual(PeopleModel.initials("Corvo Studio Milano"), "CS")
        XCTAssertEqual(PeopleModel.meetingsText(1), "1 meeting")
        XCTAssertEqual(PeopleModel.meetingsText(3), "3 meetings")
        XCTAssertEqual(PeopleModel.peopleText(1), "1 person")
        XCTAssertEqual(PeopleModel.peopleText(2), "2 people")
        let person = PeopleModel.Row(id: "p", kind: .person, name: "Marta Velin", companyName: "Halden Works", meetings: 3,
                                     lastMet: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(PeopleModel.secondLine(person).head, "Halden Works · 3 meetings")
        let company = PeopleModel.Row(id: "c", kind: .company, name: "Halden Works", people: 2, meetings: 5)
        XCTAssertEqual(PeopleModel.secondLine(company, countingMeetings: false).head, "2 people")
        XCTAssertEqual(PeopleModel.shortName(MemoryEntity(id: "x", kind: .person, name: "Marta Velin", createdAt: .now)), "Marta")
        XCTAssertEqual(PeopleModel.shortName(MemoryEntity(id: "x", kind: .company, name: "Halden Works", createdAt: .now)), "Halden Works")
    }

    // MARK: entity page

    func testThePageHasMeetingsUpcomingAndSuggestions() throws {
        var w = try world()
        let event = env.event(attendees: [PeopleEnv.marta])
        let item = HomeUpNextItem(id: event.id, title: event.title, meta: "", session: nil, event: event)
        w.sessions.append(try env.session("Halden pricing call", daysAgo: 20))
        let page = try XCTUnwrap(PeopleModel.page(for: "e-marta", file: w.file, folders: w.folders, sessions: w.sessions, upcoming: [item]))
        XCTAssertEqual(page.meetings.map(\.name), ["h-review", "h-kickoff"])
        XCTAssertEqual(page.upcoming.map(\.id), [event.id])
        XCTAssertEqual(page.company?.name, "Halden Works")
        let company = try XCTUnwrap(PeopleModel.page(for: "e-halden", file: w.file, folders: w.folders, sessions: w.sessions, upcoming: []))
        XCTAssertEqual(company.people.map(\.name), ["Marta Velin", "Joe Arkwright"])
        XCTAssertEqual(company.meetings.count, 2, "a company lists its people's meetings")
        XCTAssertEqual(company.suggestions.map(\.name), ["Halden pricing call"])
        // An old id resolves through `merged`.
        w.file.merged["e-old"] = "e-marta"
        XCTAssertEqual(PeopleModel.page(for: "e-old", file: w.file, folders: w.folders, sessions: w.sessions, upcoming: [])?.entity.id, "e-marta")
        XCTAssertNil(PeopleModel.page(for: "e-nobody", file: w.file, folders: w.folders, sessions: w.sessions, upcoming: []))
    }

    // MARK: brief states

    private func brief(newest: String, sessions: [String] = ["h-review", "h-kickoff"], cost: Double = 0.048) -> BriefFile {
        BriefFile(version: 1, entity: "e-marta", name: "Marta Velin", madeAt: env.when, lang: "en", model: "claude-sonnet-5-5", newestSession: newest,
                  forSession: nil, sessions: sessions.map { .init(name: $0, key: "k" + $0, title: $0, date: "2026-10-19T17:00:00+02:00") },
                  sections: [], costUSD: cost, droppedUncited: 0)
    }

    func testBriefStatesByFixture() throws {
        let w = try world()
        let past = PeopleModel.page(for: "e-marta", file: w.file, folders: w.folders, sessions: w.sessions, upcoming: [])!.meetings
        XCTAssertEqual(PeopleModel.briefState(past: past, brief: brief(newest: "h-review"), making: false, failure: nil), .ready(brief(newest: "h-review")))
        guard case .stale(_, let newest) = PeopleModel.briefState(past: past, brief: brief(newest: "h-kickoff"), making: false, failure: nil) else {
            return XCTFail("a newer meeting makes it stale")
        }
        XCTAssertEqual(newest.name, "h-review")
        XCTAssertEqual(PeopleModel.briefState(past: past, brief: nil, making: false, failure: nil), .none(pastMeetings: 2))
        XCTAssertEqual(PeopleModel.briefState(past: past, brief: nil, making: true, failure: nil), .making)
        XCTAssertEqual(PeopleModel.briefState(past: past, brief: brief(newest: "h-review"), making: true, failure: nil), .making, "making wins while updating")
        let failure = ChatFailure(kind: "offline", message: "")
        XCTAssertEqual(PeopleModel.briefState(past: past, brief: nil, making: false, failure: failure), .failed(failure))
        XCTAssertEqual(PeopleModel.briefState(past: [], brief: brief(newest: "h-review"), making: false, failure: nil), .hidden,
                       "no past meeting with a transcript or summary: the plate is not shown")
        XCTAssertEqual(PeopleModel.failureText(ChatFailure(kind: "no_sessions", message: "")), "There are no past meetings to sum up yet.")
        XCTAssertEqual(PeopleModel.failureText(failure), AskMessages.text(for: failure))
    }

    func testBriefLanguage() {
        XCTAssertEqual(BriefLanguage.pick(upcoming: "it", past: ["en", "en"]), "it", "the prepared session's language first")
        XCTAssertEqual(BriefLanguage.pick(upcoming: nil, past: ["tr", "en", "tr"]), "tr")
        XCTAssertEqual(BriefLanguage.pick(upcoming: "", past: ["", ""]), "en")
        XCTAssertEqual(BriefLanguage.pick(upcoming: nil, past: []), "en")
    }

    // MARK: timeline and follow-up files

    func testFirstSentenceAndActionsOfASummary() throws {
        let text = "# Meeting summary\n\n_generated fixture_\n\n## Summary\n\nMarta described the backlog. The pilot starts in November.\n\n## Actions\n\n- Send the budget\n- (none)\n- Share the plan\n"
        XCTAssertEqual(EntityFiles.firstSentence(text), "Marta described the backlog.")
        XCTAssertEqual(EntityFiles.actions(text), ["Send the budget", "Share the plan"])
        XCTAssertNil(EntityFiles.firstSentence("## Decisions\n\n- Go\n"))
        XCTAssertEqual(EntityFiles.firstSentence("## Summary\n\nNo full stop here"), "No full stop here")
    }

    func testEntityFilesReadSummariesAndTheBriefFlag() throws {
        let w = try world()
        let dir = w.sessions.first { $0.name == "h-kickoff" }!.dir
        try Data("{}".utf8).write(to: dir.appendingPathComponent("brief.json"))
        let loaded = EntityFiles.load(env.reload(["h-kickoff", "h-review"]))
        XCTAssertEqual(loaded.extras["h-kickoff"]?.snippet, "Marta described the backlog.")
        XCTAssertEqual(loaded.extras["h-kickoff"]?.hadBrief, true)
        XCTAssertEqual(loaded.extras["h-review"]?.hadBrief, false)
        XCTAssertTrue(loaded.follow.isEmpty, "the fixture summaries have no Actions section")
    }

    // MARK: the brief's layout

    private func richBrief() -> BriefFile {
        func cite(_ s: String, _ kind: String = "turn", _ stamp: String? = nil) -> BriefFile.Cite { .init(key: "k" + s, session: s, kind: kind, stamp: stamp) }
        var b = brief(newest: "h-review")
        b.sections = [
            .init(id: "discussed", points: [
                .init(text: "The pilot covers two teams", cites: [cite("h-review", "turn", "4:10"), cite("h-kickoff", "summary")]),
                .init(text: "Pricing moves to per-seat", cites: [cite("h-review", "turn", "4:10")]),
                .init(text: "A point whose only source was trashed", cites: [cite("gone", "turn", "1:00")]),
            ]),
            .init(id: "promised_owner", points: [.init(text: "Send the budget", cites: [cite("h-review", "summary")])]),
            .init(id: "promised_them", points: []),
            .init(id: "tone", points: [.init(text: "Nothing clear yet", cites: [])]),
        ]
        return b
    }

    func testBriefLayoutNumbersSourcesPerSectionAndHidesTrashedOnes() {
        let layout = BriefLayout.make(brief: richBrief(), available: ["h-review", "h-kickoff"])
        XCTAssertEqual(layout.sections.map(\.id), ["discussed", "promised_owner", "tone"], "an empty section is not shown")
        let discussed = layout.sections[0]
        XCTAssertEqual(discussed.points.map(\.text), ["The pilot covers two teams", "Pricing moves to per-seat"], "the trashed source's point is hidden")
        XCTAssertEqual(discussed.points[0].marks, [1, 2])
        XCTAssertEqual(discussed.points[1].marks, [1], "the same source keeps its ordinal")
        XCTAssertEqual(discussed.sources.map(\.ordinal), [1, 2])
        XCTAssertEqual(discussed.sources[0].caption.hasSuffix("4:10"), true)
        XCTAssertTrue(discussed.sources[0].caption.hasPrefix("h-review · "), discussed.sources[0].caption)
        XCTAssertEqual(discussed.sources[1].caption.hasSuffix("Summary"), true)
        XCTAssertEqual(layout.sections[1].sources.map(\.ordinal), [1], "ordinals restart in each section")
        XCTAssertEqual(layout.sections[2].points.map(\.text), ["Nothing clear yet"], "a point allowed without a citation stays")
        XCTAssertTrue(layout.sections[2].sources.isEmpty)
        XCTAssertEqual(BriefLayout.make(brief: richBrief(), available: []).sections.map(\.id), ["tone"])
    }

    func testBriefSectionTitlesAreLocalized() {
        XCTAssertEqual(BriefLayout.title(forSection: "promised_owner"), "You promised")
        XCTAssertEqual(BriefLayout.title(forSection: "promised_them"), "They promised")
        XCTAssertEqual(BriefLayout.title(forSection: "tone"), "Tone and preferences")
        XCTAssertEqual(EntityPageView.reveal(for: .init(key: "k", session: "s", kind: "turn", stamp: "12:34")), .stamp("12:34"))
        XCTAssertEqual(EntityPageView.reveal(for: .init(key: "k", session: "s", kind: "summary", stamp: nil)), .summary)
        XCTAssertEqual(EntityPageView.reveal(for: .init(key: "k", session: "s", kind: "chat", stamp: nil)), .none)
    }

    func testBriefViewRendersInAHostingView() throws {
        _ = NSApplication.shared
        let view = BriefView(brief: richBrief(), ownerName: "Dana Reyes", availableSessions: ["h-review", "h-kickoff"], onCitation: { _ in })
            .environment(\.homeInk, VT.Window(dark: true)).frame(width: 520)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    // MARK: router

    func testRouterEntryPoints() {
        let router = HomeRouter()
        router.showEntity("e-marta")
        XCTAssertEqual(router.page, .people)
        XCTAssertEqual(router.selectedEntity, "e-marta")
        router.showAsk(.entity("e-marta"))
        XCTAssertEqual(router.page, .sessions)
        XCTAssertEqual(router.askRequest, .entity("e-marta"))
        router.showSession("h-kickoff", reveal: .stamp("12:34"))
        XCTAssertEqual(router.selectedSession, "h-kickoff")
        XCTAssertEqual(router.revealRequest, SessionRevealRequest(session: "h-kickoff", reveal: .stamp("12:34"), serial: 1))
        router.showSession("h-kickoff", reveal: .stamp("12:34"))
        XCTAssertEqual(router.revealRequest?.serial, 2, "asking for the same place twice is two requests")
        XCTAssertEqual(HomePage.people.title, "People")
        XCTAssertEqual(HomePage.people.symbol, "person.2")
        XCTAssertEqual(HomePage.allCases.firstIndex(of: .people), (HomePage.allCases.firstIndex(of: .sessions) ?? 0) + 1)
    }
}
