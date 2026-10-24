import AppKit
import SwiftUI
@testable import VerseUI
import XCTest

/// Renders the Ask panel on its own (340 pt wide, light and dark) in every state of the redesign: the empty state, a question being
/// thought about, a partial answer, a failed question, and a three-turn chat with a hovered citation. Off unless
/// `VERSE_RENDER_ASK_DIR` names a folder: `VERSE_RENDER_ASK_DIR=~/out swift test --filter AskPanelRenderTests`. Fictional data only.
@MainActor
final class AskPanelRenderTests: XCTestCase {
    /// The Brightwave call's lines that the fictional chat cites.
    private static let lines: [String: AskCitedLine] = [
        "0:14": AskCitedLine(speaker: "Lena", text: "Thanks for joining, the owner. I'm Lena, I lead platform at Brightwave. Before we dive in, can you tell me what you built at your last company?"),
        "1:20": AskCitedLine(speaker: "Lena", text: "Six days to two is a big claim. How did you measure it, and what was the baseline?"),
        "2:10": AskCitedLine(speaker: "Lena", text: "Okay. And what did you stop doing to get there?"),
        "4:05": AskCitedLine(speaker: "Lena", text: "Let's talk about the team. How do you work with someone who disagrees with a technical decision of yours?"),
        "4:41": AskCitedLine(speaker: "the owner", text: "I write down what would change my mind, and then we try the smaller option first. Last year that meant a nightly matching job instead of a real-time one, and nobody missed the real-time version."),
        "21:20": AskCitedLine(speaker: "Lena", text: "Sorry, my connection dropped. Where were we? Right, disagreement. One last thing: what would you need in your first month?"),
        "21:47": AskCitedLine(speaker: "the owner", text: "A sandbox account, one person who owns the data export, and the last two post-mortems. I would rather read how things broke than how they are meant to work."),
        "22:06": AskCitedLine(speaker: "Lena", text: "That is easy to arrange. Thank you, the owner, we will come back to you by Friday."),
    ]

    func testRenderTheAskPanelStates() async throws {
        guard let raw = ProcessInfo.processInfo.environment["VERSE_RENDER_ASK_DIR"] else { throw XCTSkip("set VERSE_RENDER_ASK_DIR to render the Ask panel") }
        let out = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let states: [(String, AskRenderState)] = [
            ("chat", AskRenderState(draft: "What should I say next time?")),
            ("hover", AskRenderState(hover: .init(question: "q4", stamp: "22:06"))),
            ("hover-top", AskRenderState(hover: .init(question: "q2", stamp: "1:20"))),
            ("empty", AskRenderState(script: .empty)),
            ("thinking", AskRenderState(script: .thinking)),
            ("streaming", AskRenderState(script: .streaming)),
            ("failed", AskRenderState(script: .failed)),
        ]
        for dark in [false, true] {
            for (name, state) in states {
                let png = try await render(state, dark: dark)
                try png.write(to: out.appendingPathComponent("ask-panel-\(name)-\(dark ? "dark" : "light").png"))
            }
            // The whole three-turn conversation at once (a tall panel), with the citation card.
            let tall = try await render(AskRenderState(hover: .init(question: "q4", stamp: "22:06")), dark: dark, height: 1100)
            try tall.write(to: out.appendingPathComponent("ask-panel-conversation-hover-\(dark ? "dark" : "light").png"))
        }
    }

    /// Frames of the stream itself, with the panel running live (no forced state): the thinking line, then a chunk of the answer at
    /// 50, 140 and 400 ms after it arrived, then a second chunk 60 ms after. Shows the soft per-chunk fade, not a typewriter.
    func testRenderTheStreamFadeFrames() async throws {
        guard let raw = ProcessInfo.processInfo.environment["VERSE_RENDER_ASK_DIR"] else { throw XCTSkip("set VERSE_RENDER_ASK_DIR to render the Ask panel") }
        let out = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-askfade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(HomeRender.Fixtures.chat.utf8).write(to: ChatLog.url(sessionDir: dir))
        let session = AskSession(makeBrain: { throw NSError(domain: "render", code: 1) })
        session.launchesBrain = false
        session.open(AskContext(sessionDir: dir, ownerName: "the owner", title: "Brightwave · Lena Brandt", date: Date(), meCore: nil, rows: []))
        session.clearChat()
        let ink = VT.Window(dark: false)
        let size = NSSize(width: 340, height: 520)
        let view = AskPanel(session: session, settings: AppSettings(defaults: UserDefaults(suiteName: "dev.example.verse.test-panel-render")),
                            stamps: Set(Self.lines.keys), lines: Self.lines, onCitation: { _ in }, onClose: {})
            .environment(\.homeInk, ink).environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height).background(ink.background)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        Self.park(window)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(700))

        func shot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("ask-fade-\(name).png"))
        }
        session.send("What did Lena ask me?")
        try await Task.sleep(for: .milliseconds(450))
        try shot("0-thinking")
        let q = try XCTUnwrap(session.turns.last?.id)
        session.handle(.delta(question: q, text: "She asked four things: what you built at your last company [0:14], how you measured the six-days-to-two claim [1:20]"))
        let t0 = ContinuousClock.now
        var frames: [(String, Int)] = [("1-chunk", 50), ("2-chunk", 140), ("3-chunk", 400)]
        for (name, ms) in frames {
            let wait = Duration.milliseconds(ms) - (ContinuousClock.now - t0)
            if wait > .zero { try await Task.sleep(for: wait) }
            try shot(name)
        }
        frames = []
        session.handle(.delta(question: q, text: ", what you stopped doing to get there [2:10], and how you handle a technical disagreement [4:05]."))
        try await Task.sleep(for: .milliseconds(70))
        try shot("4-second-chunk")
        try await Task.sleep(for: .milliseconds(500))
        try shot("5-settled")
    }

    /// Where `HomeRender` parks its capture window: just below the screen with 2 pt in view, behind everything, so it counts as visible
    /// (animations and timelines run) without showing anything to the person at the machine.
    private static func park(_ window: NSWindow) {
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        if let s = NSScreen.main { window.setFrameOrigin(NSPoint(x: s.frame.midX - window.frame.width / 2, y: s.frame.minY - window.frame.height + 2)) }
        window.orderBack(nil)
    }

    private func render(_ state: AskRenderState, dark: Bool, height: CGFloat = 760) async throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-askrender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(HomeRender.Fixtures.chat.utf8).write(to: ChatLog.url(sessionDir: dir))
        let session = AskSession(makeBrain: { throw NSError(domain: "render", code: 1) })
        session.launchesBrain = false
        session.open(AskContext(sessionDir: dir, ownerName: "the owner", title: "Brightwave · Lena Brandt", date: Date(), meCore: nil, rows: []))
        session.applyRender(state)
        let ink = VT.Window(dark: dark)
        let size = NSSize(width: 340, height: height)
        let view = AskPanel(session: session, settings: AppSettings(defaults: UserDefaults(suiteName: "dev.example.verse.test-panel-render")),
                            stamps: Set(Self.lines.keys), lines: Self.lines, onCitation: { _ in }, onClose: {})
            .environment(\.homeInk, ink)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.askRender, state)
            .frame(width: size.width, height: size.height)
            .background(ink.background)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        Self.park(window)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
