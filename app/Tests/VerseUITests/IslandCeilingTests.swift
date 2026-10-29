import Testing
@testable import VerseUI

// A deep answer must fit: the card's ceiling follows the screen, and a small saved height can't shrink it (owner, 29 Oct).
@Suite("Island ceiling")
struct IslandCeilingTests {
    @Test
    func aSmallSavedHeightDoesNotCutTheAnswer() {
        #expect(OverlayView.islandCeiling(setting: 226, screenHeight: 982) == 638)
    }

    @Test
    func aTallerSavedHeightStillWins() {
        #expect(OverlayView.islandCeiling(setting: 720, screenHeight: 982) == 720)
    }
}
