import Foundation
import VerseMeet
import XCTest
@testable import VerseUI

@MainActor
final class EntityResolverTests: XCTestCase {
    private var env: PeopleEnv!

    override func setUpWithError() throws { env = try PeopleEnv() }
    override func tearDown() { env.cleanUp() }

    private func reconcile(_ file: PeopleFile, folders: FoldersFile = FoldersFile(), sessions: [HomeSession]) -> PeopleFile {
        var n = 0
        return EntityResolver.reconcile(file, folders: folders, sessions: sessions, makeID: { n += 1; return "e-new\(n)" }, now: env.when)
    }

    private func attendees(_ pairs: [String: [Attendee]], owners: [String] = ["owner@example.com"]) -> PeopleFile {
        var f = PeopleFile()
        f.attendees = pairs
        f.ownerEmails = owners
        return f
    }

    // MARK: reconcile

    func testAFolderMakesACompany() throws {
        let s = try env.session("halden-kickoff")
        let folders = env.folders([(id: "f-halden", name: "Halden Works", sessions: ["halden-kickoff"])])
        let out = reconcile(PeopleFile(), folders: folders, sessions: [s])
        let e = try XCTUnwrap(out.entity(named: "Halden Works"))
        XCTAssertEqual(e.kind, .company)
        XCTAssertEqual(e.folders, ["f-halden"])
        XCTAssertEqual(e.namedBy, "auto")
    }

    func testAFolderNamedAfterAnAttendeeMakesAPerson() throws {
        let s = try env.session("kickoff")
        let folders = env.folders([(id: "f-marta", name: "Marta Velin", sessions: ["kickoff"])])
        let out = reconcile(attendees(["kickoff": [PeopleEnv.marta]]), folders: folders, sessions: [s])
        let people = out.entities.filter { $0.name == "Marta Velin" }
        XCTAssertEqual(people.count, 1, "the address joins the folder's person instead of making a second one")
        XCTAssertEqual(people[0].kind, .person)
        XCTAssertEqual(people[0].folders, ["f-marta"])
        XCTAssertEqual(people[0].emails, ["marta@halden.example"])
        XCTAssertNotNil(people[0].company)
    }

    func testAnAttendeeMakesAPersonAndACompanyFromTheDomain() throws {
        let s = try env.session("kickoff")
        let out = reconcile(attendees(["kickoff": [PeopleEnv.marta, PeopleEnv.joe]]), sessions: [s])
        let marta = try XCTUnwrap(out.entity(named: "Marta Velin", .person))
        let company = try XCTUnwrap(out.entity(named: "Halden", .company))
        XCTAssertEqual(marta.emails, ["marta@halden.example"])
        XCTAssertEqual(marta.company, company.id)
        XCTAssertEqual(company.domains, ["halden.example"])
        XCTAssertEqual(out.entities.filter { $0.kind == .company }.count, 1, "both people share one company")
        XCTAssertEqual(try XCTUnwrap(out.entity(named: "Joe Arkwright")).company, company.id)
    }

    func testAnExistingCompanyWhoseNameIsTheDomainLabelIsReused() throws {
        let s = try env.session("kickoff")
        var f = attendees(["kickoff": [PeopleEnv.marta]])
        f.entities = [MemoryEntity(id: "e-halden", kind: .company, name: "halden", createdAt: env.when)]
        let out = reconcile(f, sessions: [s])
        XCTAssertEqual(out.entities.filter { $0.kind == .company }.count, 1)
        XCTAssertEqual(out.entities.first { $0.id == "e-halden" }?.domains, ["halden.example"])
        XCTAssertEqual(try XCTUnwrap(out.entity(named: "Marta Velin")).company, "e-halden")
    }

    func testFreemailMakesAPersonWithoutACompany() throws {
        let s = try env.session("intro")
        let out = reconcile(attendees(["intro": [Attendee(name: nil, email: "x.person@gmail.com")]]), sessions: [s])
        let p = try XCTUnwrap(out.entity(named: "X Person", .person), "named after the address's local part when the invite has no name")
        XCTAssertNil(p.company)
        XCTAssertEqual(out.entities.count, 1)
    }

    func testTheOwnerAndRoomsMakeNoEntity() throws {
        let s = try env.session("kickoff")
        let out = reconcile(attendees(["kickoff": [PeopleEnv.owner, Attendee(name: "Room", email: "c_1@resource.calendar.google.com"),
                                                  Attendee(name: nil, email: "noreply@halden.example")]]), sessions: [s])
        XCTAssertTrue(out.entities.isEmpty, "\(out.entities.map(\.name))")
    }

    func testReconcileTwiceChangesNothing() throws {
        let s1 = try env.session("kickoff"), s2 = try env.session("review")
        let folders = env.folders([(id: "f-halden", name: "Halden Works", sessions: ["kickoff"])])
        let first = reconcile(attendees(["kickoff": [PeopleEnv.marta, PeopleEnv.joe], "review": [PeopleEnv.giulia]]), folders: folders, sessions: [s1, s2])
        XCTAssertEqual(reconcile(first, folders: folders, sessions: [s1, s2]), first)
    }

    func testASessionThatIsGoneMakesNoEntity() throws {
        let out = reconcile(attendees(["trashed": [PeopleEnv.marta]]), sessions: [])
        XCTAssertTrue(out.entities.isEmpty)
    }

    func testAFolderRenameRenamesAnAutoNamedEntityOnly() throws {
        let s = try env.session("kickoff")
        var folders = env.folders([(id: "f-a", name: "Halden Works", sessions: ["kickoff"]), (id: "f-b", name: "Corvo", sessions: [])])
        var f = reconcile(PeopleFile(), folders: folders, sessions: [s])
        // Corvo's entity was named by hand.
        let corvo = try XCTUnwrap(f.entities.firstIndex { $0.name == "Corvo" })
        f.entities[corvo].name = "Corvo Studio"
        f.entities[corvo].namedBy = "user"
        folders.folders[0].name = "Halden Group"
        folders.folders[1].name = "Corvo Design"
        f = reconcile(f, folders: folders, sessions: [s])
        XCTAssertNotNil(f.entity(named: "Halden Group", .company))
        XCTAssertEqual(f.entity(named: "Halden Group")?.aliases, ["Halden Works"], "the old name stays findable")
        XCTAssertNotNil(f.entity(named: "Corvo Studio"), "a user-named entity keeps its name")
        XCTAssertNil(f.entity(named: "Corvo Design"))
    }

    // MARK: sessions of an entity

    private func hald() throws -> (file: PeopleFile, sessions: [HomeSession]) {
        let names = ["kickoff", "review", "corvo-call", "loose"]
        let sessions = try names.enumerated().map { try env.session($1, daysAgo: $0 + 1) }
        var f = PeopleFile()
        f.entities = [
            MemoryEntity(id: "e-marta", kind: .person, name: "Marta Velin", emails: ["marta@halden.example"], company: "e-halden", createdAt: env.when),
            MemoryEntity(id: "e-halden", kind: .company, name: "Halden Works", domains: ["halden.example"], folders: ["f-halden"], createdAt: env.when),
            MemoryEntity(id: "e-giulia", kind: .person, name: "Giulia Ferri", emails: ["giulia@corvo.example"], createdAt: env.when),
        ]
        f.attendees = ["kickoff": [PeopleEnv.marta], "review": [Attendee(name: "A Colleague", email: "colleague@halden.example")],
                       "corvo-call": [PeopleEnv.giulia]]
        return (f, sessions)
    }

    private func names(_ id: String, _ f: PeopleFile, _ folders: FoldersFile, _ s: [HomeSession]) -> [String] {
        EntityResolver.sessions(of: id, file: f, folders: folders, sessions: s).map(\.name)
    }

    func testSessionsOfByFolderEmailDomainLinkAndUnlink() throws {
        var (f, s) = try hald()
        var folders = env.folders([(id: "f-halden", name: "Halden Works", sessions: ["loose"])])
        // Marta: her address (kickoff). Newest first.
        XCTAssertEqual(names("e-marta", f, folders, s), ["kickoff"])
        // The company: its folder (loose), its domain (review: a colleague nobody knows), and its people's sessions (kickoff).
        XCTAssertEqual(names("e-halden", f, folders, s), ["kickoff", "review", "loose"])
        XCTAssertEqual(names("e-giulia", f, folders, s), ["corvo-call"])
        // Moving a session to another folder moves it between entities with no other write.
        folders.assign["loose"] = "f-other"
        XCTAssertEqual(names("e-halden", f, folders, s), ["kickoff", "review"])
        // A link by hand adds, an unlink removes whatever put it there.
        f.links["loose"] = ["e-giulia"]
        XCTAssertEqual(names("e-giulia", f, folders, s), ["corvo-call", "loose"], "newest first")
        f.unlinks["kickoff"] = ["e-marta"]
        XCTAssertEqual(names("e-marta", f, folders, s), [])
        XCTAssertEqual(names("e-halden", f, folders, s), ["kickoff", "review"], "the company still has it through its own signals")
        f.unlinks["kickoff"] = ["e-marta", "e-halden"]
        XCTAssertEqual(names("e-halden", f, folders, s), ["review"])
        s = []
        XCTAssertEqual(names("e-halden", f, folders, s), [])
    }

    func testAFreemailDomainOwnsNothing() throws {
        let s = [try env.session("intro")]
        var f = PeopleFile()
        f.entities = [MemoryEntity(id: "e-g", kind: .company, name: "Gmail", domains: ["gmail.com"], createdAt: env.when)]
        f.attendees = ["intro": [Attendee(name: nil, email: "someone@gmail.com")]]
        XCTAssertEqual(names("e-g", f, FoldersFile(), s), [])
    }

    func testPracticeRunsAndHiddenEntitiesAreLeftOut() throws {
        let practice = try env.session("sim-20261018-0900-halden", files: ["report.html": "<html></html>"])
        let held = try env.session("kickoff")
        var (f, _) = try hald()
        let folders = env.folders([(id: "f-halden", name: "Halden Works", sessions: ["sim-20261018-0900-halden", "kickoff"])])
        XCTAssertEqual(names("e-halden", f, folders, [practice, held]), ["kickoff"])
        f.entities[0].hidden = true
        XCTAssertEqual(names("e-marta", f, folders, [practice, held]), [], "a hidden entity owns nothing")
    }

    func testEntitiesOfASessionListPeopleThenCompanies() throws {
        let (f, _) = try hald()
        let es = EntityResolver.entities(of: "kickoff", file: f, folders: FoldersFile())
        XCTAssertEqual(es.map(\.name), ["Marta Velin", "Halden Works"])
    }

    func testPastSessionsNeedATranscriptOrASummaryAndExcludeOne() throws {
        _ = try env.session("kickoff")
        // A prepared session: a pack and nothing else.
        _ = try env.session("prep-only")
        try FileManager.default.removeItem(at: env.sessionsRoot.appendingPathComponent("prep-only/summary.md"))
        // A call whose summary was never written but whose transcript exists.
        _ = try env.session("call-only", files: ["transcript.jsonl": "{}\n"])
        try FileManager.default.removeItem(at: env.sessionsRoot.appendingPathComponent("call-only/summary.md"))
        let all = env.reload(["kickoff", "prep-only", "call-only"])
        var f = PeopleFile()
        f.entities = [MemoryEntity(id: "e-h", kind: .company, name: "Halden", folders: ["f"], createdAt: env.when)]
        let folders = env.folders([(id: "f", name: "Halden", sessions: ["kickoff", "prep-only", "call-only"])])
        XCTAssertEqual(EntityResolver.pastSessions(of: "e-h", excluding: nil, file: f, folders: folders, sessions: all).map(\.name).sorted(),
                       ["call-only", "kickoff"])
        XCTAssertEqual(EntityResolver.pastSessions(of: "e-h", excluding: "kickoff", file: f, folders: folders, sessions: all).map(\.name), ["call-only"])
        XCTAssertEqual(EntityResolver.sessions(of: "e-h", file: f, folders: folders, sessions: all).count, 3, "a prepared session is still the entity's")
    }

    // MARK: primary entity

    private func world() throws -> (PeopleFile, FoldersFile, [HomeSession]) {
        let s = [try env.session("h1", daysAgo: 3), try env.session("h2", daysAgo: 2), try env.session("c1", daysAgo: 1)]
        var f = PeopleFile()
        f.entities = [
            MemoryEntity(id: "e-marta", kind: .person, name: "Marta Velin", emails: ["marta@halden.example"], company: "e-halden", createdAt: env.when),
            MemoryEntity(id: "e-joe", kind: .person, name: "Joe Arkwright", emails: ["joe@halden.example"], company: "e-halden", createdAt: env.when),
            MemoryEntity(id: "e-halden", kind: .company, name: "Halden Works", domains: ["halden.example"], createdAt: env.when),
            MemoryEntity(id: "e-giulia", kind: .person, name: "Giulia Ferri", emails: ["giulia@corvo.example"], company: "e-corvo", createdAt: env.when),
            MemoryEntity(id: "e-corvo", kind: .company, name: "Corvo Studio", domains: ["corvo.example"], createdAt: env.when),
            MemoryEntity(id: "e-emre", kind: .person, name: "Emre Kaya", emails: ["emre@gmail.com"], createdAt: env.when),
        ]
        f.ownerEmails = ["owner@example.com"]
        f.attendees = ["h1": [PeopleEnv.marta], "h2": [PeopleEnv.marta, PeopleEnv.joe], "c1": [PeopleEnv.giulia]]
        return (f, FoldersFile(), s)
    }

    func testPrimaryEntityOfTwoPeopleAtOneCompanyIsTheCompany() throws {
        let (f, folders, s) = try world()
        let e = env.event(attendees: [PeopleEnv.marta, PeopleEnv.joe])
        XCTAssertEqual(EntityResolver.primaryEntity(for: e, file: f, folders: folders, sessions: s)?.id, "e-halden")
    }

    func testPrimaryEntityOfOnePersonIsThatPerson() throws {
        let (f, folders, s) = try world()
        let e = env.event(attendees: [Attendee(name: "Emre Kaya", email: "emre@gmail.com")])
        XCTAssertEqual(EntityResolver.primaryEntity(for: e, file: f, folders: folders, sessions: s)?.id, "e-emre")
    }

    func testPrimaryEntityOfTwoCompaniesIsThePersonWithMoreSessions() throws {
        let (f, folders, s) = try world()
        let e = env.event(attendees: [PeopleEnv.giulia, PeopleEnv.marta])
        XCTAssertEqual(EntityResolver.primaryEntity(for: e, file: f, folders: folders, sessions: s)?.id, "e-marta", "Marta has 2 meetings, Giulia 1")
    }

    func testPrimaryEntityIgnoresTheOwnerAndNeedsSomeoneKnown() throws {
        let (f, folders, s) = try world()
        XCTAssertNil(EntityResolver.primaryEntity(for: env.event(attendees: []), file: f, folders: folders, sessions: s), "only the owner")
        let stranger = env.event(attendees: [Attendee(name: "Nobody", email: "nobody@unknown.example")])
        XCTAssertNil(EntityResolver.primaryEntity(for: stranger, file: f, folders: folders, sessions: s))
        // A known domain without a known person resolves to the company.
        let colleague = env.event(attendees: [Attendee(name: "New Colleague", email: "new@halden.example")])
        XCTAssertEqual(EntityResolver.primaryEntity(for: colleague, file: f, folders: folders, sessions: s)?.id, "e-halden")
    }

    func testGuestNamesNeverCarryAnAddress() throws {
        let (f, _, _) = try world()
        let e = env.event(attendees: [PeopleEnv.marta, Attendee(name: nil, email: "anon@halden.example"), Attendee(name: "Invited Guest", email: "guest@x.example")])
        let names = EntityResolver.guestNames(of: e, file: f)
        XCTAssertEqual(names, ["Marta Velin", "Invited Guest"])
        XCTAssertFalse(names.joined().contains("@"))
    }

    // MARK: suggestions

    func testASessionThatMentionsTheEntityIsSuggestedUntilDismissed() throws {
        let pricing = try env.session("Halden pricing call", daysAgo: 4)
        let other = try env.session("Corvo sync", daysAgo: 5)
        let s = [pricing, other]
        // "Halden Works" with no alias: the first word of a company name finds the session; "Corvo" is another company's.
        var f = PeopleFile()
        f.entities = [MemoryEntity(id: "e-h", kind: .company, name: "Halden Works", createdAt: env.when)]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-h", file: f, folders: FoldersFile(), sessions: s), ["Halden pricing call"])
        // With the alias it is the same session.
        f.entities[0].aliases = ["Halden"]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-h", file: f, folders: FoldersFile(), sessions: s), ["Halden pricing call"])
        // A session that already belongs is not suggested; a link takes it out.
        f.links["Halden pricing call"] = ["e-h"]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-h", file: f, folders: FoldersFile(), sessions: s), [])
        f.links = [:]
        f.dismissed["e-h"] = ["Halden pricing call"]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-h", file: f, folders: FoldersFile(), sessions: s), [])
        f.dismissed = [:]
        f.unlinks["Halden pricing call"] = ["e-h"]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-h", file: f, folders: FoldersFile(), sessions: s), [], "one he removed is not suggested again")
    }

    func testAPersonIsNotFoundByFirstNameAlone() throws {
        let s = [try env.session("Marta budget thoughts")]
        var f = PeopleFile()
        f.entities = [MemoryEntity(id: "e-m", kind: .person, name: "Marta Velin", createdAt: env.when)]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-m", file: f, folders: FoldersFile(), sessions: s), [])
        f.entities[0].aliases = ["Marta"]
        XCTAssertEqual(EntityResolver.suggestions(for: "e-m", file: f, folders: FoldersFile(), sessions: s), ["Marta budget thoughts"])
    }

    // MARK: merge suggestion

    func testMergeSuggestionOnTheNewerEntityOnly() throws {
        var f = PeopleFile()
        let old = env.when.addingTimeInterval(-1_000)
        f.entities = [
            MemoryEntity(id: "e-1", kind: .person, name: "Marta Velin", createdAt: old),
            MemoryEntity(id: "e-2", kind: .person, name: "Marta", createdAt: env.when),
            MemoryEntity(id: "e-3", kind: .person, name: "Marta Rossi", createdAt: env.when.addingTimeInterval(10)),
            MemoryEntity(id: "e-4", kind: .company, name: "Marta", createdAt: env.when.addingTimeInterval(20)),
            MemoryEntity(id: "e-5", kind: .person, name: "MARTA VELIN", createdAt: env.when.addingTimeInterval(30)),
        ]
        XCTAssertEqual(EntityResolver.mergeSuggestion(for: "e-2", file: f)?.id, "e-1", "Marta / Marta Velin")
        XCTAssertNil(EntityResolver.mergeSuggestion(for: "e-1", file: f), "shown on the newer one's page only")
        XCTAssertEqual(EntityResolver.mergeSuggestion(for: "e-5", file: f)?.id, "e-1", "equal folded names")
        // Marta Velin / Marta Rossi: the same first word, but both have two words.
        f.entities.removeAll { $0.id == "e-2" || $0.id == "e-5" }
        XCTAssertNil(EntityResolver.mergeSuggestion(for: "e-3", file: f))
        // A person and a company are never suggested to each other; "Not this" ends it.
        XCTAssertNil(EntityResolver.mergeSuggestion(for: "e-4", file: f))
        f.entities.append(MemoryEntity(id: "e-6", kind: .person, name: "Marta", createdAt: env.when.addingTimeInterval(40)))
        XCTAssertNotNil(EntityResolver.mergeSuggestion(for: "e-6", file: f))
        f.dismissed["e-6"] = ["e-1"]
        XCTAssertNotEqual(EntityResolver.mergeSuggestion(for: "e-6", file: f)?.id, "e-1")
    }
}
