import Foundation
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// The Ask panel in the memory scopes (memory spec 2.3, 3.4, 3.7, 5.2): the first line each scope sends, object citations, the chat and
/// spend files of the memory folder, the Scope menu, the reveal of a cited line. The brain is a scripted stand-in; nothing is paid.
@MainActor
final class AskMemoryScopeTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!
    private var defaultsCleanup: (() -> Void)?

    override func setUp() async throws { scratch = try MemoryFixtures.scratch() }
    override func tearDown() async throws {
        scratch.remove()
        defaultsCleanup?()
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await eventually(5, condition)
        XCTAssertTrue(ok, "timed out waiting", file: file, line: line)
    }

    private struct Rig {
        var controller: AskScopeController
        var store: EntityStore
        var model: HomeSessionsModel
        var brains: MemBox<[FakeAskBrain]>
        var marta: MemoryEntity
        var company: MemoryEntity
    }

    /// A controller over the fixture sessions, with Marta Velin and Halden Works made from two recorded invites.
    private func rig(memoryEnabled: Bool = false) throws -> Rig {
        let (defaults, cleanup) = FolderFixtures.defaults()
        defaultsCleanup = cleanup
        let model = HomeSessionsModel(root: scratch.sessions, defaults: defaults)
        model.reload()
        var n = 0
        let store = EntityStore(paths: scratch.paths, sessionsRoot: scratch.sessions, makeID: { n += 1; return "e-" + String(format: "%08d", n) })
        store.context = { [unowned model] in (model.folders.file, model.sessions) }
        store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "halden-kickoff")
        store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "halden-weekly-prep")
        let marta = try XCTUnwrap(store.file.entity(named: "Marta Velin", .person))
        let company = try XCTUnwrap(store.file.entity(named: "Halden", .company))
        let memory = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                                   makeBrain: { throw NSError(domain: "test", code: 1) }, enabled: memoryEnabled)
        let brains = MemBox<[FakeAskBrain]>([])
        let ask = AskSession(makeBrain: { let b = FakeAskBrain(); brains.value.append(b); return b })
        let c = AskScopeController(ask: ask, memory: memory, people: store)
        c.ownerName = { "Dana" }
        c.useMeProfile = { false }
        c.sessions = { [unowned model] in model.sessions }
        c.folders = { [unowned model] in model.folders.file }
        return Rig(controller: c, store: store, model: model, brains: brains, marta: marta, company: company)
    }

    // MARK: the first line

    func testMemoryAskStartLineGoldenForAllAndEntity() {
        let all = MemoryAskContext(scope: .all, scopeName: "", ownerName: "Dana", db: URL(fileURLWithPath: "/tmp/memory/index.sqlite"),
                                   chat: URL(fileURLWithPath: "/tmp/memory/chats/all.jsonl"), spendDir: URL(fileURLWithPath: "/tmp/memory"), meCore: nil)
        XCTAssertEqual(all.startLine(model: .sonnet),
                       #"{"chat":"/tmp/memory/chats/all.jsonl","db":"/tmp/memory/index.sqlite","me":null,"model":"sonnet","owner_name":"Dana","scope":{"id":null,"kind":"all","name":null,"sessions":null},"type":"memory_ask_start"}"#)
        let entity = MemoryAskContext(scope: .entity("e-8hz1p0qq"), scopeName: "Marta Velin", ownerName: "Dana", db: URL(fileURLWithPath: "/tmp/memory/index.sqlite"),
                                      chat: URL(fileURLWithPath: "/tmp/memory/chats/e-8hz1p0qq.jsonl"), spendDir: URL(fileURLWithPath: "/tmp/memory"),
                                      meCore: URL(fileURLWithPath: "/tmp/profile/me.md"), sessions: ["halden-kickoff", "halden-pilot-review"])
        XCTAssertEqual(entity.startLine(model: .opus),
                       #"{"chat":"/tmp/memory/chats/e-8hz1p0qq.jsonl","db":"/tmp/memory/index.sqlite","me":{"core":"/tmp/profile/me.md"},"model":"opus","owner_name":"Dana","scope":{"id":"e-8hz1p0qq","kind":"entity","name":"Marta Velin","sessions":["halden-kickoff","halden-pilot-review"]},"type":"memory_ask_start"}"#)
    }

    func testTheControllerBuildsContextsFromTheMemoryFolderAndTheResolver() throws {
        let r = try rig()
        let all = try XCTUnwrap(r.controller.memoryContext(for: .all))
        XCTAssertEqual(all.db, scratch.paths.db)
        XCTAssertEqual(all.chat, scratch.paths.chat(named: "all"))
        XCTAssertEqual(all.spendDir, scratch.memory)
        XCTAssertNil(all.meCore, "the profile toggle is off")
        let e = try XCTUnwrap(r.controller.memoryContext(for: .entity(r.marta.id)))
        XCTAssertEqual(e.chat, scratch.paths.chat(named: r.marta.id))
        XCTAssertEqual(e.scopeName, "Marta Velin")
        let expected = EntityResolver.sessions(of: r.marta.id, file: r.store.file, folders: r.model.folders.file, sessions: r.model.sessions).map(\.name)
        XCTAssertEqual(e.sessions, expected)
        XCTAssertTrue(e.sessions.contains("halden-kickoff"))
        XCTAssertFalse(e.sessions.contains("corvo-design-call"))
        XCTAssertNil(r.controller.memoryContext(for: .entity("e-nobody")), "an entity that is gone has no context")
        XCTAssertNil(r.controller.memoryContext(for: .session("halden-kickoff")))
        // The profile toggle on and the file there: the me layer goes along.
        let me = scratch.top.appendingPathComponent("me.md")
        try MemoryFixtures.write("# Me\n", to: me)
        r.controller.useMeProfile = { true }
        r.controller.meCore = { me }
        XCTAssertEqual(r.controller.memoryContext(for: .all)?.meCore, me)
    }

    // MARK: events

    func testAskDoneWithObjectCitationsFillsSourcesAndLeavesCitationsEmpty() throws {
        let line = #"{"type":"ask_done","id":"a3","q":"q3","model":"claude-sonnet-5-5","usage":{"input":10,"output":5},"cost_usd":0.041,"ms_first_token":2100,"ms_total":5200,"stop_reason":"end_turn","cost_estimated":false,"excerpt_tokens":15820,"citations":[{"key":"sk3f9qa","session":"halden-kickoff","title":"Halden Kickoff","date":"2026-10-19T17:00:00+02:00","kind":"turn","stamp":"12:34","speaker":"Marta","text":"We'd need the pilot plan by Friday."},{"key":"sp0m2vx","session":"halden-pilot-review","title":"Halden Pilot Review","date":"2026-10-24T10:00:00+02:00","kind":"summary","stamp":null,"speaker":null,"text":"Actions: Send the revised budget"}]}"#
        guard case .done(let d)? = AskEvent.parse(line) else { return XCTFail("not an ask_done") }
        XCTAssertEqual(d.citations, [])
        XCTAssertEqual(d.excerptTokens, 15820)
        XCTAssertEqual(d.sources.map(\.key), ["sk3f9qa", "sp0m2vx"])
        XCTAssertEqual(d.sources[0], AskSource(key: "sk3f9qa", session: "halden-kickoff", title: "Halden Kickoff",
                                               date: BriefLayout.date(from: "2026-10-19T17:00:00+02:00"), kind: "turn", stamp: "12:34",
                                               speaker: "Marta", text: "We'd need the pilot plan by Friday."))
        XCTAssertEqual(d.sources[1].kind, "summary")
        XCTAssertNil(d.sources[1].stamp)
        XCTAssertEqual(d.sources[0].form, "12:34")
        XCTAssertEqual(d.sources[1].form, "summary")
    }

    func testAskDoneWithStringCitationsIsAsBefore() {
        let line = #"{"type":"ask_done","id":"a1","q":"q1","model":"m","usage":{},"cost_usd":0.01,"stop_reason":"end_turn","citations":["0:22","1:02:05"]}"#
        guard case .done(let d)? = AskEvent.parse(line) else { return XCTFail("not an ask_done") }
        XCTAssertEqual(d.citations, ["0:22", "1:02:05"])
        XCTAssertEqual(d.sources, [])
    }

    func testChatLogReadsAMemoryChatWithObjectCitationsAndAReset() throws {
        let chat = """
        {"type":"q","id":"q1","t":"x","text":"Before the reset","model":"m","scope":"all"}
        {"type":"a","id":"a1","q":"q1","t":"x","text":"Old [sk3f9qa 12:34]","model":"m","usage":{},"cost_usd":0.5,"citations":[{"key":"sk3f9qa","session":"halden-kickoff","title":"Halden Kickoff","date":"2026-10-19T17:00:00+02:00","kind":"turn","stamp":"12:34","speaker":"Marta","text":"x"}],"stop_reason":"end_turn","context":"memory","excerpt_tokens":100}
        {"type":"reset","t":"x"}
        {"type":"q","id":"q2","t":"x","text":"After","model":"m","scope":"all"}
        {"type":"a","id":"a2","q":"q2","t":"x","text":"New [sk3f9qa 12:34] and [sp0m2vx summary].","model":"claude-sonnet-5-5","usage":{"input":1},"cost_usd":0.04,"ms_total":4200,"citations":[{"key":"sk3f9qa","session":"halden-kickoff","title":"Halden Kickoff","date":"2026-10-19T17:00:00+02:00","kind":"turn","stamp":"12:34","speaker":"Marta","text":"We'd need the pilot plan by Friday."},{"key":"sp0m2vx","session":"halden-pilot-review","title":"Halden Pilot Review","date":"2026-10-24T10:00:00+02:00","kind":"summary","stamp":null,"speaker":null,"text":"Actions: Send the revised budget"}],"stop_reason":"end_turn","context":"memory","excerpt_tokens":15820}
        """
        let url = scratch.memory.appendingPathComponent("chats/all.jsonl")
        try MemoryFixtures.write(chat, to: url)
        let loaded = ChatLog.load(url: url)
        XCTAssertEqual(loaded.turns.map(\.question), ["After"], "the pair before the reset is hidden")
        XCTAssertEqual(loaded.nextIndex, 3)
        let a = try XCTUnwrap(loaded.turns[0].answer)
        XCTAssertEqual(a.citations, [])
        XCTAssertEqual(a.sources.map(\.session), ["halden-kickoff", "halden-pilot-review"])
        XCTAssertEqual(a.sources[0].speaker, "Marta")
        XCTAssertEqual(a.excerptTokens, 15820)
        XCTAssertEqual(ChatLog.load(url: scratch.memory.appendingPathComponent("chats/none.jsonl")).turns, [])
    }

    // MARK: the process, the chat, the spend

    func testAMemoryScopeStreamsAndRecordsItsCostInTheMemoryFolderNotInASession() async throws {
        let r = try rig()
        XCTAssertTrue(r.controller.openMemory(.all))
        await wait { !r.brains.value.isEmpty }
        let b = try XCTUnwrap(r.brains.value.first)
        let first = MemoryFixtures.object(b.sent[0])
        XCTAssertEqual(first["type"] as? String, "memory_ask_start", "the first line decides the mode")
        XCTAssertEqual((first["scope"] as? [String: Any])?["kind"] as? String, "all")
        XCTAssertEqual(first["chat"] as? String, scratch.paths.chat(named: "all").path)

        let ask = r.controller.ask
        ask.send("What did I promise?")
        XCTAssertEqual(MemoryFixtures.object(try XCTUnwrap(b.sent.last))["type"] as? String, "ask")
        b.push(["type": "ask_delta", "q": "q1", "text": "You promised the budget "])
        b.push(["type": "ask_delta", "q": "q1", "text": "[sk3f9qa 12:34]."])
        await wait { ask.turns.first?.partial == "You promised the budget [sk3f9qa 12:34]." }
        b.push(["type": "ask_done", "id": "a1", "q": "q1", "model": "claude-sonnet-5-5", "usage": ["input": 5, "output": 9], "cost_usd": 0.041,
                "stop_reason": "end_turn", "excerpt_tokens": 100,
                "citations": [["key": "sk3f9qa", "session": "halden-kickoff", "title": "Halden Kickoff", "date": "2026-10-19T17:00:00+02:00", "kind": "turn",
                               "stamp": "12:34", "speaker": "Marta", "text": "We'd need the pilot plan by Friday."]]])
        await wait { ask.turns.first?.phase == .answered }
        XCTAssertEqual(ask.turns[0].answer?.sources.first?.session, "halden-kickoff")

        let runs = SpendLedger.runs(sessionDir: scratch.memory)
        XCTAssertEqual(runs.map(\.kind), ["ask"], "memory/spend.json takes the cost")
        XCTAssertEqual(runs[0].costUSD, 0.041, accuracy: 1e-9)
        for s in ["halden-kickoff", "corvo-design-call", "halden-weekly-prep"] {
            XCTAssertTrue(SpendLedger.runs(sessionDir: scratch.sessions.appendingPathComponent(s)).isEmpty, "\(s) is not charged")
        }
    }

    // MARK: scopes

    func testTheScopeMenuListsThisMeetingTheSessionsPeopleAndAllMeetings() throws {
        let r = try rig()
        let kickoff = try XCTUnwrap(r.model.session(named: "halden-kickoff"))
        let withAsk = r.controller.choices(selected: kickoff, availability: .available)
        XCTAssertEqual(withAsk.map(\.scope), [.session("halden-kickoff"), .entity(r.marta.id), .entity(r.company.id), .all])
        XCTAssertEqual(withAsk.map(\.title), [L10n.tr("This meeting"), "Marta Velin", "Halden", L10n.tr("All meetings")])
        let noAsk = r.controller.choices(selected: kickoff, availability: .noTranscript)
        XCTAssertEqual(noAsk.map(\.scope), [.entity(r.marta.id), .entity(r.company.id), .all], "no This meeting when the session offers no Ask")
        let corvo = try XCTUnwrap(r.model.session(named: "corvo-design-call"))
        XCTAssertEqual(r.controller.choices(selected: corvo, availability: .available).last?.scope, .all)
        XCTAssertEqual(r.controller.choices(selected: nil, availability: .hidden).map(\.scope), [.all])
    }

    func testChoosingAScopeEndsTheProcessAndStartsANewOneWithTheNewFirstLine() async throws {
        let r = try rig()
        r.controller.openMemory(.all)
        await wait { r.brains.value.count == 1 }
        XCTAssertEqual(r.controller.scope, .all)
        r.controller.change(to: .entity(r.marta.id), sessionContext: nil)
        await wait { r.brains.value.count == 2 }
        let second = try XCTUnwrap(r.brains.value.last)
        let scope = try XCTUnwrap(MemoryFixtures.object(second.sent[0])["scope"] as? [String: Any])
        XCTAssertEqual(scope["kind"] as? String, "entity")
        XCTAssertEqual(scope["id"] as? String, r.marta.id)
        XCTAssertEqual(scope["name"] as? String, "Marta Velin")
        await wait { r.brains.value[0].closed }
        XCTAssertEqual(r.controller.scope, .entity(r.marta.id))

        // Back to one meeting: ask_start, the session's own chat file.
        let ctx = AskContext(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana", title: "Halden Kickoff",
                             date: Date(), meCore: nil, rows: [])
        r.controller.change(to: .session("halden-kickoff"), sessionContext: ctx)
        await wait { r.brains.value.count == 3 }
        XCTAssertEqual(MemoryFixtures.object(r.brains.value[2].sent[0])["type"] as? String, "ask_start")
    }

    func testTheMemoryScopeIsRememberedAndOnlyMemoryScopes() async throws {
        let r = try rig()
        var store = r.controller.store
        let (defaults, cleanup) = FolderFixtures.defaults()
        defer { cleanup() }
        store.defaults = defaults
        r.controller.store = store
        XCTAssertEqual(r.controller.store.scope, .all)
        r.controller.openMemory(.entity(r.marta.id))
        XCTAssertEqual(r.controller.store.scope, .entity(r.marta.id))
        r.controller.close()
        XCTAssertEqual(r.controller.store.scope, .entity(r.marta.id), "closing keeps it")
        let ctx = AskContext(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana", title: "t", date: Date(), meCore: nil, rows: [])
        r.controller.open(session: ctx)
        XCTAssertEqual(r.controller.store.scope, .entity(r.marta.id), "Ask this meeting does not overwrite it")
    }

    func testSelectingAnotherSessionClosesAskThisMeetingButNotAMemoryScope() async throws {
        let r = try rig()
        let ctx = AskContext(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana", title: "t", date: Date(), meCore: nil, rows: [])
        r.controller.open(session: ctx)
        XCTAssertTrue(r.controller.closesOnSelectionChange, "the 5F rule stays")
        r.controller.close()
        XCTAssertFalse(r.controller.closesOnSelectionChange)
        r.controller.openMemory(.all)
        XCTAssertFalse(r.controller.closesOnSelectionChange)
        r.controller.openMemory(.entity(r.marta.id))
        XCTAssertFalse(r.controller.closesOnSelectionChange)
    }

    func testTheEmptyStatesNameTheScope() throws {
        let r = try rig()
        XCTAssertNil(r.controller.emptyText(for: .all))
        XCTAssertNil(r.controller.emptyText(for: .entity(r.marta.id)))
        // Everything trashed: no held meeting in scope.
        r.controller.sessions = { [] }
        XCTAssertEqual(r.controller.emptyText(for: .all), "Verse has no past meetings to search yet.")
        XCTAssertEqual(r.controller.emptyText(for: .entity(r.marta.id)), "No meetings with Marta Velin are in Verse yet.")
    }

    // MARK: citations

    func testSourcesOpenTheRightPlace() {
        XCTAssertEqual(AskScopeController.reveal(for: AskSource(key: "sk3f9qa", session: "s", title: "t", kind: "turn", stamp: "12:34")), .stamp("12:34"))
        XCTAssertEqual(AskScopeController.reveal(for: AskSource(key: "sk3f9qa", session: "s", title: "t", kind: "summary")), .summary)
        XCTAssertEqual(AskScopeController.reveal(for: AskSource(key: "sk3f9qa", session: "s", title: "t", kind: "prep")), SessionReveal.none)
        XCTAssertEqual(AskScopeController.reveal(for: AskSource(key: "sk3f9qa", session: "s", title: "t", kind: "chat")), SessionReveal.none)
    }

    func testARevealCallsTheJumpWithTheRowOfTheStampAndAMissingStampIsSaid() throws {
        let doc = TranscriptDocument.load(sessionDir: scratch.sessions.appendingPathComponent("halden-kickoff"), ownerName: "Dana")
        let jump = TranscriptJump()
        let row = try XCTUnwrap(doc.row(forStamp: "0:24"))
        XCTAssertEqual(SessionRevealOutcome.perform(.stamp("0:24"), document: doc, jump: jump), .revealed)
        XCTAssertEqual(jump.rowID, row.id, "the jump target is the fixture row")
        let serial = jump.serial
        XCTAssertEqual(SessionRevealOutcome.perform(.stamp("59:59"), document: doc, jump: jump), .missing, "the page then shows the note")
        XCTAssertEqual(jump.serial, serial, "nothing scrolled")
        XCTAssertEqual(SessionRevealOutcome.perform(.summary, document: doc, jump: jump), .summary)
        XCTAssertEqual(SessionRevealOutcome.perform(.none, document: doc, jump: jump), SessionRevealOutcome.none)
        XCTAssertEqual(SessionRevealOutcome.perform(.stamp("0:24"), document: nil, jump: jump), .missing, "no transcript read yet")
    }

    /// A router request to open a session at a line reaches the page as a request with a fresh serial each time.
    func testTheRouterTurnsEveryCitationIntoANewRequest() {
        let router = HomeRouter()
        router.showSession("halden-kickoff", reveal: .stamp("0:24"))
        let first = router.revealRequest
        router.showSession("halden-kickoff", reveal: .stamp("0:24"))
        XCTAssertEqual(router.page, .sessions)
        XCTAssertEqual(router.selectedSession, "halden-kickoff")
        XCTAssertNotEqual(first?.serial, router.revealRequest?.serial)
        router.showAsk(.entity("e-1"))
        XCTAssertEqual(router.askRequest, .entity("e-1"))
    }

    func testASourceInTheTrashDoesNothingWhenOpened() {
        let opened = MemBox<[String]>([])
        let env = AskMemoryEnv(available: ["halden-kickoff"], onSource: { opened.value.append($0.session) })
        env.open(AskSource(key: "sk3f9qa", session: "halden-kickoff", title: "Halden Kickoff", kind: "turn", stamp: "12:34"))
        env.open(AskSource(key: "sg7t1mn", session: "gone-session", title: "Gone", kind: "turn", stamp: "4:02"))
        XCTAssertEqual(opened.value, ["halden-kickoff"])
    }
}
