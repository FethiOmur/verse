import AppKit
import ScreenCaptureKit
import SwiftUI
import VerseAudio
import VerseMeet
import VersePrompter
import VerseTurns

// `Verse --render-home DIR`: every home page over the mockups' wallpaper, 1280 x 800 pt at 2x, light and dark, plus
// Prepare under Reduce Transparency and Increase Contrast. The same canvas, window frame (1100 x 680) and wallpaper as
// design/mockups, so a render lines up with the approved PNGs. Fixture data only; nothing reads or writes the user's
// sessions, spend ledger, profile or settings. `VERSE_RENDER_LANG=it|tr` renders in that interface language.
//
// Render-only differences from the app: the window glass is SwiftUI's in-window `glassEffect` over the wallpaper (the app
// uses a behind-window AppKit sheet, HomeGlass.swift), and the traffic lights are drawn, not real.

@MainActor
public enum HomeRender {
    /// `VERSE_RENDER_TALL=1`: a taller window (1100 x 2000) to look at the whole of a long page (the Me page).
    static let tall = ProcessInfo.processInfo.environment["VERSE_RENDER_TALL"] != nil
    public static let canvas = CGSize(width: 1280, height: tall ? 2120 : 800)
    static var windowHeight: CGFloat { tall ? 2000 : 680 }

    struct Variant {
        var suffix: String
        var override: HomeA11yOverride?
        var pages: [HomePage]
    }

    /// File names `home-<page>[-reduce-transparency|-increase-contrast]-<light|dark>.png`, like the mockups.
    public static func renderAll(to dir: URL, pages only: [HomePage]? = nil) async throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixtures = try Fixtures()
        defer { fixtures.cleanUp() }
        let variants = [
            // People has its own states below (a brief, a stale one, none, and an empty page).
            Variant(suffix: "", override: nil, pages: HomePage.allCases.filter { $0 != .people }),
            Variant(suffix: "-reduce-transparency", override: HomeA11yOverride(reduceTransparency: true), pages: [.prepare]),
            Variant(suffix: "-increase-contrast", override: HomeA11yOverride(increaseContrast: true), pages: [.prepare]),
        ]
        var out: [URL] = []
        // `VERSE_RENDER_ASK_ONLY=1`: only the Ask panel's states (the redesign work renders these over and over).
        if ProcessInfo.processInfo.environment["VERSE_RENDER_ASK_ONLY"] != nil {
            for dark in [false, true] { out += try await renderAsk(fixtures, dir: dir, dark: dark) }
            return out
        }
        for dark in [false, true] {
            // Sessions on a practice run: its report on the reading plate.
            if only?.contains(.sessions) ?? true {
                let router = HomeRouter()
                router.page = .sessions
                router.selectedSession = fixtures.practiceSession
                let url = dir.appendingPathComponent("home-sessions-report-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: router), dark: dark, override: nil), size: canvas, dark: dark, to: url)
                out.append(url)

                // Sessions in folders (F3): two folders and No folder; the selected row carries its suggestion chip.
                let folderFixtures = try FolderFixtures()
                defer { folderFixtures.cleanUp() }
                let folderRouter = HomeRouter()
                folderRouter.page = .sessions
                folderRouter.selectedSession = folderFixtures.selectedSession
                let folderURL = dir.appendingPathComponent("home-sessions-folders-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: folderRouter, sessions: folderFixtures.sessions), dark: dark, override: nil),
                                  size: canvas, dark: dark, to: folderURL)
                out.append(folderURL)

                // Move to Trash, the Mail way: a row swiped open on its red Trash action, and the "Moved to Trash · Undo" toast.
                for (name, state) in [("swipe", SessionsTrashRenderState(swiped: "Harbor Ledger kickoff")), ("toast", SessionsTrashRenderState(toast: true))] {
                    let url = dir.appendingPathComponent("home-sessions-trash-\(name)-\(dark ? "dark" : "light").png")
                    var scene = Scene(context: fixtures.context(router: folderRouter, sessions: folderFixtures.sessions), dark: dark, override: nil)
                    scene.trashRender = state
                    try await capture(scene, size: canvas, dark: dark, to: url)
                    out.append(url)
                }
            }
            // Sessions on a meeting with a transcript (F1): the Transcript tab, and again with a search shown.
            if only?.contains(.sessions) ?? true {
                for (name, query) in [("", ""), ("-search", "close")] {
                    let router = HomeRouter()
                    router.page = .sessions
                    router.selectedSession = fixtures.transcriptSession
                    let url = dir.appendingPathComponent("home-sessions-transcript\(name)-\(dark ? "dark" : "light").png")
                    var scene = Scene(context: fixtures.context(router: router), dark: dark, override: nil)
                    scene.detailRender = SessionsDetailRenderState(tab: .transcript, query: query)
                    try await capture(scene, size: canvas, dark: dark, to: url)
                    out.append(url)
                }
            }
            // Sessions with the Ask panel open: the three-turn chat, the same with a hovered citation, the empty state, a question being
            // thought about, one being answered, and one that failed.
            if only?.contains(.sessions) ?? true {
                out += try await renderAsk(fixtures, dir: dir, dark: dark)
            }
            // Memory: Ask across meetings, the brief before a prepared meeting, and Up next's Brief popover (fictional people only).
            if (only?.contains(.sessions) ?? true) || (only?.contains(.prepare) ?? true) {
                out += try await renderMemory(fixtures, dir: dir, dark: dark, pages: only)
            }
            // People: the entity page with a ready brief, a stale one, none, and the empty page (fictional people only).
            if only?.contains(.people) ?? true {
                out += try await renderPeople(fixtures, dir: dir, dark: dark)
            }
            // Me: the usual state, and the one with "Sources changed · Refresh" (a build older than a week, a source changed).
            if only?.contains(.me) ?? true {
                let router = HomeRouter()
                router.page = .me
                let url = dir.appendingPathComponent("home-me-stale-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: router, staleMe: true), dark: dark, override: nil), size: canvas, dark: dark, to: url)
                out.append(url)
            }
            // Settings: the Meetings group alone, whole.
            if only?.contains(.settings) ?? true {
                let router = HomeRouter()
                router.page = .settings
                let url = dir.appendingPathComponent("home-settings-meetings-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: router), dark: dark, override: nil, meetingsOnly: true), size: canvas, dark: dark, to: url)
                out.append(url)
            }
            // The sidebar footer while a session runs (Listening · session, with Stop).
            if only?.contains(.prepare) ?? true {
                let router = HomeRouter()
                router.page = .prepare
                router.selectedSession = fixtures.selectedSession
                fixtures.controller.setRunningForPreview(true)
                let url = dir.appendingPathComponent("home-sidebar-running-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: router), dark: dark, override: nil), size: canvas, dark: dark, to: url)
                fixtures.controller.setRunningForPreview(false)
                out.append(url)
            }
            for v in variants {
                for page in v.pages where only?.contains(page) ?? true {
                    let router = HomeRouter()
                    router.page = page
                    router.selectedSession = fixtures.selectedSession
                    let ctx = fixtures.context(router: router)
                    let name = "home-\(page.rawValue)\(v.suffix)-\(dark ? "dark" : "light")"
                    let url = dir.appendingPathComponent(name + ".png")
                    let scene = Scene(context: ctx, dark: dark, override: v.override)
                    try await capture(scene, size: canvas, dark: dark, to: url)
                    out.append(url)
                }
            }
        }
        return out
    }

    /// `home-sessions-ask[-state]-<light|dark>.png`: the Ask panel on the Brightwave call (fictional transcript and chat).
    static func renderAsk(_ fixtures: Fixtures, dir: URL, dark: Bool) async throws -> [URL] {
        let states: [(String, AskRenderState)] = [
            ("", AskRenderState(draft: "What should I say next time?")),
            ("-hover", AskRenderState(hover: .init(question: "q4", stamp: "22:06"))),
            ("-empty", AskRenderState(script: .empty)),
            ("-thinking", AskRenderState(script: .thinking)),
            ("-streaming", AskRenderState(script: .streaming)),
            ("-failed", AskRenderState(script: .failed)),
        ]
        var out: [URL] = []
        for (name, state) in states {
            let router = HomeRouter()
            router.page = .sessions
            router.selectedSession = fixtures.transcriptSession
            let url = dir.appendingPathComponent("home-sessions-ask\(name)-\(dark ? "dark" : "light").png")
            var scene = Scene(context: fixtures.context(router: router), dark: dark, override: nil)
            scene.askRender = state
            try await capture(scene, size: canvas, dark: dark, to: url)
            out.append(url)
        }
        return out
    }

    /// `home-sessions-ask-memory-{all,entity}-*`, `home-sessions-prepared-brief-dark`, `home-prepare-upnext-brief-dark`: Ask across
    /// meetings and the brief placements over fictional meetings with Halden Works, Corvo Studio and Tarla Labs.
    static func renderMemory(_ fixtures: Fixtures, dir: URL, dark: Bool, pages: [HomePage]?) async throws -> [URL] {
        var out: [URL] = []
        let mf = try MemoryRenderFixtures(settings: fixtures.settings)
        defer { mf.cleanUp() }
        let mode = dark ? "dark" : "light"
        if pages?.contains(.sessions) ?? true {
            let router = HomeRouter()
            router.page = .sessions
            router.selectedSession = "Halden Pilot Review"
            let all = dir.appendingPathComponent("home-sessions-ask-memory-all-\(mode).png")
            var scene = Scene(context: mf.context(router: router, fixtures: fixtures), dark: dark, override: nil)
            scene.askRender = AskRenderState(scope: .all)
            try await capture(scene, size: canvas, dark: dark, to: all)
            out.append(all)
            if dark {
                let entityRouter = HomeRouter()
                entityRouter.page = .sessions
                entityRouter.selectedSession = "Halden Pilot Review"
                let entity = dir.appendingPathComponent("home-sessions-ask-memory-entity-\(mode).png")
                var entityScene = Scene(context: mf.context(router: entityRouter, fixtures: fixtures), dark: dark, override: nil)
                entityScene.askRender = AskRenderState(scope: .entity(mf.people.marta), hover: .init(question: "q2", stamp: "1"))
                try await capture(entityScene, size: canvas, dark: dark, to: entity)
                out.append(entity)

                let briefRouter = HomeRouter()
                briefRouter.page = .sessions
                briefRouter.selectedSession = mf.prepared
                let brief = dir.appendingPathComponent("home-sessions-prepared-brief-\(mode).png")
                try await capture(Scene(context: mf.context(router: briefRouter, fixtures: fixtures), dark: dark, override: nil), size: canvas, dark: dark, to: brief)
                out.append(brief)
            }
        }
        if dark, pages?.contains(.prepare) ?? true {
            let router = HomeRouter()
            router.page = .prepare
            let url = dir.appendingPathComponent("home-prepare-upnext-brief-\(mode).png")
            var scene = Scene(context: mf.context(router: router, fixtures: fixtures), dark: dark, override: nil)
            scene.upNextBriefRender = true
            try await capture(scene, size: canvas, dark: dark, to: url)
            out.append(url)
        }
        return out
    }

    /// `home-people-{brief,stale,nobrief,empty}-<light|dark>.png`: Marta Velin's page over a fictional Halden Works, and the empty page.
    static func renderPeople(_ fixtures: Fixtures, dir: URL, dark: Bool) async throws -> [URL] {
        var out: [URL] = []
        for state in ["brief", "stale", "nobrief", "empty"] {
            let pf = try PeopleFixtures(empty: state == "empty", settings: fixtures.settings)
            defer { pf.cleanUp() }
            let router = HomeRouter()
            router.page = .people
            router.selectedEntity = pf.marta
            let ctx = HomeContext(settings: fixtures.settings, controller: fixtures.controller, simSettings: fixtures.simSettings, sim: fixtures.sim,
                                  conversation: fixtures.conversation, sessions: pf.sessions, upNext: pf.upNext, me: fixtures.meModel(stale: false),
                                  router: router, memory: nil, people: pf.store)
            var scene = Scene(context: ctx, dark: dark, override: nil)
            scene.briefRender = PeopleBriefRenderState(brief: state == "brief" ? pf.brief(stale: false) : (state == "stale" ? pf.brief(stale: true) : nil))
            let url = dir.appendingPathComponent("home-people-\(state)-\(dark ? "dark" : "light").png")
            try await capture(scene, size: canvas, dark: dark, to: url)
            out.append(url)
        }
        return out
    }

    // MARK: scene

    struct Scene: View {
        var context: HomeContext
        var dark: Bool
        var override: HomeA11yOverride?
        var meetingsOnly = false
        /// The Sessions detail's tab and search, forced for the transcript renders.
        var detailRender: SessionsDetailRenderState?
        /// The Ask panel open over what `chat.jsonl` holds (F2b).
        var askRender: AskRenderState?
        /// A row with its Trash action revealed, or the toast (Move to Trash).
        var trashRender: SessionsTrashRenderState?
        /// The brief the People page shows (renders only).
        var briefRender: PeopleBriefRenderState?
        /// Up next's Brief popover drawn open (renders only; a popover is a window of its own and is not in the capture).
        var upNextBriefRender = false

        var body: some View {
            ZStack {
                RenderWallpaper(dark: dark)
                HomeRoot(context: context, a11yOverride: override ?? HomeA11yOverride(), inWindowGlass: true, meetingsOnly: meetingsOnly)
                    .environment(\.sessionsDetailRender, detailRender)
                    .environment(\.askRender, askRender)
                    .environment(\.sessionsTrashRender, trashRender)
                    .environment(\.peopleBriefRender, briefRender)
                    .environment(\.upNextBriefRender, upNextBriefRender)
                    .frame(width: 1100, height: HomeRender.windowHeight)
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 30, y: 16)
            }
            .frame(width: HomeRender.canvas.width, height: HomeRender.canvas.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    // MARK: capture (the mockups' approach: an offscreen window, grabbed with ScreenCaptureKit)

    static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async throws {
        let window = RenderWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).clipped())
        if let s = NSScreen.main { window.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.minY - size.height + 2)) }
        // Key, so the native switches and sliders draw in their active (mint) state like in the real window.
        window.orderBack(nil)
        NSApp.activate()
        window.makeKey()
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(900))

        let content = try await SCShareableContent.currentProcess
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "HomeRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not capturable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let px = CGFloat(filter.pointPixelScale)
        cfg.width = Int(size.width * px)
        cfg.height = Int(size.height * px)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        var image: CGImage?
        var lastError: Error?
        for attempt in 0..<5 where image == nil {
            do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        guard let image else { throw lastError ?? NSError(domain: "HomeRender", code: 3) }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "HomeRender", code: 2)
        }
        try png.write(to: url)
    }

    /// A borderless window that can be key.
    final class RenderWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    // MARK: people fixtures

    /// The People page over fictional people at `.example` domains: Halden Works (Marta Velin, Joe Arkwright), Corvo Studio (Giulia Ferri,
    /// an Italian call) and Tarla Labs (Emre Kaya, a Turkish call), and the owner Dana Reyes. Everything lives in a temporary folder.
    @MainActor
    final class PeopleFixtures {
        let root: URL
        let sessions: HomeSessionsModel
        let store: EntityStore
        let upNext: HomeUpNextModel
        let marta = "e-martavel"
        private let suite = "\(AppIdentity.bundleID).render-people-\(UUID().uuidString)"

        init(empty: Bool, settings: AppSettings, prepared: Bool = false) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("verse-render-people-\(UUID().uuidString)", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            try fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            let cal = Calendar.current
            let now = Date()
            func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
                let d = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
                return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
            }
            func write(_ name: String, _ date: Date, summary: String, extra: [String: String] = [:]) throws {
                let d = sessionsRoot.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data().write(to: d.appendingPathComponent("pack.md"))
                for (f, text) in extra.merging(["summary.md": summary], uniquingKeysWith: { a, _ in a }) {
                    let u = d.appendingPathComponent(f)
                    try Data(text.utf8).write(to: u)
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
                }
            }
            func summary(_ line: String, actions: [String]) -> String {
                "# Meeting summary\n\n_generated fixture_\n\n## Summary\n\n\(line)\n\n## Actions\n\n" + actions.map { "- \($0)\n" }.joined()
            }
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            let paths = MemoryPaths(base: root.appendingPathComponent("memory", isDirectory: true))
            if empty {
                sessions = HomeSessionsModel(root: sessionsRoot, defaults: defaults)
                store = EntityStore(paths: paths, sessionsRoot: sessionsRoot)
                upNext = HomeUpNextModel(settings: settings, meeting: MeetingSettings(defaults: defaults), sessions: { [] },
                                         eventMap: EventSessionMap(url: root.appendingPathComponent("event-sessions.json")))
                return
            }
            try write("Halden Pilot Review", at(2, 10, 0),
                      summary: summary("Marta Velin agreed to start the pilot with two teams. The budget stays open until the revised sheet arrives.",
                                       actions: ["Send the revised budget by Friday", "Share the security questionnaire next week"]))
            try write("Halden Kickoff", at(8, 17, 0),
                      summary: summary("Marta Velin and Joe Arkwright described the invoice-matching backlog at Halden Works.",
                                       actions: ["Send the pilot plan"]))
            try write("Corvo Design Call", at(5, 15, 0),
                      summary: summary("Giulia Ferri ha chiesto una prima bozza della navigazione entro il fine mese.", actions: ["Inviare la bozza"]))
            try write("Tarla Intro", at(12, 11, 0),
                      summary: summary("Emre Kaya pilot için iki haftalık bir deneme istedi.", actions: ["Deneme planını paylaş"]))
            try write("Halden pricing call", at(20, 14, 0),
                      summary: summary("A short call about per-seat pricing.", actions: []))
            if prepared {
                // A session prepared from the invite of tomorrow's call: a pack, no summary, not held yet.
                let d = sessionsRoot.appendingPathComponent("Halden weekly", isDirectory: true)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data("# Halden weekly\n\nPrepared from the invite.\n".utf8).write(to: d.appendingPathComponent("pack.md"))
                try Data(#"{"languages":["en"]}"#.utf8).write(to: d.appendingPathComponent("meta.json"))
            }
            sessions = HomeSessionsModel(root: sessionsRoot, defaults: defaults)
            let halden = try sessions.folders.create(name: "Halden Works")
            for s in ["Halden Pilot Review", "Halden Kickoff"] { try sessions.folders.move(s, to: halden.id) }
            sessions.reload()

            // people.json as the app would have written it: the owner is Dana Reyes, so her address is not an entity.
            let created = at(30, 9, 0)
            func person(_ id: String, _ name: String, _ email: String, company: String) -> MemoryEntity {
                MemoryEntity(id: id, kind: .person, name: name, emails: [email], company: company, createdAt: created)
            }
            var file = PeopleFile()
            file.entities = [
                person("e-martavel", "Marta Velin", "marta@halden.example", company: "e-haldenwk"),
                person("e-joearkwr", "Joe Arkwright", "joe@halden.example", company: "e-haldenwk"),
                MemoryEntity(id: "e-haldenwk", kind: .company, name: "Halden Works", domains: ["halden.example"], aliases: ["Halden"],
                             folders: [halden.id], namedBy: "user", createdAt: created),
                person("e-giuliafe", "Giulia Ferri", "giulia@corvo.example", company: "e-corvostu"),
                MemoryEntity(id: "e-corvostu", kind: .company, name: "Corvo Studio", domains: ["corvo.example"], createdAt: created),
                person("e-emrekaya", "Emre Kaya", "emre@tarla.example", company: "e-tarlalab"),
                MemoryEntity(id: "e-tarlalab", kind: .company, name: "Tarla Labs", domains: ["tarla.example"], createdAt: created),
            ]
            file.ownerEmails = ["owner@example.com"]
            file.attendees = [
                "Halden Pilot Review": [Attendee(name: "Marta Velin", email: "marta@halden.example")],
                "Halden Kickoff": [Attendee(name: "Marta Velin", email: "marta@halden.example"), Attendee(name: "Joe Arkwright", email: "joe@halden.example")],
                "Corvo Design Call": [Attendee(name: "Giulia Ferri", email: "giulia@corvo.example")],
                "Tarla Intro": [Attendee(name: "Emre Kaya", email: "emre@tarla.example")],
            ]
            if prepared {
                file.attendees["Halden weekly"] = [Attendee(name: "Marta Velin", email: "marta@halden.example"), Attendee(name: "Joe Arkwright", email: "joe@halden.example")]
            }
            try fm.createDirectory(at: paths.base, withIntermediateDirectories: true)
            try PeopleCodec.encode(file).write(to: paths.people)
            store = EntityStore(paths: paths, sessionsRoot: sessionsRoot)

            let owner = Attendee(name: "Dana Reyes", email: "owner@example.com")
            let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
            let event = MeetingEvent(id: "ev-halden-weekly", title: "Halden weekly", start: start, end: start.addingTimeInterval(1_800),
                                     attendees: [owner, Attendee(name: "Marta Velin", email: "marta@halden.example"),
                                                 Attendee(name: "Joe Arkwright", email: "joe@halden.example")], provider: .meet, currentUser: owner)
            upNext = HomeUpNextModel(settings: settings, meeting: MeetingSettings(defaults: defaults), sessions: { [] },
                                     eventMap: EventSessionMap(url: root.appendingPathComponent("event-sessions.json")))
            upNext.setItems([HomeUpNextItem(id: event.id, title: event.title, meta: "", session: nil, event: event)])
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        /// Marta's brief: made from the Pilot Review (current) or from the Kickoff only (stale).
        func brief(stale: Bool, entity: String? = nil, name: String? = nil, forSession: String? = nil) -> BriefFile {
            func cite(_ session: String, key: String, kind: String = "turn", _ stamp: String? = nil) -> BriefFile.Cite {
                BriefFile.Cite(key: key, session: session, kind: kind, stamp: stamp)
            }
            let review = "Halden Pilot Review", kick = "Halden Kickoff"
            let sections: [BriefFile.Section] = [
                .init(id: "discussed", points: [
                    .init(text: "The pilot covers two teams, not four", cites: [cite(review, key: "sp0m2vx", "4:10")]),
                    .init(text: "Pricing moves to per-seat once the pilot ends", cites: [cite(kick, key: "sk3f9qa", kind: "summary")]),
                ]),
                .init(id: "promised_owner", points: [
                    .init(text: "Send the revised budget by Friday", cites: [cite(review, key: "sp0m2vx", "31:12"), cite(review, key: "sp0m2vx", kind: "summary")]),
                ]),
                .init(id: "promised_them", points: [
                    .init(text: "Marta shares the security questionnaire next week", cites: [cite(kick, key: "sk3f9qa", "12:34")]),
                ]),
                .init(id: "open", points: [
                    .init(text: "Whether the second team joins in January", cites: [cite(review, key: "sp0m2vx", "18:40")]),
                ]),
                .init(id: "tone", points: [
                    .init(text: "Prefers short written follow-ups to long calls", cites: [cite(kick, key: "sk3f9qa", "25:05")]),
                ]),
            ]
            let iso = ISO8601DateFormatter()
            let cal = Calendar.current
            func stamp(_ daysAgo: Int) -> String { iso.string(from: cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()) }
            return BriefFile(version: 1, entity: entity ?? marta, name: name ?? "Marta Velin", madeAt: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date(), lang: "en",
                             model: "claude-sonnet-5-5", newestSession: stale ? kick : review, forSession: forSession,
                             sessions: [.init(name: review, key: "sp0m2vx", title: review, date: stamp(2)),
                                        .init(name: kick, key: "sk3f9qa", title: kick, date: stamp(8))],
                             sections: sections, costUSD: 0.048, droppedUncited: 0)
        }
    }

    // MARK: memory fixtures

    /// Ask across meetings and the brief placements over the People fixtures: Dana Reyes's fictional meetings with Halden Works,
    /// Corvo Studio and Tarla Labs, a session prepared for tomorrow's call with its brief, and the chats of two scopes. Everything is
    /// in a temporary folder; the memory service is disabled, so no process starts.
    @MainActor
    final class MemoryRenderFixtures {
        let people: PeopleFixtures
        let memory: MemoryService
        let prepared = "Halden weekly"
        let haldenCompany = "e-haldenwk"

        init(settings: AppSettings) throws {
            people = try PeopleFixtures(empty: false, settings: settings, prepared: true)
            let paths = MemoryPaths(base: people.root.appendingPathComponent("memory", isDirectory: true))
            memory = MemoryService(paths: paths, sessionsRoot: people.sessions.root, ownerName: { "Dana Reyes" },
                                   makeBrain: { throw NSError(domain: "render", code: 1) }, enabled: false)
            paths.ensureDirectories()
            // Briefs: the session's own (`brief.json`) and its company's latest.
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let own = people.brief(stale: false, entity: haldenCompany, name: "Halden Works", forSession: prepared)
            try enc.encode(own).write(to: people.sessions.root.appendingPathComponent(prepared).appendingPathComponent("brief.json"))
            try enc.encode(people.brief(stale: false, entity: haldenCompany, name: "Halden Works")).write(to: paths.brief(entity: haldenCompany))
            try Self.chat(all: true).write(to: paths.chat(named: "all"), atomically: true, encoding: .utf8)
            try Self.chat(all: false).write(to: paths.chat(named: people.marta), atomically: true, encoding: .utf8)
            people.sessions.reload()
        }

        func cleanUp() { people.cleanUp() }

        func context(router: HomeRouter, fixtures: Fixtures) -> HomeContext {
            HomeContext(settings: fixtures.settings, controller: fixtures.controller, simSettings: fixtures.simSettings, sim: fixtures.sim,
                        conversation: fixtures.conversation, sessions: people.sessions, upNext: people.upNext, me: fixtures.meModel(stale: false),
                        router: router, memory: memory, people: people.store)
        }

        /// The chat files, `memory/chats/all.jsonl` and `<entity-id>.jsonl`, in the brain's line shapes (memory spec 3.7).
        static func chat(all: Bool) -> String {
            let cal = Calendar.current
            let iso = ISO8601DateFormatter()
            func stamp(_ daysAgo: Int, _ h: Int = 10, _ m: Int = 0) -> String {
                let d = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
                return iso.string(from: cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d)
            }
            func cite(_ key: String, _ session: String, _ title: String, _ days: Int, _ kind: String, _ stampText: String?, _ speaker: String?, _ text: String) -> [String: Any] {
                ["key": key, "session": session, "title": title, "date": stamp(days), "kind": kind, "stamp": stampText as Any? ?? NSNull(),
                 "speaker": speaker as Any? ?? NSNull(), "text": text]
            }
            func line(_ o: [String: Any]) -> String { AskWire.line(o) }
            func q(_ id: String, _ text: String, _ scope: String, _ days: Int) -> String {
                line(["type": "q", "id": id, "t": stamp(days, 11, 2), "text": text, "model": "claude-sonnet-5-5", "scope": scope])
            }
            func a(_ id: String, _ q: String, _ text: String, _ cites: [[String: Any]], cost: Double, ms: Int, days: Int) -> String {
                line(["type": "a", "id": id, "q": q, "t": stamp(days, 11, 3), "text": text, "model": "claude-sonnet-5-5",
                      "usage": ["input": 1_840, "output": 212, "cache_read": 15_620, "cache_write": 0], "cost_usd": cost, "cost_estimated": false,
                      "ms_first_token": 1_900, "ms_total": ms, "citations": cites, "stop_reason": "end_turn", "context": "memory", "excerpt_tokens": 15_820])
            }
            let budget = cite("sp0m2vx", "Halden Pilot Review", "Halden Pilot Review", 2, "turn", "31:12", "Dana", "I'll send the revised budget by Friday, with the two-team scope.")
            let plan = cite("sk3f9qa", "Halden Kickoff", "Halden Kickoff", 8, "turn", "12:34", "Marta", "We'd need the pilot plan by Friday, and the security questionnaire after that.")
            let corvo = cite("sc4r7wd", "Corvo Design Call", "Corvo Design Call", 5, "summary", nil, nil, "Actions: Send the navigation draft by the end of the month")
            let pricing = cite("sk3f9qa", "Halden Kickoff", "Halden Kickoff", 8, "summary", nil, nil, "Pricing moves to per-seat once the pilot ends.")
            let gone = cite("sg7t1mn", "Halden pricing call", "Halden pricing call", 20, "turn", "4:02", "Joe", "Per-seat is fine for us if the pilot stays free.")
            let review = cite("sp0m2vx", "Halden Pilot Review", "Halden Pilot Review", 2, "turn", "4:10", "Marta", "The pilot covers two teams, not four.")
            let reviewSummary = cite("sp0m2vx", "Halden Pilot Review", "Halden Pilot Review", 2, "summary", nil, nil, "Marta Velin and Joe Arkwright described the invoice-matching backlog.")
            let tone = cite("sk3f9qa", "Halden Kickoff", "Halden Kickoff", 8, "turn", "25:05", "Marta", "Short written follow-ups work better for me than another call.")
            var out: [String] = []
            if all {
                out.append(q("q1", "What did I promise, and to whom?", "all", 1))
                out.append(a("a1", "q1", "You made two promises in the last week.\n- To Marta at Halden Works: the revised budget by Friday [sp0m2vx 31:12].\n- To Giulia at Corvo Studio: the navigation draft by the end of the month [sc4r7wd summary].\nMarta also asked for the pilot plan by Friday [sk3f9qa 12:34].",
                             [budget, corvo, plan], cost: 0.041, ms: 5_200, days: 1))
                out.append(q("q2", "Which meetings talked about pricing?", "all", 1))
                out.append(a("a2", "q2", "Two meetings did.\n- Halden Kickoff: pricing moves to per-seat once the pilot ends [sk3f9qa summary].\n- An earlier pricing call, which is no longer in Verse [sg7t1mn 4:02].",
                             [pricing, gone], cost: 0.038, ms: 4_400, days: 1))
            } else {
                out.append(q("q1", "What did we agree last time?", "e-martavel", 1))
                out.append(a("a1", "q1", "At the Pilot Review you agreed on a two-team pilot [sp0m2vx 4:10], and you said you would send the revised budget by Friday [sp0m2vx 31:12]. Marta still owes you the pilot plan [sk3f9qa 12:34].",
                             [review, budget, plan], cost: 0.036, ms: 4_800, days: 1))
                out.append(q("q2", "How does Marta like to work?", "e-martavel", 1))
                out.append(a("a2", "q2", "She prefers short written follow-ups to another call [sk3f9qa 25:05], and she wants the numbers in the summary rather than in the meeting [sp0m2vx summary].",
                             [tone, reviewSummary], cost: 0.033, ms: 4_100, days: 1))
            }
            return out.joined(separator: "\n") + "\n"
        }
    }

    // MARK: folder fixtures

    /// The Sessions page with folders: fictional sessions in a temporary folder, two folders filled the way the app fills them
    /// (a move by hand, a practice run that follows its source), and one unfiled session with a "new folder" suggestion.
    @MainActor
    final class FolderFixtures {
        let root: URL
        let sessions: HomeSessionsModel
        let selectedSession = "Tideline Studio first call"
        private let suite = "\(AppIdentity.bundleID).render-folders-\(UUID().uuidString)"

        init() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("verse-render-folders-\(UUID().uuidString)", isDirectory: true)
            self.root = root
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let cal = Calendar.current
            let now = Date()
            func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
                let d = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
                return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
            }
            func write(_ name: String, _ date: Date, _ files: [String: String]) throws {
                let d = root.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data().write(to: d.appendingPathComponent("pack.md"))
                for (f, text) in files {
                    let u = d.appendingPathComponent(f)
                    try Data(text.utf8).write(to: u)
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
                }
            }
            func summary(_ who: String, _ line: String) -> String {
                "# Meeting summary\n\n_generated fixture_\n\n## Summary\n\n\(who) \(line)\n\n## Actions\n\n- Send the notes by Friday\n- Share the draft pricing sheet\n"
            }
            try write("Harbor Ledger pricing call", at(0, 14, 30), ["summary.md": summary("Dana from Harbor Ledger", "wants per-seat pricing for the pilot.")])
            try write("Harbor Ledger kickoff", at(3, 11, 0), ["summary.md": summary("Dana from Harbor Ledger", "described the invoice-matching backlog.")])
            try write("sim-20261018-0900-Harbor Ledger kickoff", at(2, 9, 0),
                      ["report.html": FolderFixtures.report,
                       "sim.json": #"{"source":"session","source_session":"Harbor Ledger kickoff","company":"Harbor Ledger"}"#])
            try write("Northwind Labs intro call", at(4, 15, 0), ["summary.md": summary("Theo from Northwind Labs", "is hiring a first applied-ML engineer.")])
            try write("Northwind Labs technical review", at(8, 10, 30), ["summary.md": summary("Theo and Mira from Northwind Labs", "walked through the retrieval stack.")])
            try write("Tideline Studio first call", at(1, 16, 0),
                      ["summary.md": summary("Ines from Tideline Studio", "wants a prototype of the booking assistant."),
                       "meta.json": #"{"conversation":{"company":"Tideline Studio"}}"#])
            try write("adhoc-20261019-0905-meeting", at(1, 9, 5), ["summary.md": summary("A short unplanned call:", "scheduling a follow-up."),
                                                                 "meta.json": #"{"kind":"adhoc","lang":"en","mode":"unprepared","route":"meeting"}"#])
            try write("Earlier sync with Dana", at(12, 10, 0), ["summary.md": summary("Dana", "checked in on the pilot timeline.")])

            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            let sessions = HomeSessionsModel(root: root, defaults: defaults)
            self.sessions = sessions
            let harbor = try sessions.folders.create(name: "Harbor Ledger")
            let northwind = try sessions.folders.create(name: "Northwind Labs")
            for s in ["Harbor Ledger pricing call", "Harbor Ledger kickoff"] { try sessions.folders.move(s, to: harbor.id) }
            for s in ["Northwind Labs intro call", "Northwind Labs technical review"] { try sessions.folders.move(s, to: northwind.id) }
            sessions.setMode(.folders)
            // The practice run follows its source session into Harbor Ledger.
            sessions.reload()
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        static let report = Fixtures.sampleReport
    }

    // MARK: fixtures

    /// The mockups' sample content, in real models and a temporary folder.
    @MainActor
    final class Fixtures {
        let root: URL
        let settings: AppSettings
        let simSettings: SimSettings
        let controller: VerseController
        let sim: SimController
        let conversation: ConversationController
        let sessions: HomeSessionsModel
        let upNext: HomeUpNextModel
        /// The fictional profile folder of the Me page (Dana Reyes; never the owner's own).
        let profileDir: URL
        let selectedSession = "Mara · Northwind Labs"
        let practiceSession = "sim-20261013-1000-Brightwave"
        /// A meeting with a transcript and its events (fictional): the Transcript tab renders.
        let transcriptSession = "Brightwave · Lena Brandt"

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("verse-render-home-\(UUID().uuidString)", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            try fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            let suite = "\(AppIdentity.bundleID).render-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            settings = AppSettings(defaults: defaults)
            // `VERSE_RENDER_LANG=it|tr|en`: the interface language of the whole render (set before the models read their texts).
            if let raw = ProcessInfo.processInfo.environment["VERSE_RENDER_LANG"], let lang = InterfaceLanguage(rawValue: raw) {
                settings.interfaceLanguage = lang
            }
            simSettings = SimSettings(defaults: defaults)
            controller = VerseController(settings: settings)
            sim = SimController(settings: settings, simSettings: simSettings, meeting: controller)
            // Every path below is under `root` (a temporary folder): no render reads the user's sessions, spend ledger, event map,
            // reports or profile. `HomeRenderPrivacyTests` pins this.
            conversation = ConversationController(owner: { "Dana" }, fake: { false }, brainDir: { nil }, root: sessionsRoot,
                                                  selectSession: { _ in false })
            profileDir = root.appendingPathComponent("profile", isDirectory: true)
            try Self.writeProfile(into: profileDir)
            try Self.writeSessions(into: sessionsRoot)
            // The controller was built over the real sessions folder (its init lists it); point it at the fictional one and list again,
            // so nothing a render shows (the sidebar's Recent, Practice's meetings, Ask) can be one of the owner's own sessions.
            controller.sessionsRoot = sessionsRoot
            controller.eventSessions = EventSessionMap(url: root.appendingPathComponent("event-sessions.json"))
            controller.refreshSessions()
            controller.setSpendForPreview(session: 0.84, month: 12.30)
            sim.setLastReportForPreview(sessionsRoot.appendingPathComponent("sim-20261013-1000-Brightwave/report.html"))
            sim.refreshMeetings()
            sessions = HomeSessionsModel(root: sessionsRoot, defaults: defaults)
            upNext = HomeUpNextModel(settings: settings, meeting: controller.meeting.settings, sessions: { [] },
                                     eventMap: EventSessionMap(url: root.appendingPathComponent("event-sessions.json")))
            settings.sessionName = "mara-northwindlabs"
            try fillScripts()
            fillPrepare()
            fillPractice()
        }

        func context(router: HomeRouter, staleMe: Bool = false, sessions override: HomeSessionsModel? = nil) -> HomeContext {
            HomeContext(settings: settings, controller: controller, simSettings: simSettings, sim: sim, conversation: conversation,
                        sessions: override ?? sessions, upNext: upNext, me: meModel(stale: staleMe), router: router)
        }

        /// The Me page's model over the fictional profile. `stale`: a source changed and the build is more than a week old.
        func meModel(stale: Bool) -> MeModel {
            let day = 24.0 * 3600
            let built = ISO8601DateFormatter().date(from: "2026-10-14T09:00:00Z") ?? Date()
            let now = built.addingTimeInterval(stale ? 11 * day : 2 * day)
            let runner = PreviewMeRunner(showOutput: stale ? "stale sources: dana_profile.md, Harbor Ledger.md" : "stale sources: none")
            let model = MeModel(directory: profileDir, runner: { runner }, brainDir: { self.root }, fake: { false }, now: { now })
            // The brain's own messages, as JSON: the status `ready` with its `me` block and the conflicts notice.
            let ready = JSONValue.decodeObject(#"{"type":"status","state":"ready","me":{"tokens":3140,"built_at":"2026-10-14T09:00:00+00:00"}}"#)
            let notice = JSONValue.decodeObject(#"{"type":"notice","kind":"me_conflicts","items":[{"me":"m402","pack":"f003","topic":"Month-end close time"}]}"#)
            var conflicts: [MeConflict] = []
            if let notice, case .meConflicts(let items)? = BrainNotice(notice) { conflicts = items }
            controller.setMeForPreview(layer: ready.flatMap { MeLayerInfo(readyStatus: $0) }, conflicts: conflicts)
            return model
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        // the fictional profile

        private static func writeProfile(into dir: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(profileText.utf8).write(to: dir.appendingPathComponent("me.md"))
            let meta: [String: Any] = ["model": "claude-sonnet-5-5", "built_at": "2026-10-14T09:00:00+00:00", "tokens": 3140,
                                       "spend_usd_total": 0.07]
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("me.meta.json"))
            let sources: [[String: Any]] = [
                ["id": "s1", "kind": "file", "path": "/Users/dana/Documents/dana_profile.md", "label": "dana_profile.md", "enabled": true],
                ["id": "s2", "kind": "vault", "path": "/Users/dana/Notes/Projects/Harbor Ledger.md", "label": "Projects/Harbor Ledger.md", "enabled": true],
                ["id": "s3", "kind": "vault", "path": "/Users/dana/Notes/Projects/Trailhead.md", "label": "Projects/Trailhead.md", "enabled": true],
                ["id": "s4", "kind": "sessions", "path": "/Users/dana/Sessions", "label": "facts of earlier meeting preps", "enabled": false],
            ]
            try JSONSerialization.data(withJSONObject: sources, options: .prettyPrinted).write(to: dir.appendingPathComponent("me.sources.json"))
        }

        static let profileText = """
        ## WHO I AM
        [m001] Backend and machine-learning engineer in Lisbon with six years in production systems. | file:dana_profile.md#L3
        [m002] Likes small services that do one job well and says what was tested and what was not. | file:dana_profile.md#L20
        ## EXPERIENCE
        [m101] 2019-2022 | Backend engineer | Northwind Freight | Built the payment and invoicing services of a freight marketplace. | file:dana_profile.md#L7
        [m102] 2022-now | Machine-learning engineer | Larkspur Health | Owns the claims-triage model and its serving stack. | file:dana_profile.md#L8
        ## PROJECTS
        [m201] Harbor Ledger | Payments reconciliation service | designed and led it | Python, PostgreSQL, Kafka | about 41,000 payments a month | file:dana_profile.md#L13
        [m202] Trailhead | Hiking route recommendation app | built it alone | Python, FastAPI, PostGIS | 12,000 monthly users | file:dana_profile.md#L16
        ## SKILLS
        [m301] Python | Harbor Ledger, Trailhead and the claims-triage model | file:dana_profile.md#L13
        [m302] PostgreSQL | Harbor Ledger reconciliation store | file:dana_profile.md#L13
        ## NUMBERS
        [m401] number | Harbor Ledger processed about 41,000 payments a month. | 41000 | file:dana_profile.md#L13
        [m402] number | Harbor Ledger cut the month-end close from 6 days to 2 days. | 2 | file:dana_profile.md#L13
        [m403] number | Trailhead reached 12,000 monthly users. | 12000 | file:dana_profile.md#L16
        ## STORIES
        [m501] Double-posted payments | In March 2021 a nightly job posted 300 payments twice. Dana found the missing idempotency key within an hour and shipped a replay-safe fix the same day. | file:dana_profile.md#L24
        ## LOOKING FOR
        [m601] Senior machine-learning engineer role in Lisbon or remote in Europe, available from January 2027. | file:dana_profile.md#L28
        ## \(MeSection.notes.rawValue)
        [m701] Prefers short sentences and says what was measured. | \(OwnerProfile.current.sourceTag)
        [m702] Available for calls after 16:00 Lisbon time. | \(OwnerProfile.current.sourceTag)

        """

        // sessions

        private static func writeSessions(into dir: URL) throws {
            let fm = FileManager.default
            let cal = Calendar.current
            let now = Date()
            func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
                let d = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
                return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
            }
            let rows: [(String, Date, Bool)] = [
                ("Mara · Northwind Labs", at(daysAgo: 0, hour: 14, minute: 30), true),
                ("Brightwave case review", at(daysAgo: 2, hour: 11, minute: 0), true),
                ("Harbor Tech technical", at(daysAgo: 3, hour: 15, minute: 0), true),
                ("sim-20261013-1000-Brightwave", at(daysAgo: 3, hour: 10, minute: 0), false),
                ("Harbor Tech first call", at(daysAgo: 7, hour: 9, minute: 30), true),
                ("sim-20261008-1630-Harbor Tech", at(daysAgo: 8, hour: 16, minute: 30), false),
            ] + (0..<6).map { i in ("Earlier call \(i + 1)", at(daysAgo: 9 + i, hour: 10, minute: 0), true) }
            // Two calls that started without a prepared session (⌥⌘V): the Unprepared tag and the route.
            for (name, route, date) in [("adhoc-20261016-1432-room", "room", at(daysAgo: 0, hour: 14, minute: 32)),
                                        ("adhoc-20261015-0905-meeting", "meeting", at(daysAgo: 1, hour: 9, minute: 5))] {
                let d = dir.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data().write(to: d.appendingPathComponent("pack.md"))
                try Data(#"{"kind":"adhoc","lang":"en","mode":"unprepared","route":"\#(route)"}"#.utf8).write(to: d.appendingPathComponent("meta.json"))
                let summary = d.appendingPathComponent("summary.md")
                try Data(Self.summaryText.utf8).write(to: summary)
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: summary.path)
            }
            try writeTranscriptSession(into: dir, date: at(daysAgo: 1, hour: 16, minute: 0))
            for (name, date, meeting) in rows {
                let d = dir.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data().write(to: d.appendingPathComponent("pack.md"))
                if meeting {
                    let summary = d.appendingPathComponent("summary.md")
                    try Data(Self.summaryText.utf8).write(to: summary)
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: summary.path)
                    try Data(Self.transcript.utf8).write(to: d.appendingPathComponent("transcript.jsonl"))
                } else {
                    // A practice run: its report.html. `VERSE_RENDER_REPORT` points at a real one (made by the brain's
                    // renderer); without it a small page in the same markup stands in.
                    let report = d.appendingPathComponent("report.html")
                    if let path = ProcessInfo.processInfo.environment["VERSE_RENDER_REPORT"], let real = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        try real.write(to: report)
                    } else {
                        try Data(Self.sampleReport.utf8).write(to: report)
                    }
                    try fm.setAttributes([.modificationDate: date], ofItemAtPath: report.path)
                }
            }
        }

        /// Two runs of one call (the connection dropped once), speakers, and the cards that fired: `transcript.jsonl` and
        /// `events.jsonl` in the forward format (`run_start`, `t_wall`, `card_done`). All text is fictional.
        private static func writeTranscriptSession(into dir: URL, date: Date) throws {
            let fm = FileManager.default
            let d = dir.appendingPathComponent("Brightwave · Lena Brandt", isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data().write(to: d.appendingPathComponent("pack.md"))
            let summary = d.appendingPathComponent("summary.md")
            try Data(summaryText.utf8).write(to: summary)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: summary.path)
            let r1 = 1_792_000_000.0, r2 = r1 + 1_260.0
            typealias Line = (run: Double, id: String, speaker: String, end: Double, text: String)
            let lines: [Line] = [
                (r1, "r1", "remote", 14.0, "Thanks for joining, Dana. I'm Lena, I lead platform at Brightwave. Before we dive in, can you tell me what you built at your last company?"),
                (r1, "m1", "me", 41.0, "Sure. I built a route planner for a small courier fleet, then a month-end close tool for finance teams. Both were one-engineer products, so I owned everything from the data model to the on-call rota."),
                (r1, "m2", "me", 58.0, "The close tool is the one I'm proudest of: it took the monthly close from six days to two."),
                (r1, "r2", "remote", 80.0, "Six days to two is a big claim. How did you measure it, and what was the baseline?"),
                (r1, "m3", "me", 112.0, "The baseline was the finance lead's own checklist timings over three months. After the rollout we tracked the same checklist with the same people, and the median close was two days."),
                (r1, "r3", "remote", 130.0, "Okay. And what did you stop doing to get there?"),
                (r1, "m4", "me", 161.0, "Mostly manual reconciliation. We replaced a shared spreadsheet with a matching job that flags only the exceptions."),
                (r1, "r4", "remote", 245.0, "Let's talk about the team. How do you work with someone who disagrees with a technical decision of yours?"),
                (r1, "m5", "me", 281.0, "I write down what would change my mind, and then we try the smaller option first. Last year that meant a nightly matching job instead of a real-time one, and nobody missed the real-time version."),
                (r2, "r1", "remote", 20.0, "Sorry, my connection dropped. Where were we? Right, disagreement. One last thing: what would you need in your first month?"),
                (r2, "m1", "me", 47.0, "A sandbox account, one person who owns the data export, and the last two post-mortems. I would rather read how things broke than how they are meant to work."),
                (r2, "r2", "remote", 66.0, "That is easy to arrange. Thank you, Dana, we will come back to you by Friday."),
            ]
            let transcript = lines.map { l -> String in
                #"{"addressee":"\#(l.speaker == "me" ? "other" : "me")","kind":"\#(l.speaker == "me" ? "statement" : "question")","lang":"en","run_start":\#(l.run),"speaker":"\#(l.speaker)","t_audio_end":\#(l.end),"t_wall":\#(l.run + l.end),"text":"\#(l.text)","turn_id":"\#(l.id)"}"#
            }.joined(separator: "\n")
            try Data(transcript.utf8).write(to: d.appendingPathComponent("transcript.jsonl"))
            typealias Card = (run: Double, after: Double, turn: String, tier: String, say: String?, points: [String])
            let cards: [Card] = [
                (r1, 16.0, "r1", "F", "I build small products end to end: a route planner for a courier fleet, then a month-end close tool for finance teams.",
                 ["Close tool: six days to two", "One engineer, full ownership from data model to on-call"]),
                (r1, 82.0, "r2", "F", "I compared the finance lead's own checklist timings over three months, before and after the rollout. Same people, same checklist: the median close went from six days to two.", []),
                (r1, 84.0, "r2", "D", nil, ["Baseline: three months of checklist timings", "Median, not the best case"]),
                (r1, 247.0, "r4", "F", "I write down what would change my mind, then we try the smaller option first.", ["Example: nightly matching job instead of real-time"]),
                (r2, 22.0, "r1", "F", "A sandbox account, one owner for the data export, and the last two post-mortems.", []),
            ]
            var events = [#"{"ev":"start","lang":"en","mode":"prepared","route":"meeting","t":\#(r1 - 3)}"#, #"{"ev":"start","lang":"en","mode":"prepared","route":"meeting","t":\#(r2 - 2)}"#]
            for c in cards {
                let say = c.say.map { #","say":"\#($0)""# } ?? ""
                let points = c.points.map { #""\#($0)""# }.joined(separator: ",")
                events.append(#"{"ev":"card_done","id":"\#(c.tier.lowercased())\#(Int(c.after))","points":[\#(points)]\#(say),"t":\#(c.run + c.after),"tier":"\#(c.tier)","turn":"\#(c.turn)"}"#)
            }
            try Data(events.joined(separator: "\n").utf8).write(to: d.appendingPathComponent("events.jsonl"))
            try Data(chat.utf8).write(to: d.appendingPathComponent("chat.jsonl"))
        }

        /// What Ask this meeting wrote for the call above (fictional): one pair before a reset (hidden), then three answers with citations.
        static let chat = """
        {"type":"q","id":"q1","t":"2026-10-19T16:30:00Z","text":"Test question before the reset","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a1","q":"q1","t":"2026-10-19T16:30:04Z","text":"Old answer [0:14]","model":"claude-sonnet-5-5","usage":{"input":9,"output":6,"cache_read":0,"cache_write":3400},"cost_usd":0.0215,"cost_estimated":false,"ms_first_token":1500,"ms_total":2100,"citations":["0:14"],"stop_reason":"end_turn","context":"full"}
        {"type":"reset","t":"2026-10-19T16:31:00Z"}
        {"type":"q","id":"q2","t":"2026-10-19T16:32:00Z","text":"What did Lena ask me?","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a2","q":"q2","t":"2026-10-19T16:32:05Z","text":"She asked four things: what you built at your last company [0:14], how you measured the six-days-to-two claim [1:20], what you stopped doing to get there [2:10], and how you handle a technical disagreement [4:05].\\n- She pushed hardest on the measurement and called it a big claim [1:20].\\n- After the connection dropped she added what you would need in your first month [21:20].","model":"claude-sonnet-5-5","usage":{"input":412,"output":196,"cache_read":0,"cache_write":3400},"cost_usd":0.0214,"cost_estimated":false,"ms_first_token":1840,"ms_total":4120,"citations":["0:14","1:20","2:10","4:05","21:20"],"stop_reason":"end_turn","context":"full"}
        {"type":"q","id":"q3","t":"2026-10-19T16:33:10Z","text":"Where was my answer weak?","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a3","q":"q3","t":"2026-10-19T16:33:13Z","text":"The disagreement answer. You gave one example, the nightly job instead of a real-time one, but not what you would do if the other person still disagreed [4:41].","model":"claude-sonnet-5-5","usage":{"input":260,"output":88,"cache_read":3400,"cache_write":0},"cost_usd":0.0035,"cost_estimated":false,"ms_first_token":900,"ms_total":2400,"citations":["4:41"],"stop_reason":"end_turn","context":"full"}
        {"type":"q","id":"q4","t":"2026-10-19T16:34:20Z","text":"What did I promise to do?","model":"claude-sonnet-5-5"}
        {"type":"a","id":"a4","q":"q4","t":"2026-10-19T16:34:23Z","text":"Nothing firm. Lena is the one who committed: she will come back to you by Friday [22:06].\\n- You said what you would need to start: a sandbox account, one owner for the data export and the last two post-mortems [21:47].","model":"claude-sonnet-5-5","usage":{"input":240,"output":104,"cache_read":3400,"cache_write":0},"cost_usd":0.0041,"cost_estimated":false,"ms_first_token":880,"ms_total":2900,"citations":["22:06","21:47"],"stop_reason":"end_turn","context":"full"}
        """

        static let summaryText = """
        # Meeting summary

        _generated fixture_

        ## Summary

        Mara wants the shift planner and the reminder agent turned into one SaaS for regional dental clinics. She owns pricing; Jonas owns onboarding. Budget is €4–5k a month for a contractor, starting in November.

        ## Actions

        - Send a one-page v1 scope by Friday
        - Ask Jonas for three clinic logins to test with
        - Price the reminder agent per location, not per seat
        """

        static let sampleReport = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{--bg:#050405;--ink:#eae5ec;--mute:#9a929f;--faint:#6d6672;--rule:#2a262d;--panel:#0d0b0e;--accent:#8fb8ab}
        html{background:var(--bg);color-scheme:dark}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.55 -apple-system,sans-serif}
        main{max-width:760px;margin:0 auto;padding:56px 24px}h1{font-size:34px;font-weight:600}h2{font-size:13px;text-transform:uppercase;color:var(--mute)}
        .meta{color:var(--mute)}.answer{border-left:2px solid var(--rule);padding-left:16px;color:#cfc9d3}</style></head>
        <body><main><h1>Practice report</h1><p class="meta">Brightwave · technical · 30 min</p>
        <section><h2>Answers</h2><p class="answer">I would start with the evaluation harness.</p></section></main></body></html>
        """

        static let transcript = """
        {"kind":"question","speaker":"remote","text":"How would you scope a v1?","turn_id":"r1"}
        {"kind":"question","speaker":"remote","text":"What breaks first at 500 locations?","turn_id":"r2"}
        {"kind":"question","speaker":"remote","text":"Would you work our hours?","turn_id":"r3"}
        """

        // scripts

        private func fillScripts() throws {
            let store = ScriptStore(directory: root.appendingPathComponent("scripts", isDirectory: true))
            let scripts: [(String, String)] = [
                ("Northwind Labs pitch", """
                Northwind Labs keeps clinic calendars full. I build the tools that turn that into a product your team can sell without me in the room.

                [pause, look at Mara]

                ---

                Two of your internal tools are already most of a SaaS: the shift planner and the reminder agent. A v1 is one login, one clinic group, twelve sites, and a weekly report the owner actually reads.

                I'd ship it in six weeks, behind your brand.
                """),
                ("Intro, 60 seconds", String(repeating: "I build agents that answer customers. ", count: 20)),
                ("Lantern story", String(repeating: "The lantern was lit at dusk. ", count: 44)),
                ("Why Brightwave", String(repeating: "Messaging is where support happens. ", count: 20)),
            ]
            let fm = FileManager.default
            for (i, s) in scripts.enumerated() {
                let u = try store.write(s.1, name: s.0)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(i) * 3600)], ofItemAtPath: u.path)
            }
            let editor = ScriptEditorModel(store: store, writer: BrainScriptWriter())
            controller.prompter.editor = editor
            if let first = editor.entries.first(where: { $0.name == "Northwind Labs pitch" }) { editor.open(first) }
        }

        // prepare

        private func fillPrepare() {
            conversation.thread = "Mara Castellan · 14 Oct\nHi Dana, thanks for the call last week. We'd like to go deeper on the internal tools: the shift planner and the reminder agent are the two we'd turn into a SaaS first. Could you walk us through how you'd scope a v1?"
            conversation.postingLink = "linkedin.com/jobs/view/0000000000"
            conversation.companyURL = "northwindlabs.com"
            conversation.note = "Ask who owns pricing and the SaaS roadmap"
            let cal = Calendar.current
            let soon = Date().addingTimeInterval(4 * 60)
            let tomorrow = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
            upNext.setItems([
                HomeUpNextItem(id: "a", title: "Mara · Northwind Labs", meta: "\(L10n.tr("Today")) \(soon.formatted(HomeFormat.time)) · Comet · \(L10n.tr("in \(4) minutes"))",
                               session: "mara-northwindlabs"),
                HomeUpNextItem(id: "b", title: "Design review with Ingrid", meta: "\(L10n.tr("Tomorrow")) \(tomorrow.formatted(HomeFormat.time)) · Zoom", session: nil),
            ])
        }

        // practice

        private func fillPractice() {
            sim.postingLink = "brightwave.com/careers/ai-engineer"
            sim.pasteText = "AI Engineer · Brightwave\nRemote, Europe. You'll build the agents that answer e-commerce customers on WhatsApp and email, own evaluation, and ship weekly with a team of six. You have shipped LLM features to production and care about evals."
            sim.usePastedText()
            sim.confirmPosting()
            sim.setup.type = .technical
            sim.setup.lengthMin = 30
            sim.setup.mode = .coach
        }
    }
}

/// Render only: a runner that answers `prep me show` with a fixed report and does nothing else.
final class PreviewMeRunner: MeRunning, @unchecked Sendable {
    var showOutput: String
    init(showOutput: String) { self.showOutput = showOutput }
    func run(_ action: MeAction, profileDir: URL, brainDir: URL, fake: Bool, onLine: @escaping @Sendable (String) -> Void) async -> MeOutcome {
        .done(stdout: action == .show ? showOutput : profileDir.path, log: [])
    }
    func cancel() {}
}

// MARK: - The mockups' wallpaper (design/mockups/Sources/VerseMockups/Wallpapers.swift), render only

private struct RenderWallpaper: View {
    var dark: Bool

    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                if !dark {
                    LinearGradient(colors: [hex(0xA9CBE6), hex(0xDCE7EE), hex(0xF3E3CC)], startPoint: .top, endPoint: .bottom)
                    Circle().fill(hex(0xFFF6E4)).frame(width: w * 0.16).position(x: w * 0.78, y: h * 0.22).blur(radius: 2)
                    RenderDune(peak: 0.42, shift: 0.0).fill(hex(0xE8C9A4)).frame(height: h * 0.62).offset(y: h * 0.19)
                    RenderDune(peak: 0.66, shift: 0.3).fill(hex(0xD9A577)).frame(height: h * 0.48).offset(y: h * 0.26)
                    RenderDune(peak: 0.25, shift: 0.55).fill(hex(0xC27F53)).frame(height: h * 0.34).offset(y: h * 0.33)
                    RenderDune(peak: 0.80, shift: 0.15).fill(hex(0x9C5A3A)).frame(height: h * 0.18).offset(y: h * 0.41)
                } else {
                    LinearGradient(colors: [hex(0x070B14), hex(0x121C2C), hex(0x1F2B3B)], startPoint: .top, endPoint: .bottom)
                    ForEach(0..<40, id: \.self) { i in
                        Circle().fill(Color.white.opacity(0.25 + Double(i % 4) * 0.15))
                            .frame(width: CGFloat(1 + i % 3), height: CGFloat(1 + i % 3))
                            .position(x: w * CGFloat((i * 37 % 100)) / 100, y: h * CGFloat((i * 53 % 45)) / 100)
                    }
                    if h > 600 {
                        Circle().fill(hex(0xE9E4D6)).frame(width: w * 0.07).position(x: w * 0.965, y: h * 0.09)
                    }
                    RenderDune(peak: 0.42, shift: 0.0).fill(hex(0x2A3A50)).frame(height: h * 0.62).offset(y: h * 0.19)
                    RenderDune(peak: 0.66, shift: 0.3).fill(hex(0x34485F)).frame(height: h * 0.48).offset(y: h * 0.26)
                    RenderDune(peak: 0.25, shift: 0.55).fill(hex(0x1B2738)).frame(height: h * 0.34).offset(y: h * 0.33)
                    RenderDune(peak: 0.80, shift: 0.15).fill(hex(0x111A27)).frame(height: h * 0.18).offset(y: h * 0.41)
                }
            }
        }
    }
}

private struct RenderDune: Shape {
    var peak: CGFloat
    var shift: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * (0.55 + shift * 0.3)))
        p.addCurve(to: CGPoint(x: r.minX + r.width * peak, y: r.minY),
                   control1: CGPoint(x: r.minX + r.width * peak * 0.4, y: r.minY + r.height * 0.5),
                   control2: CGPoint(x: r.minX + r.width * peak * 0.7, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * (0.35 + shift * 0.4)),
                   control1: CGPoint(x: r.minX + r.width * (peak + (1 - peak) * 0.3), y: r.minY),
                   control2: CGPoint(x: r.minX + r.width * (peak + (1 - peak) * 0.6), y: r.minY + r.height * 0.3))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
