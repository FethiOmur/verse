import AppKit
import Foundation
import SwiftUI
import Testing
import VersePrompter
import VerseSpeech
@testable import VerseUI

/// Review V3 (the meeting-card page and the island's layout cache) and V6 (the room route).
@Suite("Prompter meeting cards: turns, layout cache, room route")
@MainActor
struct PrompterMeetingCardTests {
    final class Box { var sessions: [PrompterSession] = [] }

    private func make(mode: PrompterMode = .wordTracking) -> (PrompterModel, ManualPrompterClock, Box) {
        let settings = PrompterSettings(defaults: scratchDefaults())
        settings.followMeetingCards = true
        settings.mode = mode
        let model = PrompterModel(settings: settings)
        model.registersHotKeys = false
        let clock = ManualPrompterClock()
        let box = Box()
        model.makeSession = { script, source in
            let session: PrompterSession
            switch source {
            case .script:
                session = PrompterSession(script: script, mode: settings.mode, clock: clock, autoTick: false)
            case .meetingCard(let tap):
                session = PrompterSession(script: script, mode: settings.mode,
                                          transcript: ExternalTranscriptSource(stream: tap.stream()), clock: clock, autoTick: false)
            }
            box.sessions.append(session)
            return session
        }
        return (model, clock, box)
    }

    private func card(_ turn: String, _ say: String) -> OverlayCard {
        var c = OverlayCard(turnID: turn, question: "q")
        c.say = say
        return c
    }

    // MARK: V3

    @Test
    func aNewTurnStartsAFreshPageInsteadOfGrowingTheOldOne() async throws {
        let (model, clock, box) = make()
        let tap = model.meetingStarted()
        await model.handleMeetingCard(card("r1", "Sure, the clearest example is the weather app I built."))
        let session = try #require(box.sessions.last)
        clock.set(1)
        tap.ingest(micEvent("sure the clearest example"))
        #expect(await waitUntil { await session.state.wordPosition >= 4 })

        let second = "It took one evening and my family used it every morning."
        await model.handleMeetingCard(card("r2", second))
        #expect(model.page.text == second, "the earlier answer is not kept on the new turn's page")
        #expect(await session.state.wordPosition == 0)
        #expect(box.sessions.count == 1, "the same prompter session")
        await model.close()
    }

    @Test
    func theIslandLayoutIsMeasuredOncePerPageNotOncePerWordRead() {
        let model = PrompterModel(settings: PrompterSettings(defaults: scratchDefaults()))
        let page = PromptPage(text: "The quick brown fox jumps over the lazy dog near the river bank and keeps on running.")
        func render() {
            let view = PrompterTextView(model: model, textWidth: 420, fontSize: 30, scale: 1)
            _ = ImageRenderer(content: view).nsImage
        }
        var state = PrompterState()
        state.wordCount = page.wordCount
        model.presentForPreview(page: page, state: state)
        render()
        #expect(model.layoutMeasurements == 1)
        for word in 1...5 {                                    // he reads five words: five new states, same page
            state.wordPosition = Double(word)
            model.presentForPreview(page: page, state: state)
            render()
        }
        #expect(model.layoutMeasurements == 1, "a read word must not re-measure the page")
        model.presentForPreview(page: PromptPage(text: "A different page."), state: PrompterState())
        render()
        #expect(model.layoutMeasurements == 2)
    }

    // MARK: V6

    @Test
    func onTheRoomRouteWordTrackingLeavesTheCardShowing() async {
        let (model, _, box) = make(mode: .wordTracking)
        _ = model.meetingStarted(room: true)
        await model.handleMeetingCard(card("r1", "An answer to read aloud."))
        #expect(!model.isOpen && box.sessions.isEmpty, "the card, whose reading follows the room route, stays on screen")
    }

    @Test
    func onTheRoomRouteClassicModeStillOpensThePrompter() async {
        let (model, _, _) = make(mode: .classic)
        _ = model.meetingStarted(room: true)
        await model.handleMeetingCard(card("r1", "An answer to read aloud."))
        #expect(model.isOpen)
        await model.close()
    }

    @Test
    func switchingToTheRoomRouteMidCallClosesTheCardPrompterWithoutDismissingTheTurn() async {
        let (model, _, _) = make(mode: .wordTracking)
        _ = model.meetingStarted()
        await model.handleMeetingCard(card("r1", "An answer to read aloud."))
        #expect(model.isOpen)
        model.meetingRoute(room: true)
        #expect(await waitUntil { !model.isOpen })
        await model.handleMeetingCard(card("r1", "An answer to read aloud, longer now."))
        #expect(!model.isOpen)
        model.meetingRoute(room: false)
        await model.handleMeetingCard(card("r1", "An answer to read aloud, longer still."))
        #expect(model.isOpen, "the route closed it, not the user, so the same turn may open it again")
        await model.close()
    }
}
