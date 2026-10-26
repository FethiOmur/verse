import AppKit
import Foundation
import SwiftUI
import VerseMeet
import VerseTurns
@testable import VerseUI
import XCTest

/// Where the brief shows and when it is made (memory spec 2.4, 5.3, 5.4): the automatic brief after a session is prepared, the plate
/// before a prepared meeting, the disclosure on a past one, the Up next caption and Brief button. The brief process is scripted.
@MainActor
final class BriefPlacementTests: XCTestCase {
    private var scratch: MemoryFixtures.Scratch!
    private var cleanup: (() -> Void)?

    override func setUp() async throws { scratch = try MemoryFixtures.scratch() }
    override func tearDown() async throws {
        scratch.remove()
        cleanup?()
    }

    private struct Rig {
        var model: HomeSessionsModel
        var store: EntityStore
        var memory: MemoryService
        var center: AutoBriefCenter
        var brains: MemBox<[ScriptedBriefBrain]>
        var env: SessionMemoryEnvironment
    }

    private func rig(_ mode: ScriptedBriefBrain.Mode = .done(cost: 0.05)) throws -> Rig {
        let (defaults, done) = FolderFixtures.defaults()
        cleanup = done
        let model = HomeSessionsModel(root: scratch.sessions, defaults: defaults)
        var n = 0
        let store = EntityStore(paths: scratch.paths, sessionsRoot: scratch.sessions, makeID: { n += 1; return "e-" + String(format: "%08d", n) })
        store.context = { [unowned model] in (model.folders.file, model.sessions) }
        // Marta Velin was at the kickoff, which was held.
        store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "halden-kickoff")
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let memory = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                                   makeBrain: { let b = ScriptedBriefBrain(mode); brains.value.append(b); return b })
        let center = AutoBriefCenter(memory: memory, people: store, sessions: model)
        center.announce = { _ in }
        let env = SessionMemoryEnvironment(memory: memory, people: store, sessions: model, router: HomeRouter(), briefs: center)
        return Rig(model: model, store: store, memory: memory, center: center, brains: brains, env: env)
    }

    private func event(_ title: String = "Halden weekly", with guests: [Attendee]) -> MeetingEvent {
        MeetingEvent(id: "ev-1", title: title, start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_800),
                     attendees: guests + [PeopleEnv.owner], currentUser: PeopleEnv.owner)
    }

    // MARK: the automatic brief

    func testPreparingAnEventWhoseGuestHasAPastMeetingMakesOneBriefIntoTheNewSession() async throws {
        let r = try rig()
        let e = event(with: [PeopleEnv.marta, PeopleEnv.joe])
        // What the hook does: record the invite, then ask for the brief. The new session is the prepared one.
        r.store.recordAttendees(e.attendees, owner: e.currentUser, session: "halden-weekly-prep")
        r.model.reload()
        r.center.afterPrepare(e, session: "halden-weekly-prep")
        XCTAssertTrue(r.center.making.contains("halden-weekly-prep"), "its row says Making brief… from the moment prep ends")
        await r.center.lastTask?.value
        XCTAssertEqual(r.brains.value.count, 1, "exactly one brief")
        let line = try XCTUnwrap(r.brains.value[0].sent.first)
        let o = MemoryFixtures.object(line)
        XCTAssertEqual(o["type"] as? String, "brief_start")
        XCTAssertEqual(o["session_out"] as? String, scratch.sessions.appendingPathComponent("halden-weekly-prep").path)
        XCTAssertEqual(o["sessions"] as? [String], ["halden-kickoff"], "the new session is not its own past")
        XCTAssertEqual(o["lang"] as? String, "en", "the new session's meta.json languages[0]")
        let upcoming = try XCTUnwrap(o["upcoming"] as? [String: Any])
        XCTAssertEqual(upcoming["title"] as? String, "Halden weekly")
        XCTAssertEqual(upcoming["attendees"] as? [String], ["Marta Velin", "Joe Arkwright"])
        XCTAssertFalse(line.contains("@"), "no e-mail address reaches the brain")
        XCTAssertFalse(line.contains("halden.example"))
        XCTAssertTrue(r.center.making.isEmpty)
        XCTAssertNil(r.center.failures["halden-weekly-prep"])
    }

    func testAnEntityWithNoPastMeetingMakesNoCall() async throws {
        let r = try rig()
        let e = event("Corvo intro", with: [PeopleEnv.giulia])
        r.store.recordAttendees(e.attendees, owner: e.currentUser, session: "halden-weekly-prep")
        r.model.reload()
        r.center.afterPrepare(e, session: "halden-weekly-prep")
        await r.center.lastTask?.value
        XCTAssertTrue(r.brains.value.isEmpty, "Giulia has no past session here")
        XCTAssertTrue(r.center.making.isEmpty)
        // An event with only the owner has no primary entity either.
        r.center.afterPrepare(event("Solo", with: []), session: "halden-weekly-prep")
        XCTAssertTrue(r.brains.value.isEmpty)
    }

    func testAFailedAutomaticBriefIsKeptForTheSessionAndRetried() async throws {
        let r = try rig(.error(kind: "offline", cost: nil))
        let e = event(with: [PeopleEnv.marta])
        r.store.recordAttendees(e.attendees, owner: e.currentUser, session: "halden-weekly-prep")
        r.model.reload()
        r.center.afterPrepare(e, session: "halden-weekly-prep")
        await r.center.lastTask?.value
        XCTAssertEqual(r.center.failures["halden-weekly-prep"]?.kind, "offline")
        XCTAssertEqual(AskMessages.text(for: try XCTUnwrap(r.center.failures["halden-weekly-prep"])), "No connection. Check your network, then retry.")
        r.center.retry(session: "halden-weekly-prep")
        XCTAssertNil(r.center.failures["halden-weekly-prep"], "Retry clears it while the brief is made again")
        await r.center.lastTask?.value
        XCTAssertEqual(r.brains.value.count, 2, "Retry asked again with the same request")
        XCTAssertEqual(r.brains.value[1].sent.first, r.brains.value[0].sent.first)
    }

    func testAServiceThatIsNotEnabledStartsNothing() async throws {
        let (defaults, done) = FolderFixtures.defaults()
        cleanup = done
        let model = HomeSessionsModel(root: scratch.sessions, defaults: defaults)
        let store = EntityStore(paths: scratch.paths, sessionsRoot: scratch.sessions)
        let brains = MemBox<[ScriptedBriefBrain]>([])
        let memory = MemoryService(paths: scratch.paths, sessionsRoot: scratch.sessions, ownerName: { "Dana" },
                                   makeBrain: { let b = ScriptedBriefBrain(.done(cost: 0.05)); brains.value.append(b); return b }, enabled: false)
        let center = AutoBriefCenter(memory: memory, people: store, sessions: model)
        center.afterPrepare(event(with: [PeopleEnv.marta]), session: "halden-weekly-prep")
        XCTAssertNil(center.lastTask)
        XCTAssertTrue(brains.value.isEmpty)
    }

    // MARK: placements

    private func writeBrief(into dir: URL, newest: String, forSession: String?) throws {
        var text = try String(contentsOf: MemoryFixtures.fixturesDir.appendingPathComponent("brief.json"), encoding: .utf8)
        text = text.replacingOccurrences(of: #""newest_session": "halden-pilot-review""#, with: #""newest_session": "\#(newest)""#)
        if forSession == nil { text = text.replacingOccurrences(of: #""for_session": "halden-weekly-prep","#, with: "") }
        try MemoryFixtures.write(text, to: dir.appendingPathComponent("brief.json"))
    }

    func testAPreparedSessionWithABriefShowsBeforeThisMeetingAndAStaleOneShowsUpdate() throws {
        let r = try rig()
        let prep = scratch.sessions.appendingPathComponent("halden-weekly-prep")
        r.store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "halden-weekly-prep")
        r.model.reload()
        let s = try XCTUnwrap(r.model.session(named: "halden-weekly-prep"))
        XCTAssertTrue(SessionBriefPlacement.showsPlate(s))
        XCTAssertFalse(SessionBriefPlacement.showsDisclosure(s))
        let about = try XCTUnwrap(SessionBriefPlacement.about(s, file: r.store.file, folders: r.model.folders.file, sessions: r.model.sessions))
        XCTAssertEqual(about.past.map(\.name), ["halden-kickoff"])

        // Without a brief but with a past meeting: "You've met Marta once. Make a brief?"
        XCTAssertNil(SessionBriefPlacement.brief(for: s, entity: about.entity, paths: scratch.paths))
        XCTAssertEqual(SessionBriefPlacement.state(past: about.past, brief: nil, making: false, failure: nil), .none(pastMeetings: 1))

        // A fresh brief of its own.
        try writeBrief(into: prep, newest: "halden-kickoff", forSession: "halden-weekly-prep")
        let fresh = try XCTUnwrap(SessionBriefPlacement.brief(for: s, entity: about.entity, paths: scratch.paths))
        guard case .ready = SessionBriefPlacement.state(past: about.past, brief: fresh, making: false, failure: nil) else { return XCTFail("a current brief is ready") }

        // The fixture's brief was made from a newer meeting than the ones here: stale, with Update.
        try writeBrief(into: prep, newest: "halden-pilot-review", forSession: "halden-weekly-prep")
        let stale = try XCTUnwrap(SessionBriefPlacement.brief(for: s, entity: about.entity, paths: scratch.paths))
        guard case .stale(_, let newest) = SessionBriefPlacement.state(past: about.past, brief: stale, making: false, failure: nil) else { return XCTFail("stale") }
        XCTAssertEqual(newest.name, "halden-kickoff")

        // Making and failed states.
        XCTAssertEqual(SessionBriefPlacement.state(past: about.past, brief: stale, making: true, failure: nil), .making)
        guard case .failed(let f) = SessionBriefPlacement.state(past: about.past, brief: stale, making: false, failure: ChatFailure(kind: "offline", message: "")) else { return XCTFail("failed") }
        XCTAssertEqual(f.kind, "offline")
        // No past meeting: no plate at all.
        XCTAssertEqual(SessionBriefPlacement.state(past: [], brief: stale, making: false, failure: nil), .hidden)

        // Without its own brief a prepared session shows the latest brief of its entity.
        try FileManager.default.removeItem(at: prep.appendingPathComponent("brief.json"))
        try MemoryFixtures.write(try String(contentsOf: MemoryFixtures.fixturesDir.appendingPathComponent("brief.json"), encoding: .utf8), to: scratch.paths.brief(entity: about.entity.id))
        XCTAssertEqual(SessionBriefPlacement.brief(for: s, entity: about.entity, paths: scratch.paths)?.entity, "e-3k9xq2ma")
    }

    func testAPastSessionThatHadABriefShowsTheDisclosureNotThePlate() throws {
        let r = try rig()
        let kickoff = try XCTUnwrap(r.model.session(named: "halden-kickoff"))
        XCTAssertTrue(SessionBriefPlacement.showsDisclosure(kickoff))
        XCTAssertFalse(SessionBriefPlacement.showsPlate(kickoff))
        XCTAssertNil(BriefStore.load(sessionDir: kickoff.dir))
        try writeBrief(into: kickoff.dir, newest: "halden-kickoff", forSession: "halden-kickoff")
        XCTAssertEqual(BriefStore.load(sessionDir: kickoff.dir)?.entity, "e-3k9xq2ma")
    }

    func testTheViewsLayOutAndDraw() throws {
        _ = NSApplication.shared
        let r = try rig()
        r.store.recordAttendees([PeopleEnv.marta], owner: PeopleEnv.owner, session: "halden-weekly-prep")
        r.model.reload()
        try writeBrief(into: scratch.sessions.appendingPathComponent("halden-weekly-prep"), newest: "halden-kickoff", forSession: "halden-weekly-prep")
        try writeBrief(into: scratch.sessions.appendingPathComponent("halden-kickoff"), newest: "halden-kickoff", forSession: "halden-kickoff")
        let prep = try XCTUnwrap(r.model.session(named: "halden-weekly-prep"))
        let kickoff = try XCTUnwrap(r.model.session(named: "halden-kickoff"))
        for dark in [false, true] {
            let views: [AnyView] = [
                AnyView(SessionBriefPlate(session: prep, ownerName: "Dana", env: r.env)),
                AnyView(SessionBriefDisclosure(session: kickoff, ownerName: "Dana", env: r.env)),
                AnyView(SessionPeopleRow(session: kickoff, env: r.env)),
            ]
            for v in views {
                let host = NSHostingView(rootView: v.environment(\.homeInk, VT.Window(dark: dark)).environment(\.colorScheme, dark ? .dark : .light).frame(width: 640))
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 640, accuracy: 1)
            }
        }
    }

    // MARK: Up next

    func testUpNextCaptionAndTheBriefButton() throws {
        let r = try rig()
        let watch = UpNextMemoryWatch(env: r.env)
        let item = HomeUpNextItem(id: "ev-1", title: "Halden weekly", meta: "", session: nil, event: event(with: [PeopleEnv.marta, PeopleEnv.joe]))
        let about = try XCTUnwrap(watch.about(item))
        XCTAssertEqual(about.past.map(\.name), ["halden-kickoff"])
        let last = try XCTUnwrap(about.past.first?.date)
        XCTAssertEqual(UpNextMemoryWatch.caption(count: 1, last: last), "Met once · last \(last.formatted(BriefLayout.shortDate))")
        XCTAssertEqual(UpNextMemoryWatch.caption(count: 3, last: last), "Met 3 times · last \(last.formatted(BriefLayout.shortDate))")
        // A guest nobody met: no caption and no Brief button.
        let stranger = HomeUpNextItem(id: "ev-2", title: "Corvo", meta: "", session: nil, event: event("Corvo", with: [PeopleEnv.giulia]))
        XCTAssertNil(watch.about(stranger))
        // Without the memory environment (tests, renders) the row is as before.
        XCTAssertNil(UpNextMemoryWatch(env: nil).about(item))

        // A fresh brief opens the popover; none makes one; a failed one makes again.
        let brief = BriefStore.decode(try Data(contentsOf: MemoryFixtures.fixturesDir.appendingPathComponent("brief.json")))
        XCTAssertEqual(UpNextBriefButton.action(brief: brief, failure: nil), .open)
        XCTAssertEqual(UpNextBriefButton.action(brief: nil, failure: nil), .make)
        XCTAssertEqual(UpNextBriefButton.action(brief: brief, failure: ChatFailure(kind: "offline", message: "")), .make)
    }

    func testTheBriefFromUpNextForAnItemWithoutASessionIsAnEntityBriefInTheMemoryFolder() async throws {
        let r = try rig()
        let e = event(with: [PeopleEnv.marta])
        let request = try XCTUnwrap(BriefPlanning.request(for: e, session: nil, file: r.store.file, folders: r.model.folders.file,
                                                          sessions: r.model.sessions, sessionsRoot: scratch.sessions))
        XCTAssertNil(request.sessionOut, "no session to write into")
        let result = await r.center.run(request, session: nil)
        guard case .success = result else { return XCTFail("the scripted brief succeeds") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.paths.brief(entity: request.entity.id).path))
        XCTAssertEqual(SpendLedger.runs(sessionDir: scratch.memory).map(\.kind), ["brief"], "an entity brief is charged to memory/spend.json")
    }
}
