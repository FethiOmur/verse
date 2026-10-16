import AppKit
import ScreenCaptureKit
import SwiftUI
import VersePrompter

// `Verse --render-home DIR`: every home page over the mockups' wallpaper, 1280 x 800 pt at 2x, light and dark, plus
// Prepare under Reduce Transparency and Increase Contrast. The same canvas, window frame (1100 x 680) and wallpaper as
// design/mockups, so a render lines up with the approved PNGs. Fixture data only; nothing reads or writes the user's
// sessions or settings.
//
// Render-only differences from the app: the window glass is SwiftUI's in-window `glassEffect` over the wallpaper (the app
// uses a behind-window AppKit sheet, HomeGlass.swift), and the traffic lights are drawn, not real.

@MainActor
public enum HomeRender {
    public static let canvas = CGSize(width: 1280, height: 800)

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
            Variant(suffix: "", override: nil, pages: HomePage.allCases),
            Variant(suffix: "-reduce-transparency", override: HomeA11yOverride(reduceTransparency: true), pages: [.prepare]),
            Variant(suffix: "-increase-contrast", override: HomeA11yOverride(increaseContrast: true), pages: [.prepare]),
        ]
        var out: [URL] = []
        for dark in [false, true] {
            // Sessions on a practice run: its report on the reading plate.
            if only?.contains(.sessions) ?? true {
                let router = HomeRouter()
                router.page = .sessions
                router.selectedSession = fixtures.practiceSession
                let url = dir.appendingPathComponent("home-sessions-report-\(dark ? "dark" : "light").png")
                try await capture(Scene(context: fixtures.context(router: router), dark: dark, override: nil), size: canvas, dark: dark, to: url)
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

    // MARK: scene

    struct Scene: View {
        var context: HomeContext
        var dark: Bool
        var override: HomeA11yOverride?

        var body: some View {
            ZStack {
                RenderWallpaper(dark: dark)
                HomeRoot(context: context, a11yOverride: override ?? HomeA11yOverride(), inWindowGlass: true)
                    .frame(width: 1100, height: 680)
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
        let selectedSession = "Mara · Northwind Labs"
        let practiceSession = "sim-20261013-1000-Brightwave"

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("verse-render-home-\(UUID().uuidString)", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            try fm.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            let suite = "dev.fethiverse.verse.render-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            settings = AppSettings(defaults: defaults)
            simSettings = SimSettings(defaults: defaults)
            controller = VerseController(settings: settings)
            sim = SimController(settings: settings, simSettings: simSettings, meeting: controller)
            conversation = ConversationController(settings: settings, meeting: controller)
            try Self.writeSessions(into: sessionsRoot)
            sessions = HomeSessionsModel(root: sessionsRoot)
            upNext = HomeUpNextModel(settings: settings, meeting: controller.meeting.settings, sessions: { [] })
            settings.sessionName = "mara-northwindlabs"
            try fillScripts()
            fillPrepare()
            fillPractice()
        }

        func context(router: HomeRouter) -> HomeContext {
            HomeContext(settings: settings, controller: controller, simSettings: simSettings, sim: sim, conversation: conversation,
                        sessions: sessions, upNext: upNext, router: router)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

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

        static let summaryText = """
        # Meeting summary

        _generated fixture_

        ## Summary

        Mara wants the appointment reminder and the recall-followup agent turned into one SaaS for independent dental clinics. He owns pricing; Marta owns onboarding. Budget is EUR 4–6k a month for a contractor, starting in November.

        ## Actions

        - Send a one-page v1 scope by Friday
        - Ask Marta for three agency logins to test with
        - Price the recall-followup agent per location, not per seat
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
                Northwind Labs keeps local businesses on the first screen of Maps. I build the tools that turn that into a product your team can sell without me in the room.

                [pause, look at Mara]

                ---

                Two of your internal tools are already most of a SaaS: the appointment reminder and the recall-followup agent. A v1 is one login, one agency, fifty locations, and a weekly report the owner actually reads.

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
            conversation.thread = "Mara Castellan · 14 Oct\nHi Alex, thanks for the call last week. We'd like to go deeper on the internal tools: the appointment reminder and the recall-followup agent are the two we'd turn into a SaaS first. Could you walk us through how you'd scope a v1?"
            conversation.postingLink = "linkedin.com/jobs/view/9876543210"
            conversation.companyURL = "northwindlabs.com"
            conversation.note = "Ask who owns pricing and the SaaS roadmap"
            let cal = Calendar.current
            let soon = Date().addingTimeInterval(4 * 60)
            let tomorrow = cal.date(bySettingHour: 10, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
            upNext.setItems([
                HomeUpNextItem(id: "a", title: "Mara · Northwind Labs", meta: "Today \(soon.formatted(HomeFormat.time)) · Comet · in 4 minutes",
                               session: "mara-northwindlabs"),
                HomeUpNextItem(id: "b", title: "Design review with Ingrid", meta: "Tomorrow \(tomorrow.formatted(HomeFormat.time)) · Zoom", session: nil),
            ])
        }

        // practice

        private func fillPractice() {
            sim.postingLink = "brightwave.example/careers/ai-engineer"
            sim.pasteText = "AI Engineer · Brightwave\nRemote, Europe. You'll build the agents that answer e-commerce customers on WhatsApp and email, own evaluation, and ship weekly with a team of six. You have shipped LLM features to production and care about evals."
            sim.usePastedText()
            sim.confirmPosting()
            sim.setup.type = .technical
            sim.setup.lengthMin = 30
            sim.setup.mode = .coach
        }
    }
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
