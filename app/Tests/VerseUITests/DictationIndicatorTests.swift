import AppKit
import Combine
import SwiftUI
@testable import VerseUI
import XCTest

/// Gap G5: the recording indicator. Its stages follow the controller (preparing until the first audio, recording, finishing),
/// it hides during a run and with the setting off, the live text keeps its newest words, and the view renders in its three
/// states (PNG files when `VERSE_SNAPSHOT_DIR` is set).
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

    // MARK: rendering

    /// Renders the indicator in its three states and checks each drew a dark capsule with light text. With
    /// `VERSE_SNAPSHOT_DIR` set, also writes them as PNG files there (for a look by eye).
    func testIndicatorViewRendersItsThreeStates() throws {
        let sample = DictationIndicatorRules.measuredTail(
            "Let me check the numbers again before we send the summary, because the second quarter looked a bit too good to be true")
        let states: [(String, DictationIndicatorContent)] = [
            ("preparing", DictationIndicatorContent(stage: .preparing)),
            ("recording", DictationIndicatorContent(stage: .recording, elapsed: 12, levels: [0.3, 0.8, 0.55], text: sample)),
            ("finishing", DictationIndicatorContent(stage: .finishing, elapsed: 14)),
            ("recording-compact", DictationIndicatorContent(stage: .recording, elapsed: 7, levels: [0.5, 0.2, 0.9], showsText: false)),
        ]
        let dir = ProcessInfo.processInfo.environment["VERSE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, content) in states {
            let view = DictationIndicatorView(content: content)
                .padding(24)
                .background(Color(red: 0.961, green: 0.961, blue: 0.969))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            if content.showsText { XCTAssertEqual(size.width, DictationIndicatorView.width + 48, accuracy: 1, name) }
            XCTAssertLessThan(size.height, 48 + 64, "\(name): at most two lines")
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var dark = 0, light = 0
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            // The capsule's middle row: island surface plus white text.
            let y = Int((host.bounds.height / 2) * scale)
            for x in stride(from: Int(40 * scale), to: rep.pixelsWide - Int(40 * scale), by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                if lum < 0.1 { dark += 1 } else if lum > 0.45 { light += 1 }
            }
            XCTAssertGreaterThan(dark, 50, "\(name): the dark island surface")
            XCTAssertGreaterThan(light, 0, "\(name): text or a dot on it")
            if let dir, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appendingPathComponent("dictation-indicator-\(name).png"))
            }
        }
    }
}
