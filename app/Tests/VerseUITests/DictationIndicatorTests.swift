import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI
@testable import VerseUI
import XCTest

/// Gap G5: the recording indicator. Its stages follow the controller (preparing until the first audio, recording, finishing),
/// it hides during a run and with the setting off, the live text keeps its newest words, and the view renders on the island's
/// glass and veil (PNG files when `VERSE_SNAPSHOT_DIR` is set).
extension DictationTests {

    // MARK: rules

    func testIndicatorStageTableLevelScaleAndElapsedLabel() {
        let R = DictationIndicatorRules.self
        XCTAssertNil(R.stage(phase: .idle, audioArrived: false))
        XCTAssertEqual(R.stage(phase: .recording, audioArrived: false), .preparing)
        XCTAssertEqual(R.stage(phase: .recording, audioArrived: true), .recording)
        XCTAssertEqual(R.stage(phase: .finalising, audioArrived: true), .finishing)
        XCTAssertNil(R.stage(phase: .inserting, audioArrived: true), "the paste is not shown; a notice may follow")

        XCTAssertTrue(R.isShown(stage: .recording, runActive: false, enabled: true))
        XCTAssertFalse(R.isShown(stage: .recording, runActive: true, enabled: true), "never during a run")
        XCTAssertFalse(R.isShown(stage: .recording, runActive: false, enabled: false), "the setting is off")
        XCTAssertFalse(R.isShown(stage: nil, runActive: false, enabled: true))

        XCTAssertEqual(R.level(rms: nil), 0)
        XCTAssertEqual(R.level(rms: 0), 0)
        XCTAssertEqual(R.level(rms: 0.0001), 0, "-80 dBFS: silence")
        XCTAssertEqual(R.level(rms: 0.1778), 1, accuracy: 0.01, "-15 dBFS: full")
        XCTAssertEqual(R.level(rms: 0.0178), 0.5, accuracy: 0.01, "-35 dBFS: half")

        XCTAssertEqual(R.elapsedLabel(0), "00:00")
        XCTAssertEqual(R.elapsedLabel(65.9), "01:05")
        XCTAssertEqual(R.elapsedLabel(3661), "61:01")
    }

    func testIndicatorTextIsCutAtTheHeadSoTheNewestWordsStayVisible() {
        let R = DictationIndicatorRules.self
        XCTAssertEqual(R.tail("short", maxCharacters: 12), "short")
        XCTAssertEqual(R.tail("one two three four five six", maxCharacters: 12), "…five six")
        XCTAssertEqual(R.tail("first line\nsecond  line", maxCharacters: 40), "first line second line", "line breaks show as spaces")
        XCTAssertEqual(R.tail("supercalifragilistic", maxCharacters: 8), "…ilistic", "one long word is cut inside")
        XCTAssertEqual(R.tail("", maxCharacters: 8), "")

        // The app's measured cut: two lines of the indicator's text column.
        let long = "So the plan for tomorrow is to meet the team at nine, go through the open issues one by one and then " +
            "decide which of them we can close before the release on Friday afternoon"
        let cut = R.measuredTail(long)
        XCTAssertTrue(cut.hasPrefix("…"))
        XCTAssertTrue(cut.hasSuffix("before the release on Friday afternoon"), cut)
        XCTAssertTrue(R.fits(cut, width: R.textWidth - 6, lines: 2))
        XCTAssertFalse(R.fits("…" + long, width: R.textWidth - 6, lines: 2))
        XCTAssertEqual(R.measuredTail("Hello there"), "Hello there")
    }

    /// A notice goes under the indicator on the indicator's screen, even when the main screen changed since it appeared.
    func testNoticeIsPlacedUnderTheIndicatorOnTheIndicatorsScreen() {
        let left = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visible: NSRect(x: 0, y: 0, width: 1440, height: 875))
        let right = (frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080), visible: NSRect(x: 1440, y: 0, width: 1920, height: 1055))
        let size = CGSize(width: 300, height: 36)
        let indicator = NSRect(x: 520, y: 831, width: 400, height: 34)   // top centre of the left screen

        let f = DictationHUD.frame(size: size, screens: [left, right], mainVisible: right.visible, avoid: indicator)
        XCTAssertEqual(f.midX, left.visible.midX, "centred on the indicator's screen, not the main one")
        XCTAssertEqual(f.maxY, indicator.minY - DictationHUD.indicatorGap)

        let alone = DictationHUD.frame(size: size, screens: [left, right], mainVisible: right.visible, avoid: nil)
        XCTAssertEqual(alone.midX, right.visible.midX, "no indicator: the main screen")
        XCTAssertEqual(alone.maxY, right.visible.maxY - DictationHUD.topGap)
    }

    // MARK: following the controller

    func testIndicatorFollowsADictationFromPreparingToFinishingAndHidesAfter() async {
        let r = rig { $0.audioSeconds = 0; $0.holdFinish = true; $0.finishText = "hello world" }
        XCTAssertNil(r.controller.indicator.content)

        await r.controller.press()
        XCTAssertEqual(r.controller.indicator.content?.stage, .preparing, "no audio yet")
        XCTAssertEqual(r.indicatorTicker.running, 1)
        XCTAssertEqual(r.indicatorTicker.intervals, [DictationIndicatorModel.tickInterval])

        let t = try! XCTUnwrap(r.last)
        r.clock.t = 1
        t.audioSeconds = nil           // audio flows from now on
        t.meterLevel = 0.05
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.stage, .recording)
        XCTAssertEqual(r.controller.indicator.content?.elapsed, 0, "the time starts at the first audio")
        XCTAssertGreaterThan(r.controller.indicator.content?.levels.last ?? 0, 0.5)

        r.clock.t = 4
        t.liveText = "hello wor"
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.elapsed, 3)
        XCTAssertEqual(r.controller.indicator.content?.text, "hello wor", "finals plus the volatile tail, as the engine has them")

        let stop = Task { await r.controller.press() }
        for _ in 0..<2000 where t.finishHeld == false { await Task.yield() }
        XCTAssertEqual(r.controller.phase, .finalising)
        r.clock.t += 5
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.stage, .finishing)
        XCTAssertEqual(r.controller.indicator.content?.elapsed, 3, "frozen at the stop press")

        t.releaseFinish()
        await stop.value
        XCTAssertEqual(r.inserter.calls.map(\.text), ["hello world"])
        XCTAssertNil(r.controller.indicator.content, "hidden once the dictation is over")
        XCTAssertEqual(r.indicatorTicker.running, 0, "no ticking while hidden")
    }

    func testIndicatorHidesWhenARunStartsAndOnCancel() async {
        let r = rig()
        let runs = PassthroughSubject<Bool, Never>()
        r.controller.observeRuns(runs)
        await r.controller.press()
        XCTAssertNotNil(r.controller.indicator.content)
        runs.send(true)
        XCTAssertNil(r.controller.indicator.content, "never shown during a meeting run")
        XCTAssertEqual(r.indicatorTicker.running, 0)
        runs.send(false)

        await r.controller.press()
        XCTAssertNotNil(r.controller.indicator.content)
        r.controller.cancelByKey()
        XCTAssertNil(r.controller.indicator.content, "Esc hides it; the notice says what happened")

        // A run reported while the model would otherwise show (belt and braces: dictation cannot start during a run).
        let t = DictationTests.FakeTranscriber()
        r.controller.indicator.update(phase: .recording, source: t, runActive: true)
        XCTAssertNil(r.controller.indicator.content)
        r.controller.indicator.update(phase: .idle, source: nil, runActive: false)
    }

    func testIndicatorSettingOffHidesItAndLiveTextOffDropsTheText() async {
        let r = rig()
        r.settings.showIndicator = false
        await r.controller.press()
        XCTAssertNil(r.controller.indicator.content, "the setting is off")
        XCTAssertEqual(r.indicatorTicker.running, 0)

        r.settings.showIndicator = true
        XCTAssertNotNil(r.controller.indicator.content, "turned on mid-dictation: shows at once")
        r.clock.t = 1
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.stage, .recording)
        let t = try! XCTUnwrap(r.last)
        t.liveText = "some words"
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.text, "some words")
        XCTAssertEqual(r.controller.indicator.content?.showsText, true)

        r.settings.indicatorLiveText = false
        XCTAssertEqual(r.controller.indicator.content?.text, "")
        XCTAssertEqual(r.controller.indicator.content?.showsText, false, "the compact layout")
        r.indicatorTicker.fire()
        XCTAssertEqual(r.controller.indicator.content?.text, "", "the live text is not read while off")

        r.settings.showIndicator = false
        XCTAssertNil(r.controller.indicator.content)
        XCTAssertEqual(r.indicatorTicker.running, 0)

        let fresh = DictationSettings(defaults: defaults())
        XCTAssertTrue(fresh.showIndicator, "on by default")
        XCTAssertTrue(fresh.indicatorLiveText, "on by default")
    }

    // MARK: surface

    /// The indicator wears the island's veil: the user's floor, then the island's lower rim easing to 75 % of it over the
    /// last 24 pt; no black head (there is no camera band). Its shape is the island's lower corner, a capsule when short.
    func testIndicatorVeilIsTheIslandsFloorAndRim() {
        let R = DictationIndicatorRules.self
        let tall = R.veilStops(height: 60, floor: 0.62)
        XCTAssertEqual(tall.first, IslandVeil.Stop(location: 0, opacity: 0.62))
        XCTAssertEqual(tall.last?.location ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(tall.last?.opacity ?? 0, 0.62 * IslandVeil.rimFactor, accuracy: 1e-9)
        XCTAssertEqual(tall[1].location, 1 - 24.0 / 60, accuracy: 1e-9, "the rim is the last 24 pt")
        XCTAssertEqual(tall[1].opacity, 0.62, accuracy: 1e-9, "flat floor above the rim")
        for (a, b) in zip(tall, tall.dropFirst()) {
            XCTAssertLessThanOrEqual(a.location, b.location)
            XCTAssertGreaterThanOrEqual(a.opacity + 1e-12, b.opacity, "never darker further down")
        }
        let short = R.veilStops(height: 20, floor: 0.92)
        XCTAssertEqual(short[1].location, 0, "shorter than the rim: all rim")
        XCTAssertEqual(short.last?.opacity ?? 0, 0.92 * 0.75, accuracy: 1e-9)

        XCTAssertEqual(NotchGlassShape.roundedCornerRadius(height: 34), 17, "a capsule")
        XCTAssertEqual(NotchGlassShape.roundedCornerRadius(height: 80), VT.Radius.islandBottom, "the island's lower corner")
    }

    /// The veil's floor is the user's Island opacity, read from the app's defaults as `AppSettings` stores it.
    func testIndicatorReadsTheIslandOpacitySetting() {
        let R = DictationIndicatorRules.self
        let d = defaults()
        XCTAssertEqual(R.islandOpacity(in: d), AppSettings(defaults: d).islandOpacity, "unset: the app's default")
        d.set(0.8, forKey: "islandOpacity")
        XCTAssertEqual(R.islandOpacity(in: d), 0.8)
        XCTAssertEqual(R.islandOpacity(in: d), AppSettings(defaults: d).islandOpacity)
        d.set(0.1, forKey: "islandOpacity")
        XCTAssertEqual(R.islandOpacity(in: d), AppSettings.islandOpacityRange.lowerBound, "clamped like the setting")
        XCTAssertEqual(R.islandOpacity(in: nil), 0.62)
    }

    // MARK: rendering

    private static let snapshotSample =
        "Let me check the numbers again before we send the summary, because the second quarter looked a bit too good to be true"

    private static func snapshotStates() -> [(String, DictationIndicatorContent)] {
        let sample = DictationIndicatorRules.measuredTail(snapshotSample)
        return [
            ("preparing", DictationIndicatorContent(stage: .preparing)),
            ("recording", DictationIndicatorContent(stage: .recording, elapsed: 12, levels: [0.3, 0.8, 0.55], text: sample)),
            ("finishing", DictationIndicatorContent(stage: .finishing, elapsed: 14)),
            ("recording-compact", DictationIndicatorContent(stage: .recording, elapsed: 7, levels: [0.5, 0.2, 0.9], showsText: false)),
        ]
    }

    /// Renders the indicator's states offscreen over a light and a dark page. `cacheDisplay` cannot draw the window-server
    /// glass, so this checks the SwiftUI half: the island's black veil darkens the page under the shape, and the text or
    /// dot on it is brighter than the veil. With `VERSE_SNAPSHOT_DIR` set, also writes them as PNG files there.
    func testIndicatorViewRendersItsStatesOnTheIslandVeil() throws {
        let dir = ProcessInfo.processInfo.environment["VERSE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let pages: [(String, Color, Double)] = [("light", Color(white: 0.961), 0.961), ("dark", Color(white: 0.114), 0.114)]
        for (name, content) in Self.snapshotStates() {
            for (pageName, page, pageLum) in pages {
                let label = "\(name)/\(pageName)"
                let view = DictationIndicatorView(content: content).padding(24).background(page)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                if content.showsText { XCTAssertEqual(size.width, DictationIndicatorView.width + 48, accuracy: 1, label) }
                XCTAssertLessThan(size.height, 48 + 64, "\(label): at most two lines")
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / host.bounds.width
                func lum(_ x: CGFloat, _ y: CGFloat) -> Double {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return -1 }
                    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                }
                let midY = host.bounds.height / 2
                // Inside the shape, left of the dot: veil over the page (the floor is 0.62 black, a little less in the rim).
                let veil = lum(24 + 8, midY)
                XCTAssertEqual(veil, pageLum * (1 - 0.62), accuracy: pageLum * 0.2 + 0.03, "\(label): the island veil over the page")
                XCTAssertEqual(lum(8, midY), pageLum, accuracy: 0.02, "\(label): the page outside the shape")
                var brighter = 0
                for x in stride(from: CGFloat(24 + 16), to: host.bounds.width - 24 - 8, by: 0.5) where lum(x, midY) > veil + 0.25 { brighter += 1 }
                XCTAssertGreaterThan(brighter, 0, "\(label): text or a dot on the veil")
                if let dir, let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: dir.appendingPathComponent("dictation-indicator-\(name)-\(pageName)-offscreen.png"))
                }
            }
        }
    }

    /// Look by eye, with the real Liquid Glass: only with `VERSE_SNAPSHOT_DIR` set. Each state is drawn in the island's
    /// mock scene (wallpaper, menu bar, a document page or a video call) in a window placed below the screen's edge and
    /// captured with ScreenCaptureKit, as `Verse --render-screens` does; two meeting-island shots go beside them.
    func testIndicatorLiveGlassSnapshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["VERSE_SNAPSHOT_DIR"] else {
            throw XCTSkip("VERSE_SNAPSHOT_DIR is not set")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults())
        for b in ScreenRenderer.Backdrop.allCases {
            for shotName in ["island-3-hearing-question", "island-4-answer-card"] {
                guard let shot = ScreenRenderer.sampleShots().first(where: { $0.name == shotName }) else { continue }
                try await ScreenRenderer.render(shot.state, settings: settings, backdrop: b,
                                                to: dir.appendingPathComponent("notch-\(shotName)-\(b.rawValue).png"))
            }
            for (name, content) in Self.snapshotStates() {
                try await Self.captureInScene(content: content, backdrop: b,
                                              to: dir.appendingPathComponent("dictation-indicator-\(name)-\(b.rawValue)-glass.png"))
            }
        }
    }

    private static func captureInScene(content: DictationIndicatorContent, backdrop: ScreenRenderer.Backdrop, to url: URL) async throws {
        let canvas = ScreenRenderer.canvas
        let wallpaper: MockWallpaper = backdrop == .white ? .light : .dark
        let scene = ZStack(alignment: .top) {
            MockWallpaperView(kind: wallpaper)
            VStack(spacing: 0) {
                MockMenuBar(kind: wallpaper)
                MockAppUnderIsland(kind: wallpaper).padding(.horizontal, 36).padding(.top, 10)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous).fill(Color.black)
                .frame(width: NotchMetrics.macBookPro.notchWidth, height: NotchMetrics.macBookPro.notchHeight)
            // Under the 32 pt menu bar, `DictationIndicatorPanel.topGap` below it.
            DictationIndicatorView(content: content).padding(.top, 32 + DictationIndicatorPanel.topGap)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        window.appearance = NSAppearance(named: backdrop == .white ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: scene)
        if let s = NSScreen.main { window.setFrameOrigin(NSPoint(x: s.frame.midX - canvas.width / 2, y: s.frame.minY - canvas.height + 2)) }
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(450))

        let shareable = try await SCShareableContent.currentProcess
        let w = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "window not capturable")
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let px = CGFloat(filter.pointPixelScale)
        cfg.width = Int(canvas.width * px)
        cfg.height = Int(canvas.height * px)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
