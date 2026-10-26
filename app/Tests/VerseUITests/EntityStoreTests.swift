import Foundation
import VerseMeet
import XCTest
@testable import VerseUI

@MainActor
final class EntityStoreTests: XCTestCase {
    private var env: PeopleEnv!

    override func setUpWithError() throws { env = try PeopleEnv() }
    override func tearDown() { env.cleanUp() }

    // MARK: codec

    private let specExample = """
    {"version":1,
     "entities":[
      {"id":"e-3k9xq2ma","kind":"person","name":"Marta Velin","emails":["marta@halden.example"],"domains":[],"aliases":[],
       "company":"e-8hz1p0qq","folders":[],"named_by":"auto","hidden":false,"created_at":"2026-10-21T09:00:00Z","extra":1},
      {"id":"e-8hz1p0qq","kind":"company","name":"Halden Works","emails":[],"domains":["halden.example"],"aliases":["Halden"],
       "company":null,"folders":["f-3k9xq2ma"],"named_by":"user","hidden":false,"created_at":"2026-10-21T09:00:00Z"}],
     "attendees":{"halden-kickoff":[{"name":"Marta Velin","email":"marta@halden.example"}]},
     "owner_emails":["owner@example.com"],
     "links":{"conv-20261012-0930-halden":["e-8hz1p0qq"]},
     "unlinks":{},
     "dismissed":{"e-3k9xq2ma":["adhoc-20261017-1415-room"]},
     "merged":{"e-old00001":"e-3k9xq2ma"},
     "something_new":{"a":1}}
    """

    func testCodecRoundTripOfTheSpecExample() throws {
        let file = try PeopleCodec.decode(Data(specExample.utf8))
        XCTAssertEqual(file.entities.count, 2)
        XCTAssertEqual(file.entities[0].name, "Marta Velin")
        XCTAssertEqual(file.entities[0].company, "e-8hz1p0qq")
        XCTAssertEqual(file.entities[1].kind, .company)
        XCTAssertEqual(file.entities[1].namedBy, "user")
        XCTAssertEqual(file.entities[1].domains, ["halden.example"])
        XCTAssertEqual(file.attendees["halden-kickoff"]?.first?.email, "marta@halden.example")
        XCTAssertEqual(file.ownerEmails, ["owner@example.com"])
        XCTAssertEqual(file.links["conv-20261012-0930-halden"], ["e-8hz1p0qq"])
        XCTAssertEqual(file.dismissed["e-3k9xq2ma"], ["adhoc-20261017-1415-room"])
        XCTAssertEqual(file.merged["e-old00001"], "e-3k9xq2ma")
        let back = try PeopleCodec.decode(PeopleCodec.encode(file))
        XCTAssertEqual(back, file, "unknown keys are ignored and the rest round-trips")
        let text = String(decoding: try PeopleCodec.encode(file), as: UTF8.self)
        XCTAssertTrue(text.contains("\"named_by\"") && text.contains("\"created_at\"") && text.contains("\"owner_emails\""), "snake_case on disk")
    }

    func testStoreReadsAndWritesTheFile() throws {
        try FileManager.default.createDirectory(at: env.paths.base, withIntermediateDirectories: true)
        try Data(specExample.utf8).write(to: env.paths.people)
        let store = env.store()
        XCTAssertEqual(store.file.entities.count, 2)
        XCTAssertNil(store.notice)
        store.setHidden("e-3k9xq2ma", true)
        let onDisk = try PeopleCodec.decode(Data(contentsOf: env.paths.people))
        XCTAssertTrue(onDisk.entities[0].hidden)
    }

    func testGarbageFileIsSetAsideWithANote() throws {
        try FileManager.default.createDirectory(at: env.paths.base, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: env.paths.people)
        let store = env.store()
        XCTAssertTrue(store.file.entities.isEmpty)
        XCTAssertNotNil(store.notice)
        let names = try FileManager.default.contentsOfDirectory(atPath: env.paths.base.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("people.json.unreadable-") }, "\(names)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.people.path))
    }

    // MARK: names

    private func twoEntities() throws -> EntityStore {
        let store = env.store()
        store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "s1")
        store.reconcile(folders: FoldersFile(), sessions: [try env.session("s1")])
        return store
    }

    func testNamesAreValidated() throws {
        let store = try twoEntities()
        let marta = try XCTUnwrap(store.file.entity(named: "Marta Velin", .person)).id
        XCTAssertThrowsError(try store.rename(marta, to: "   ")) { XCTAssertEqual($0 as? EntityError, .emptyName) }
        XCTAssertThrowsError(try store.rename(marta, to: String(repeating: "x", count: 81))) { XCTAssertEqual($0 as? EntityError, .tooLong) }
        try store.rename(marta, to: String(repeating: "x", count: 80))
        try store.rename(marta, to: "Marta Velin")
        // Another person with the name folded the same is refused; a company of that name is not.
        store.recordAttendees([Attendee(name: "Joe Arkwright", email: "joe@halden.example")], owner: nil, session: "s1")
        store.reconcile(folders: FoldersFile(), sessions: [HomeSession.load(name: "s1", root: env.sessionsRoot)])
        let joe = try XCTUnwrap(store.file.entity(named: "Joe Arkwright")).id
        XCTAssertThrowsError(try store.rename(joe, to: "MARTA VELIN")) {
            XCTAssertEqual($0 as? EntityError, .duplicateName(kind: .person, name: "MARTA VELIN"))
        }
        let company = try XCTUnwrap(store.file.entity(named: "Halden", .company)).id
        try store.rename(company, to: "Marta Velin")
        XCTAssertEqual(store.resolve(id: company)?.namedBy, "user")
        XCTAssertEqual(store.file.entities.filter { $0.name == "Marta Velin" }.count, 2)
    }

    func testRenameTurnsAnAutoNameIntoAUserName() throws {
        let store = try twoEntities()
        let marta = try XCTUnwrap(store.file.entity(named: "Marta Velin", .person))
        XCTAssertEqual(marta.namedBy, "auto")
        try store.rename(marta.id, to: "M. Velin")
        XCTAssertEqual(store.resolve(id: marta.id)?.namedBy, "user")
    }

    // MARK: kind

    func testChangeKind() throws {
        let store = env.store()
        var file = PeopleFile()
        file.entities = [
            MemoryEntity(id: "e-1", kind: .person, name: "Marta Velin", emails: ["marta@halden.example"], company: "e-2", createdAt: env.when),
            MemoryEntity(id: "e-2", kind: .company, name: "Halden", domains: ["halden.example"], createdAt: env.when),
            MemoryEntity(id: "e-3", kind: .company, name: "Marta Velin", createdAt: env.when),
        ]
        store.restore(file)
        try store.setKind("e-2", .person)
        let e2 = try XCTUnwrap(store.resolve(id: "e-2"))
        XCTAssertEqual(e2.kind, .person)
        XCTAssertEqual(e2.domains, [])
        XCTAssertEqual(e2.aliases, ["halden.example"], "a domain is not a person's: it becomes an alias")
        XCTAssertNil(store.resolve(id: "e-1")?.company, "people of a company that stopped being one lose it")
        // A person becoming a company keeps its emails; a name taken in the target kind is refused.
        XCTAssertThrowsError(try store.setKind("e-1", .company)) { XCTAssertEqual($0 as? EntityError, .duplicateName(kind: .company, name: "Marta Velin")) }
        try store.rename("e-3", to: "Velin Consulting")
        try store.setKind("e-1", .company)
        XCTAssertEqual(store.resolve(id: "e-1")?.emails, ["marta@halden.example"])
    }

    // MARK: merge, snapshot

    private func mergeFixture() -> PeopleFile {
        var f = PeopleFile()
        f.entities = [
            MemoryEntity(id: "e-a", kind: .person, name: "Marta Velin", emails: ["marta@halden.example"], aliases: ["MV"], folders: ["f-1"], company: nil, createdAt: env.when),
            MemoryEntity(id: "e-b", kind: .person, name: "M. Velin", emails: ["m.velin@halden.example"], aliases: ["Marta"], folders: ["f-2"], company: "e-c", createdAt: env.when),
            MemoryEntity(id: "e-c", kind: .company, name: "Halden Works", domains: ["halden.example"], createdAt: env.when),
            MemoryEntity(id: "e-d", kind: .person, name: "Joe Arkwright", emails: ["joe@halden.example"], company: "e-c", createdAt: env.when),
        ]
        f.links = ["s1": ["e-b", "e-d"], "s2": ["e-a", "e-b"]]
        f.unlinks = ["s3": ["e-b"]]
        f.dismissed = ["e-b": ["s4"], "e-a": ["s5"], "e-d": ["e-b"]]
        f.merged = ["e-old": "e-b"]
        return f
    }

    func testMergeUnionsAndRedirects() throws {
        let store = env.store()
        store.restore(mergeFixture())
        let before = store.snapshot()
        try store.merge("e-b", into: "e-a")
        let a = try XCTUnwrap(store.resolve(id: "e-a"))
        XCTAssertEqual(a.emails, ["marta@halden.example", "m.velin@halden.example"])
        XCTAssertEqual(a.aliases, ["MV", "Marta", "M. Velin"], "the loser's aliases and name")
        XCTAssertEqual(a.folders, ["f-1", "f-2"])
        XCTAssertEqual(a.company, "e-c", "the survivor takes the loser's company when it has none")
        XCTAssertNil(store.file.entities.first { $0.id == "e-b" })
        XCTAssertEqual(store.file.links["s1"], ["e-a", "e-d"])
        XCTAssertEqual(store.file.links["s2"], ["e-a"])
        XCTAssertEqual(store.file.unlinks["s3"], ["e-a"])
        XCTAssertEqual(store.file.dismissed["e-a"], ["s5", "s4"])
        XCTAssertEqual(store.file.dismissed["e-d"], ["e-a"])
        XCTAssertEqual(store.resolve(id: "e-b")?.id, "e-a", "the merged redirect resolves")
        XCTAssertEqual(store.resolve(id: "e-old")?.id, "e-a", "and an older redirect follows it")
        XCTAssertEqual(store.resolvedID("e-old"), "e-a")
        // Restoring the snapshot brings the exact file back, in memory and on disk.
        store.restore(before)
        XCTAssertEqual(store.file, before)
        XCTAssertEqual(try PeopleCodec.decode(Data(contentsOf: env.paths.people)), before)
    }

    func testMergeAcrossKindsThrows() throws {
        let store = env.store()
        store.restore(mergeFixture())
        XCTAssertThrowsError(try store.merge("e-a", into: "e-c")) { XCTAssertEqual($0 as? EntityError, .crossKind) }
        XCTAssertThrowsError(try store.merge("e-a", into: "e-missing")) { XCTAssertEqual($0 as? EntityError, .notFound) }
        XCTAssertEqual(store.file, mergeFixture(), "nothing changed")
    }

    func testUndoRestoresTheWholeFile() throws {
        let store = env.store()
        store.restore(mergeFixture())
        let um = UndoManager()
        um.groupsByEvent = false
        let before = store.snapshot()
        um.beginUndoGrouping()
        try store.apply("Merge", undoManager: um) { try $0.merge("e-b", into: "e-a") }
        um.endUndoGrouping()
        XCTAssertNotEqual(store.file, before)
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, "Merge")
        um.undo()
        XCTAssertEqual(store.file, before)
        XCTAssertTrue(um.canRedo)
        um.redo()
        XCTAssertNil(store.file.entities.first { $0.id == "e-b" })
    }

    func testAChangeThatChangesNothingRegistersNoUndo() throws {
        let store = env.store()
        store.restore(mergeFixture())
        let um = UndoManager()
        um.groupsByEvent = false
        // No group is open: an undo registered here would raise. Nothing changes, so nothing is registered.
        try store.apply("Hide", undoManager: um) { $0.setHidden("e-a", false) }
        XCTAssertFalse(um.canUndo)
    }

    // MARK: links

    func testLinkUnlinkDismissAndPruning() throws {
        var alive: Set<String> = ["s1", "s2"]
        let store = env.store(sessionExists: { alive.contains($0) })
        store.restore(mergeFixture())
        store.link("s1", to: "e-a")
        XCTAssertEqual(store.file.links["s1"], ["e-b", "e-d", "e-a"])
        store.unlink("s1", from: "e-a")
        XCTAssertEqual(store.file.links["s1"], ["e-b", "e-d"])
        XCTAssertEqual(store.file.unlinks["s1"], ["e-a"])
        store.link("s1", to: "e-a")
        XCTAssertNil(store.file.unlinks["s1"], "a link takes the entity off the unlinks")
        store.dismiss("s2", for: "e-a")
        XCTAssertEqual(store.file.dismissed["e-a"], ["s2"], "s5 does not exist, so the first write dropped it")
        // A write drops entries of sessions that are gone; recorded attendees stay.
        store.recordAttendees([PeopleEnv.marta], owner: nil, session: "gone")
        alive = ["s1"]
        store.setHidden("e-d", true)
        XCTAssertNil(store.file.links["s2"])
        XCTAssertNil(store.file.unlinks["s3"])
        XCTAssertNil(store.file.dismissed["e-a"], "turned-down sessions that are gone are dropped")
        XCTAssertEqual(store.file.dismissed["e-d"], ["e-b"], "a turned-down merge suggestion (an entity id) stays")
        XCTAssertEqual(store.file.attendees["gone"]?.count, 1, "recorded attendees are never pruned")
    }

    // MARK: attendees

    func testRecordAttendeesDropsTheOwnerAndRoomsAndLearnsOwnerEmails() throws {
        let store = env.store()
        var file = PeopleFile()
        file.ownerEmails = ["dana@work.example"]
        store.restore(file)
        let room = Attendee(name: "Room 4", email: "c_abc@resource.calendar.google.com")
        let group = Attendee(name: nil, email: "team@group.calendar.google.com")
        let bot = Attendee(name: "Calendar", email: "noreply@halden.example")
        let work = Attendee(name: "Dana", email: "Dana@Work.Example")
        let other = Attendee(name: "Dana", email: "dana@home.example")
        store.recordAttendees([PeopleEnv.marta, PeopleEnv.owner, room, group, bot, work, other, Attendee(name: "Joe Arkwright", email: nil)],
                              owner: PeopleEnv.owner, session: "halden-kickoff")
        let recorded = try XCTUnwrap(store.file.attendees["halden-kickoff"])
        XCTAssertEqual(recorded.map(\.email), ["marta@halden.example", "dana@home.example", nil],
                       "the owner (currentUser and owner_emails), rooms, group calendars and no-reply senders are dropped")
        XCTAssertEqual(store.file.ownerEmails, ["dana@work.example", "owner@example.com"], "a new owner address is remembered")
        // Only the owner on the invite: nothing is recorded.
        store.recordAttendees([PeopleEnv.owner], owner: PeopleEnv.owner, session: "solo")
        XCTAssertNil(store.file.attendees["solo"])
    }

    func testBackfillRecordsMappedSessionsAndIgnoresMissingEvents() async throws {
        let store = env.store()
        let session = try env.session("halden-kickoff")
        _ = try env.session("old-one")
        let event = env.event(attendees: [PeopleEnv.marta])
        let recorded = await store.backfill(eventSessions: ["ev-Halden weekly": "halden-kickoff", "ev-missing": "old-one", "ev-x": "no-such-folder"],
                                            lookup: { id in id == event.id ? event : nil })
        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(store.file.attendees["halden-kickoff"]?.first?.email, "marta@halden.example")
        XCTAssertNil(store.file.attendees["old-one"], "a missed event stays unlinked")
        XCTAssertEqual(store.file.ownerEmails, ["owner@example.com"])
        // A session that has attendees already is not asked again.
        var asked = 0
        _ = await store.backfill(eventSessions: ["ev-Halden weekly": "halden-kickoff"], lookup: { _ in asked += 1; return event })
        XCTAssertEqual(asked, 0)
        _ = session
    }

    func testAChangeTellsTheMemoryIndex() throws {
        let store = env.store()
        var n = 0
        store.onChange = { n += 1 }
        store.restore(mergeFixture())
        XCTAssertEqual(n, 1)
        store.setHidden("e-a", true)
        XCTAssertEqual(n, 2)
        store.setHidden("e-a", true)
        XCTAssertEqual(n, 2, "no change, no write")
    }
}
