import AppKit
import Combine
import Foundation
import VersePrompter
import VerseTurns
@testable import VerseUI
import XCTest

/// UI review fixes on the island: V8 (level bars), V9 (VoiceOver and the hover controls), V10 (wing text fits the
/// listening capsule) and V13 (prompter and script-import messages in the interface language).
@MainActor
final class IslandReviewFixTests: XCTestCase {
    // MARK: V8

    /// Level samples (about ten a second for the whole call) move only `levels`: the model announces no change, so the
    /// overlay (and the card under it) is not re-evaluated for them. Anything else still announces itself.
    func testLevelSamplesDoNotRepublishTheIslandOnlyTheBars() {
        let c = Clock()
        let m = OverlayModel(config: OverlayConfig(), clock: { c.t })
        m.sessionStarting(lang: "en", session: "s", app: "Comet")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        m.apply(turn("r1", "Can you tell me about yourself?"))
        XCTAssertNotNil(m.state.card)

        // Bring the speaking flag up first: that one is a real change of the band (the left wing gets its bars).
        m.apply(.level(remoteDbfs: -20, meDbfs: -30)); c.t += 0.1
        XCTAssertTrue(m.state.remoteSpeaking)

        var modelChanges = 0, barChanges = 0
        let a = m.objectWillChange.sink { modelChanges += 1 }
        let b = m.levels.objectWillChange.sink { barChanges += 1 }
        defer { a.cancel(); b.cancel() }
        for db in [-35.0, -25, -30, -22, -28, -33, -21, -26, -31, -24] {
            m.apply(.level(remoteDbfs: db, meDbfs: db - 5)); c.t += 0.1
        }
        XCTAssertEqual(modelChanges, 0, "level samples must not re-evaluate the whole island")
        XCTAssertGreaterThan(barChanges, 0)
        XCTAssertEqual(m.levels.remote, m.state.remoteBars, "the bars view reads the same values as the state")
        XCTAssertEqual(m.levels.me, m.state.meBars)

        m.collapse()
        XCTAssertEqual(modelChanges, 1, "a real change still announces itself")
    }

    /// The renderer sets whole states; their bars reach the bars views too.
    func testShownStateFeedsTheBars() {
        let m = OverlayModel()
        var s = OverlayState()
        s.remoteBars = [0.45, 0.9, 0.6]
        s.meBars = [0.3, 0.55, 0.4]
        m.show(s)
        XCTAssertEqual(m.levels.remote, [0.45, 0.9, 0.6])
        XCTAssertEqual(m.levels.me, [0.3, 0.55, 0.4])
    }

    // MARK: V9

    /// VoiceOver never moves the pointer: the hover-only controls (Stop, Repeat, Skip, End, the prompter row) show
    /// while it runs, so they are opaque, hit-testable and in the accessibility tree.
    func testVoiceOverCountsAsHover() {
        XCTAssertFalse(OverlayView.islandHover(override: nil, pointer: false, voiceOver: false))
        XCTAssertTrue(OverlayView.islandHover(override: nil, pointer: true, voiceOver: false))
        XCTAssertTrue(OverlayView.islandHover(override: nil, pointer: false, voiceOver: true))
        XCTAssertFalse(OverlayView.islandHover(override: false, pointer: false, voiceOver: true), "the renderer's override wins")
    }

    // MARK: V10

    /// Every right-wing text of the bare capsule, in all three languages, fits its wing at full size (the review measured
    /// eight of them cut off in the fixed 354 pt capsule). Measured with the wing font, as the review did.
    func testCapsuleWingTextsFitInEveryLanguage() {
        let m = NotchMetrics.macBookPro
        let keys: [String.LocalizationValue] = ["No connection", "Rate limited", "Restarting", "for someone else", "for you",
                                                "1 min left", "wrap up", "Unprepared"]
        var failures: [String] = []
        for code in ["en", "it", "tr"] {
            let locale = Locale(identifier: code)
            for key in keys {
                let text = L10n.tr(key, locale: locale)
                let w = IslandWidth.listeningWidth(wingText: text, metrics: m)
                let frame = (w - m.notchWidth) / 2 - VT.Radius.islandShoulder - IslandBand.wingInset(width: w)
                if IslandWidth.wingTextWidth(text) > frame { failures.append("\(code) \"\(text)\": \(IslandWidth.wingTextWidth(text)) > \(frame)") }
            }
        }
        XCTAssertEqual(failures, [])
    }

    func testShortWingTextKeepsTheListeningCapsule() {
        let m = NotchMetrics.macBookPro
        XCTAssertEqual(IslandWidth.listeningWidth(wingText: nil, metrics: m), 354)
        XCTAssertEqual(IslandWidth.listeningWidth(wingText: "for Ada", metrics: m), 354)
        XCTAssertEqual(IslandWidth.listeningWidth(wingText: String(repeating: "W", count: 80), metrics: m), IslandWidth.maxListening,
                       "a very long name stops at the cap (the wing scales and truncates from there)")
    }

    /// The new "reconnected" notices and the other status words sit in a status panel's wing (480 pt), not the capsule:
    /// they fit there in every language.
    func testStatusPanelWingTextsFitInEveryLanguage() {
        let m = NotchMetrics.macBookPro
        let w = IslandWidth.status
        let frame = (w - m.notchWidth) / 2 - VT.Radius.islandShoulder - IslandBand.wingInset(width: w)
        var failures: [String] = []
        for code in ["en", "it", "tr"] {
            for key: String.LocalizationValue in ["Reconnected", "Restarted", "Restarting", "Needs access", "No credit", "No profile",
                                                 "Stop?", "Error"] {
                let text = L10n.tr(key, locale: Locale(identifier: code))
                if IslandWidth.wingTextWidth(text) > frame { failures.append("\(code) \"\(text)\"") }
            }
        }
        XCTAssertEqual(failures, [])
    }

    // MARK: listening while the brain warms up

    /// Listening starts before the brain is ready (the runner's `status warming`): the startup panel says answers are still
    /// warming up instead of "Ready", until the brain's `ready`. Both the start card and the plain panel.
    func testStartupPanelSaysAnswersAreWarmingUntilTheBrainIsReady() {
        for route: AudioRoute? in [.meeting, nil] {
            var r = OverlayReducer()
            r.sessionStarting(lang: "en", session: "dana-reyes", app: "Comet", route: route)
            r.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])), now: 1)
            r.apply(.status(state: "warming", message: VerseRunner.warmingWhileListening), now: 1)
            XCTAssertEqual(r.state.startup?.title, "Listening · answers warming up", "route \(String(describing: route))")
            r.apply(.level(remoteDbfs: -20, meDbfs: nil), now: 2)
            XCTAssertEqual(r.state.startup?.phase, .listening)
            XCTAssertEqual(r.state.startup?.title, "Listening · answers warming up", "sound does not make answers ready")
            r.apply(status("ready"), now: 3)
            XCTAssertEqual(r.state.startup?.title, route == nil ? "Listening · dana-reyes" : "Listening")
        }
        // A brain that is ready before listening starts never shows the warming step.
        var r = OverlayReducer()
        r.sessionStarting(lang: "en", session: "dana-reyes", app: "Comet", route: .meeting)
        r.apply(status("ready"), now: 0)
        r.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])), now: 1)
        XCTAssertEqual(r.state.startup?.title, "Ready")
    }

    /// The step is the startup panel's one-line title (15 pt semibold in the 480 pt panel): it fits in every language.
    func testAnswersWarmingTitleFitsTheStartupPanel() {
        let room = IslandWidth.startup - 2 * VT.islandCardInset
        var failures: [String] = []
        for code in ["en", "it", "tr"] {
            let text = L10n.tr("Listening · answers warming up", locale: Locale(identifier: code))
            if code != "en" { XCTAssertNotEqual(text, "Listening · answers warming up", "\(code) is not translated") }
            let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
            if w > room { failures.append("\(code) \"\(text)\": \(w) > \(room)") }
        }
        XCTAssertEqual(failures, [])
    }

    // MARK: V13

    /// The teleprompter's fallback hint is in the interface language for every cause; the raw English reason is not shown.
    func testFallbackHintIsLocalizedAndHidesTheRawReason() {
        let causes: [PrompterFallbackCause] = [.noSpeechSource, .noLevelSource, .permissionDenied, .microphoneFailed,
                                              .speechUnavailable, .other]
        for cause in causes {
            let hint = PrompterHint.fellBack(reason: "No speech source is available.", cause: cause)
            let en = hint.text(locale: Locale(identifier: "en"))
            XCTAssertTrue(en.hasPrefix("Classic mode: "), en)
            XCTAssertFalse(en.contains("No speech source is available."), "the raw reason stays in the log")
            for code in ["it", "tr"] {
                let t = hint.text(locale: Locale(identifier: code))
                XCTAssertNotEqual(t, en, "\(cause) has no \(code) text")
            }
        }
    }

    /// Script import errors: each loader case maps to a catalog string, translated in Italian and Turkish.
    func testImportErrorsAreLocalized() {
        let errors: [any Error] = [
            ScriptLoader.LoadError.unsupportedType("key"), ScriptLoader.LoadError.unreadable("x"), ScriptLoader.LoadError.empty,
            PresentationNotesExtractor.ExtractionError.unsupportedFormat, PresentationNotesExtractor.ExtractionError.extractionFailed("x"),
            PresentationNotesExtractor.ExtractionError.noNotesFound, CocoaError(.fileReadUnknown),
        ]
        var seen = Set<String>()
        for e in errors {
            let en = ScriptEditorModel.importErrorText(e, locale: Locale(identifier: "en"))
            seen.insert(en)
            for code in ["it", "tr"] {
                XCTAssertNotEqual(ScriptEditorModel.importErrorText(e, locale: Locale(identifier: code)), en, "\(e) has no \(code) text")
            }
        }
        XCTAssertEqual(seen.count, errors.count, "each case has its own message")
        XCTAssertEqual(ScriptEditorModel.importErrorText(ScriptLoader.LoadError.unsupportedType("key"), locale: Locale(identifier: "tr")),
                       ".key dosyaları içe aktarılamaz. .md, .txt veya .pptx kullanın.")
    }
}
