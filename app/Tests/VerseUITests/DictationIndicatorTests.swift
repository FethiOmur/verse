import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI
@testable import VerseUI
import XCTest

/// Gap G5: the recording indicator, shown as an island hanging from the notch. Its stages follow the controller (preparing
/// until the first audio, recording, finishing), it hides during a run and with the setting off, the live text keeps its
/// newest words, the island hangs from the notch like the meeting island, and the view renders on the island's glass and
/// veil (PNG files when `VERSE_SNAPSHOT_DIR` is set).
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

        // The app's measured cut: three lines of the island's text column (the panel width less the card's insets).
        XCTAssertEqual(R.textLines, 3)
        XCTAssertEqual(R.textWidth, IslandWidth.status - 2 * VT.islandCardInset)
        let long = "So the plan for tomorrow is to meet the team at nine, go through the open issues one by one and then " +
            "decide which of them we can close before the release on Friday afternoon, and after that we write the notes " +
            "for the people who could not join, so that nobody has to ask again what was decided and why it was decided"
        let cut = R.measuredTail(long)
        XCTAssertTrue(cut.hasPrefix("…"))
        XCTAssertTrue(cut.hasSuffix("what was decided and why it was decided"), cut)
        XCTAssertTrue(R.fits(cut, width: R.textWidth - 6, lines: 3))
        XCTAssertFalse(R.fits(cut, width: R.textWidth - 6, lines: 2), "it uses the third line")
        XCTAssertFalse(R.fits("…" + long, width: R.textWidth - 6, lines: 3))
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

    // MARK: notices

    /// Notices show in the island, except the two that come while a run holds the notch.
    func testNoticesShowInTheIslandExceptDuringARun() {
        XCTAssertFalse(DictationNotice.busy.showsInIsland)
        XCTAssertFalse(DictationNotice.cancelledByRun.showsInIsland)
        for n: DictationNotice in [.notInserted, .copiedToClipboard, .nothingHeard, .failed("x"), .cancelled, .microphoneSilent,
                                   .microphoneSilentNothingInserted] {
            XCTAssertTrue(n.showsInIsland, "\(n)")
        }
        XCTAssertTrue(DictationNotice.failed("x").isFailure)
        XCTAssertFalse(DictationNotice.notInserted.isFailure)
        let p = StatusPanelView.split(DictationNotice.notInserted.text)
        XCTAssertEqual(p.headline, "Not inserted.")
        XCTAssertEqual(p.line, "It is on the clipboard: press ⌘V")
    }

    // MARK: geometry

    private static func islandSize(_ content: DictationIndicatorContent?, notice: DictationNotice? = nil,
                                   metrics: NotchMetrics = .macBookPro) -> CGSize {
        let host = NSHostingView(rootView: DictationIslandView(content: content, notice: notice, metrics: metrics))
        return host.fittingSize
    }

    /// The island hangs from the notch as the meeting island does: the window is exactly the surface, its top edge the
    /// screen's top edge, centred on the camera housing (also on a second screen and on one without a notch).
    func testIslandHangsFromTheNotchCentredWithItsTopEdgeFlushWithTheScreenTop() {
        let m = NotchMetrics.macBookPro
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        for (content, notice) in [(DictationIndicatorContent(stage: .recording, elapsed: 5, showsText: false), nil),
                                  (DictationIndicatorContent(stage: .recording, text: "Some words", language: "en"), nil),
                                  (nil, DictationNotice.notInserted)] as [(DictationIndicatorContent?, DictationNotice?)] {
            let size = Self.islandSize(content, notice: notice)
            let f = NotchPanelController.islandFrame(contentSize: size, screenFrame: screen, centerX: 756, metrics: m)
            XCTAssertEqual(f.maxY, screen.maxY, "flush with the screen's top edge")
            XCTAssertEqual(f.midX, 756, accuracy: 0.5, "centred on the notch")
            XCTAssertEqual(f.width, ceil(size.width))
            XCTAssertEqual(f.height, ceil(size.height))
        }
        // A notch off the screen's middle, on a screen to the right of another.
        let right = NSRect(x: 1512, y: -98, width: 1728, height: 1117)
        let f = NotchPanelController.islandFrame(contentSize: CGSize(width: 480, height: 90), screenFrame: right, centerX: 2380, metrics: m)
        XCTAssertEqual(f.maxY, right.maxY)
        XCTAssertEqual(f.midX, 2380, accuracy: 0.5)

        // No notch: a notch-sized island as tall as the menu bar, as the meeting island.
        let flat = NotchMetrics(notchWidth: 186, notchHeight: 24, hasNotch: false)
        let compact = Self.islandSize(DictationIndicatorContent(stage: .recording, showsText: false), metrics: flat)
        XCTAssertEqual(compact.height, flat.capsuleHeight)
        XCTAssertEqual(compact.width, flat.listeningWidth)
    }

    /// The meeting island can be up with no run (a meeting prompt, an offline status), so dictation is allowed while it
    /// shows: the dictation island then hangs just below it, never on top of it (its window ignores the mouse, so a cover
    /// would send clicks to the prompt's buttons underneath). A meeting island elsewhere leaves it at the notch.
    func testIslandHangsBelowAVisibleMeetingIslandInsteadOfCoveringIt() {
        let island = NSRect(x: 556, y: 900, width: 400, height: 82)
        let prompt = NSRect(x: 536, y: 862, width: 440, height: 120)
        let f = DictationIndicatorPanel.frame(island: island, avoiding: prompt)
        XCTAssertFalse(f.intersects(prompt))
        XCTAssertEqual(f.maxY, prompt.minY - DictationIndicatorPanel.meetingGap)
        XCTAssertEqual(f.midX, island.midX)
        XCTAssertEqual(f.size, island.size)
        XCTAssertEqual(DictationIndicatorPanel.frame(island: island, avoiding: nil), island)
        let otherScreen = NSRect(x: 2000, y: 900, width: 440, height: 120)
        XCTAssertEqual(DictationIndicatorPanel.frame(island: island, avoiding: otherScreen), island)
    }

    /// The panel itself: a meeting island that appears while the dictation island is up moves it below; when the meeting
    /// island goes, it hangs from the notch again.
    func testIndicatorPanelMovesBelowTheMeetingIslandAndBack() async throws {
        let model = DictationIndicatorModel(settings: DictationSettings(defaults: defaults()),
                                            ticker: { _, _ in AnyCancellable {} }, now: { 0 })
        let panel = DictationIndicatorPanel(model: model)
        var meeting: NSRect?
        panel.meetingIsland = { meeting }
        panel.show(.notInserted, for: .seconds(30))
        defer { panel.clearNotice() }
        let hanging = try XCTUnwrap(panel.visibleFrame)
        meeting = NSRect(x: hanging.midX - 220, y: hanging.maxY - 140, width: 440, height: 140)
        panel.meetingIslandChanged()
        let below = try XCTUnwrap(panel.visibleFrame)
        XCTAssertFalse(below.intersects(meeting!), "never on top of the meeting island")
        XCTAssertEqual(below.maxY, meeting!.minY - DictationIndicatorPanel.meetingGap)
        meeting = nil
        panel.meetingIslandChanged()
        XCTAssertEqual(panel.visibleFrame, hanging, "back at the notch")
        panel.clearNotice()
        XCTAssertNil(panel.visibleFrame)
    }

    /// The band is the notch's height; live text grows the island downward line by line up to three lines; preparing,
    /// finishing and a notice take the body's place; with live text off only the band shows.
    func testIslandGrowsDownwardForTheTextAndIsTheBandAloneWithLiveTextOff() {
        let m = NotchMetrics.macBookPro
        for stage in [DictationIndicatorStage.preparing, .recording, .finishing] {
            let size = Self.islandSize(DictationIndicatorContent(stage: stage, elapsed: 3, text: "ignored", showsText: false, language: "tr"))
            XCTAssertEqual(size.height, m.capsuleHeight, "\(stage): the band alone")
            XCTAssertEqual(size.width, IslandWidth.listeningWidth(wingText: DictationIslandView.wingSample(
                DictationIndicatorContent(stage: stage, language: "tr")), metrics: m), "\(stage)")
        }
        let line = "One short line"
        let two = DictationIndicatorRules.measuredTail(String(repeating: "word ", count: 18))
        let many = String(repeating: "and then some more words ", count: 30)
        let h1 = Self.islandSize(DictationIndicatorContent(stage: .recording, text: line)).height
        let h2 = Self.islandSize(DictationIndicatorContent(stage: .recording, text: two)).height
        let h3 = Self.islandSize(DictationIndicatorContent(stage: .recording, text: DictationIndicatorRules.measuredTail(many))).height
        let hRaw = Self.islandSize(DictationIndicatorContent(stage: .recording, text: many)).height
        XCTAssertGreaterThan(h1, m.capsuleHeight + 20, "one line under the band")
        XCTAssertGreaterThan(h2, h1 + 12, "a second line grows it")
        XCTAssertGreaterThan(h3, h2 + 12, "a third line grows it")
        XCTAssertEqual(hRaw, h3, accuracy: 0.5, "never more than three lines")
        XCTAssertEqual(Self.islandSize(DictationIndicatorContent(stage: .recording, text: line)).width, DictationIslandView.bodyWidth)

        let listening = Self.islandSize(DictationIndicatorContent(stage: .recording)).height
        let preparing = Self.islandSize(DictationIndicatorContent(stage: .preparing)).height
        let finishing = Self.islandSize(DictationIndicatorContent(stage: .finishing, text: two)).height
        XCTAssertEqual(preparing, finishing, accuracy: 0.5)
        XCTAssertEqual(listening, preparing, accuracy: 2, "the island holds still from preparing to listening")
        let notice = Self.islandSize(nil, notice: .notInserted)
        XCTAssertGreaterThan(notice.height, preparing, "a headline and a line")
        XCTAssertEqual(notice.width, DictationIslandView.bodyWidth)
        XCTAssertEqual(Self.islandSize(DictationIndicatorContent(stage: .recording, showsText: false), notice: .microphoneSilent).width,
                       DictationIslandView.bodyWidth, "a notice during a dictation grows the compact island")
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
        "Let me check the numbers again before we send the summary, because the second quarter looked a bit too good to be " +
        "true, and I would rather ask the team for the raw figures today than explain a mistake to everyone next week"

    private static func snapshotStates() -> [(String, DictationIndicatorContent?, DictationNotice?)] {
        let sample = DictationIndicatorRules.measuredTail(snapshotSample)
        return [
            ("preparing", DictationIndicatorContent(stage: .preparing, language: "en"), nil),
            ("listening", DictationIndicatorContent(stage: .recording, elapsed: 1, levels: [0.2, 0.5, 0.3], language: "en"), nil),
            ("recording", DictationIndicatorContent(stage: .recording, elapsed: 12, levels: [0.3, 0.8, 0.55], text: sample, language: "en"), nil),
            ("finishing", DictationIndicatorContent(stage: .finishing, elapsed: 14, text: sample, language: "en"), nil),
            ("recording-compact", DictationIndicatorContent(stage: .recording, elapsed: 7, levels: [0.5, 0.2, 0.9], showsText: false,
                                                            language: "en"), nil),
            ("not-inserted", nil, .notInserted),
        ]
    }

    /// Renders the island's states offscreen over a light and a dark page, hanging from the top edge. `cacheDisplay` cannot
    /// draw the window-server glass, so this checks the SwiftUI half: the band is black around the notch, the veil darkens
    /// the page under the body, outside the silhouette the page shows, and the dot and text are brighter than the veil.
    /// Reduce Transparency draws the solid surface. With `VERSE_SNAPSHOT_DIR` set, also writes PNG files there.
    func testIslandViewRendersItsStatesOnTheIslandVeil() throws {
        let dir = ProcessInfo.processInfo.environment["VERSE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let m = NotchMetrics.macBookPro
        let pages: [(String, Color, Double)] = [("light", Color(white: 0.961), 0.961), ("dark", Color(white: 0.114), 0.114)]
        var solid: [Double] = []
        let states = Self.snapshotStates().map { ($0.0, $0.1, $0.2, IslandA11y()) }
            + [("recording-reduce-transparency", Self.snapshotStates()[2].1, nil, IslandA11y(reduceTransparency: true)),
               ("recording-increase-contrast", Self.snapshotStates()[2].1, nil, IslandA11y(increaseContrast: true))]
        for (name, content, notice, a11y) in states {
            for (pageName, page, pageLum) in pages {
                let label = "\(name)/\(pageName)"
                let view = DictationIslandView(content: content, notice: notice, metrics: m)
                    .environment(\.islandA11yOverride, a11y)
                    .padding(.horizontal, 24).padding(.bottom, 24).background(page)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                let w = DictationIslandView.width(content: content, notice: notice, metrics: m)
                XCTAssertEqual(size.width, w + 48, accuracy: 1, label)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / host.bounds.width
                func lum(_ x: CGFloat, _ y: CGFloat) -> Double {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return -1 }
                    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                }
                let band = m.capsuleHeight
                // The camera gap in the band: black, as the meeting island's band.
                XCTAssertLessThan(lum(host.bounds.midX, band / 2), 0.03, "\(label): the black band")
                XCTAssertEqual(lum(8, 8), pageLum, accuracy: 0.02, "\(label): the page outside the silhouette")
                XCTAssertEqual(lum(24 + 4, 2), pageLum, accuracy: 0.05, "\(label): the concave shoulder shows the page")
                // The left wing: a dot brighter than the band.
                var dot = 0
                for x in stride(from: CGFloat(24 + 20), to: host.bounds.midX - m.notchWidth / 2, by: 0.5) where lum(x, band / 2) > 0.25 { dot += 1 }
                XCTAssertGreaterThan(dot, 0, "\(label): the wing's dot")
                if let dir, let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: dir.appendingPathComponent("dictation-island-\(name)-\(pageName)-offscreen.png"))
                }
                let hasBody = DictationIslandView.hasBody(content: content, notice: notice)
                XCTAssertEqual(size.height - 24 > band + 1, hasBody, "\(label): a body under the band")
                guard hasBody else { continue }
                // Low in the body, left of the text: the veil over the page (or the solid surface).
                let bodyY = size.height - 24 - 30
                let veil = lum(24 + 18, bodyY)
                if a11y.reduceTransparency {
                    solid.append(veil)
                } else {
                    XCTAssertLessThan(veil, pageLum * (1 - 0.62 * 0.75) + 0.03, "\(label): the island veil over the page")
                }
                var text = 0
                for y in stride(from: band + 8, to: size.height - 24 - 16, by: 1) {
                    for x in stride(from: CGFloat(24 + VT.islandCardInset), to: 24 + w - VT.islandCardInset, by: 1) where lum(x, y) > veil + 0.25 {
                        text += 1
                    }
                }
                XCTAssertGreaterThan(text, 20, "\(label): text on the veil")
            }
        }
        XCTAssertEqual(solid.count, 2)
        XCTAssertEqual(solid[0], solid[1], accuracy: 0.02, "Reduce Transparency: the solid surface, whatever the page")
    }

    /// Look by eye, with the real Liquid Glass: only with `VERSE_SNAPSHOT_DIR` set. Each state is drawn in the island's
    /// mock scene (wallpaper, menu bar, the notch, a document page or a video call) in a window placed below the screen's
    /// edge and captured with ScreenCaptureKit, as `Verse --render-screens` does; meeting-island shots go beside them.
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
            for (name, content, notice) in Self.snapshotStates() {
                try await Self.captureInScene(content: content, notice: notice, backdrop: b,
                                              to: dir.appendingPathComponent("dictation-island-\(name)-\(b.rawValue)-glass.png"))
            }
        }
    }

    /// `ScreenRenderer.render`'s scene with the dictation island in the meeting island's place.
    private static func captureInScene(content: DictationIndicatorContent?, notice: DictationNotice?, backdrop: ScreenRenderer.Backdrop,
                                       to url: URL) async throws {
        let canvas = ScreenRenderer.canvas
        let metrics = NotchMetrics.macBookPro
        let wallpaper: MockWallpaper = backdrop == .white ? .light : .dark
        let scene = ZStack(alignment: .top) {
            MockWallpaperView(kind: wallpaper)
            VStack(spacing: 0) {
                MockMenuBar(kind: wallpaper)
                MockAppUnderIsland(kind: wallpaper).padding(.horizontal, 36).padding(.top, 10)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous).fill(Color.black)
                .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            DictationIslandView(content: content, notice: notice, metrics: metrics)
                .environment(\.islandA11yOverride, IslandA11y())
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
