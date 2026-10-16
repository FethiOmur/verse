import Foundation
import SwiftUI
import VerseTurns
@testable import VerseUI
import XCTest

/// The redesigned island (UI redesign spec 2.4, 3.2, 5): the veil math, the state kinds and widths, the level bars.
@MainActor
final class IslandTests: XCTestCase {
    // MARK: veil

    func testVeilIsBlackThroughTheBandThenFallsToTheFloorAndEasesAtTheRim() {
        let h: CGFloat = 268
        let stops = IslandVeil.stops(height: h, bandHeight: 32, floor: 0.62)
        let band = Double(32 + 6) / Double(h)
        XCTAssertEqual(stops.first?.opacity, 1)
        XCTAssertEqual(stops.first(where: { $0.location >= band - 1e-9 })?.opacity, 1, "black through the band + 6")
        // The dissolve reaches the floor 34 % of the height below the band (at most 78 % down).
        let reach = min(0.78, band + 0.34)
        let atReach = stops.first(where: { $0.location >= reach - 1e-9 })!
        XCTAssertEqual(atReach.opacity, 0.62, accuracy: 1e-6)
        // The last stop is 75 % of the floor and nothing rises on the way down.
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.last?.opacity ?? 0, 0.62 * 0.75, accuracy: 1e-6)
        for (a, b) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(b.opacity, a.opacity + 1e-9)
            XCTAssertGreaterThanOrEqual(b.location, a.location)
        }
        // The rim strip is the last 24 pt.
        XCTAssertEqual(stops.first(where: { $0.opacity < 0.62 - 1e-6 && $0.location > reach })?.location ?? 1, 1 - 24 / Double(h), accuracy: 0.05)
    }

    func testCapsuleHeightIsFlatBlack() {
        XCTAssertEqual(IslandVeil.stops(height: 32, bandHeight: 32, floor: 0.35).map(\.opacity), [1, 1])
        XCTAssertEqual(IslandVeil.solidStops(height: 32, bandHeight: 32).map(\.opacity), [1, 1])
    }

    func testFloorFollowsTheSettingAndTheAccessibilitySwitches() {
        XCTAssertEqual(IslandVeil.floor(userOpacity: 0.62, reduceTransparency: false, increaseContrast: false), 0.62)
        XCTAssertEqual(IslandVeil.floor(userOpacity: 0.1, reduceTransparency: false, increaseContrast: false), 0.35, "clamped to the setting's range")
        XCTAssertEqual(IslandVeil.floor(userOpacity: 0.62, reduceTransparency: false, increaseContrast: true), 0.92, "Increase Contrast: at least 92 %")
        XCTAssertEqual(IslandVeil.floor(userOpacity: 0.97, reduceTransparency: false, increaseContrast: true), 0.97)
        XCTAssertEqual(IslandVeil.floor(userOpacity: 0.4, reduceTransparency: true, increaseContrast: false), 1, "Reduce Transparency: solid")
    }

    func testSolidStopsBlendTheBlackBandIntoTheSolidSurface() {
        let s = IslandVeil.solidStops(height: 200, bandHeight: 32)
        XCTAssertEqual(s.first?.opacity, 1)
        XCTAssertEqual(s.last?.opacity, 0)
        XCTAssertEqual(s[1].location, 38.0 / 200, accuracy: 1e-9)
    }

    func testSilhouetteRadiiAreTheSpecs() {
        XCTAssertEqual(HangingNotchMetrics.topShoulderRadius, 14)
        XCTAssertEqual(HangingNotchMetrics.bottomCornerRadius, 26)
    }

    // MARK: level bars

    func testBarLevelMapsDbfsToAnEmptyToFullBar() {
        XCTAssertEqual(OverlayReducer.barLevel(nil), 0)
        XCTAssertEqual(OverlayReducer.barLevel(-80), 0)
        XCTAssertEqual(OverlayReducer.barLevel(-40), 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayReducer.barLevel(-10), 1)
    }

    func testLevelsFeedTheBarsAndTheSpeakingFlagAndTheHoldEndsIt() {
        let c = Clock()
        let m = OverlayModel(config: OverlayConfig(), clock: { c.t })
        m.sessionStarting(lang: "en", session: "s", app: "Comet")
        m.apply(status("ready"))
        m.apply(.metric(obj(["type": "metric", "stage": "session_t0", "turn_id": ""])))
        XCTAssertFalse(m.state.remoteSpeaking)
        m.apply(.level(remoteDbfs: -50, meDbfs: nil)); c.t += 0.1
        m.apply(.level(remoteDbfs: -30, meDbfs: -45)); c.t += 0.1
        m.apply(.level(remoteDbfs: -20, meDbfs: nil))
        XCTAssertTrue(m.state.remoteSpeaking)
        XCTAssertEqual(m.state.remoteBars, [0.25, 0.75, 1.0])
        XCTAssertEqual(m.state.meBars, [0, 0.375, 0])
        // 2.5 s without sound: the flag goes down on the next tick and the bars empty.
        c.t += 2.6
        m.tick()
        XCTAssertFalse(m.state.remoteSpeaking)
        XCTAssertEqual(m.state.remoteBars, [0, 0, 0])
    }

    func testBarsAreAlwaysTheLastThreeLevels() {
        let m = OverlayModel(config: OverlayConfig(), clock: { 5 })
        for db in [-60.0, -50, -40, -30, -20] { m.apply(.level(remoteDbfs: db, meDbfs: nil)) }
        XCTAssertEqual(m.state.remoteBars, [0.5, 0.75, 1.0])
    }

    // MARK: kinds and widths

    func testKindPriorityIsStatusPromptSimPrompterStartupTopicsCardCapsule() {
        var s = OverlayState()
        s.running = true
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "capsule")
        s.card = OverlayCard(turnID: "r1", question: "Q?")
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "card")
        s.topics = [OverlayChip(text: "ETA", source: "glossary", kind: "topic")]
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "card", "a card beats the topic row")
        s.card = nil
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "topics")
        s.startup = StartupPanel(phase: .ready, session: "x", app: nil)
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "startup")
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: true)), "prompter")
        s.sim = SimOverlay(startedAt: Date(), voice: "text", showCaption: false)
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: true)), "sim")
        s.meetingPrompt = .saved(path: "p")
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: true)), "prompt")
        s.status = .error("boom")
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: true)), "status")
        s.status = .offline
        XCTAssertEqual(kindName(IslandKind.resolve(s, prompterOpen: false)), "prompt", "Offline is a wing, not a panel")
    }

    private func kindName(_ k: IslandKind) -> String {
        switch k {
        case .capsule: return "capsule"
        case .statusPanel: return "status"
        case .prompt: return "prompt"
        case .sim: return "sim"
        case .prompter: return "prompter"
        case .startup: return "startup"
        case .topics: return "topics"
        case .card: return "card"
        }
    }

    func testWidthsFollowTheStateTable() {
        let m = NotchMetrics.macBookPro
        func w(_ s: OverlayState, card: CGFloat = 600, prompter: Bool = false) -> CGFloat {
            IslandWidth.width(kind: IslandKind.resolve(s, prompterOpen: prompter), state: s, metrics: m, cardWidth: card)
        }
        var idle = OverlayState()
        idle.running = true
        idle.activity = .listening
        XCTAssertEqual(w(idle), 266)
        var talking = idle
        talking.remoteSpeaking = true
        XCTAssertEqual(w(talking), 354)
        var tagged = idle
        tagged.addresseeTag = "for Marco"
        XCTAssertEqual(w(tagged), 354, "the tag needs the listening wing")
        var offline = idle
        offline.status = .offline
        XCTAssertEqual(w(offline), 354, "\"Offline\" needs its wing")
        var card = idle
        card.card = OverlayCard(turnID: "r", question: "q")
        XCTAssertEqual(w(card), 600)
        XCTAssertEqual(w(card, card: 480), 480, "the card width is the setting")
        XCTAssertEqual(w(idle, prompter: true), 640)
        var status = idle
        status.status = .creditExhausted("x")
        XCTAssertEqual(w(status), 480)
        var prompt = OverlayState()
        prompt.meetingPrompt = .saved(path: "p")
        XCTAssertEqual(w(prompt), 480)
        var sim = idle
        sim.sim = SimOverlay(startedAt: Date(), voice: "text", showCaption: false)
        XCTAssertEqual(w(sim), 520)
        XCTAssertEqual(IslandWidth.width(kind: .sim(sim.sim!), state: sim, metrics: m, cardWidth: 600, forcePracticeCapsule: true), 442)
    }

    func testCapsuleWidthsScaleWithTheNotch() {
        let wide = NotchMetrics(notchWidth: 200, notchHeight: 32, hasNotch: true)
        XCTAssertEqual(wide.capsuleWidth(wide: false), 280)
        XCTAssertEqual(wide.listeningWidth, 368)
        XCTAssertEqual(wide.capsuleWidth(wide: true), 456)
    }

    // MARK: pieces

    func testPrompterShowsThreeLinesAroundTheCurrentOne() {
        XCTAssertEqual(PrompterLineWindow(currentLine: 0, lineCount: 3), PrompterLineWindow(previous: nil, current: 0, next: 1))
        XCTAssertEqual(PrompterLineWindow(currentLine: 1, lineCount: 3), PrompterLineWindow(previous: 0, current: 1, next: 2))
        XCTAssertEqual(PrompterLineWindow(currentLine: 2, lineCount: 3), PrompterLineWindow(previous: 1, current: 2, next: nil))
        XCTAssertEqual(PrompterLineWindow(currentLine: 5, lineCount: 0), PrompterLineWindow(previous: nil, current: 0, next: nil))
        XCTAssertEqual(PrompterIslandType.current(fontSize: 26, scale: 1), 30)
        XCTAssertEqual(PrompterIslandType.other(fontSize: 26, scale: 1), 26)
        XCTAssertEqual(PrompterIslandType.current(fontSize: 26, scale: 28.0 / 22), 38)
    }

    func testStatusSentenceSplitsIntoHeadlineAndLine() {
        let (h, l) = StatusPanelView.split("Max API credit used up until 1 December. Verse keeps transcribing locally.")
        XCTAssertEqual(h, "Max API credit used up until 1 December.")
        XCTAssertEqual(l, "Verse keeps transcribing locally.")
        XCTAssertEqual(StatusPanelView.split("Something broke").headline, "Something broke")
        XCTAssertNil(StatusPanelView.split("Something broke").line)
    }

    func testStartPromptCarriesTheIslandLayout() {
        let p = MeetingPrompt.detected(appName: "Comet", eventTitle: "Mara · Northwind Labs", plan: .prepared("mara"), questionCount: 14)
        XCTAssertEqual(p.eyebrow, "Comet is using the microphone")
        XCTAssertEqual(p.headline, "Mara · Northwind Labs")
        XCTAssertEqual(p.detailLine, "Prepared · 14 questions")
        XCTAssertEqual(p.dismissLabel, "Dismiss", "the model's label stays; the island shows it as \"Not now\"")
        let q = MeetingPrompt.detected(appName: "Zoom", eventTitle: nil, plan: .fromInvite)
        XCTAssertEqual(q.headline, "Meeting detected")
        XCTAssertEqual(q.detailLine, "Prepares a session from the invite")
        XCTAssertEqual(MeetingPrompt.detected(appName: "Zoom", eventTitle: "x", plan: .prepared("mara")).detailLine, "Prepared · mara")
        XCTAssertEqual(MeetingPrompt.upcoming(eventTitle: "x", minutes: 4, plan: .selected(nil)).eyebrow, "Meeting in 4 min")
    }

    func testEverySpecStateHasARenderShot() {
        let names = Set(ScreenRenderer.sampleShots().map(\.name))
        for n in ["island-0-meeting-detected", "island-1-idle", "island-2-listening", "island-3-hearing-question", "island-4-answer-card",
                  "island-5-following-you", "island-6-practice-capsule", "island-6b-practice-coach-note", "island-7-teleprompter",
                  "island-8-status-credit", "island-a1-answer-veil-35", "island-a2-answer-reduce-transparency",
                  "island-a3-answer-increase-contrast", "island-a4-answer-reduce-motion"] {
            XCTAssertTrue(names.contains(n), n)
        }
    }
}
