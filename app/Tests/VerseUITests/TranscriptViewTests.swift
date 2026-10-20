import AppKit
import SwiftUI
@testable import VerseUI
import XCTest

/// The Transcript tab (F1): which tabs a session offers, the jump API Ask uses, and that the view lays out and draws with real
/// fixture data in both appearances.
@MainActor
final class TranscriptViewTests: XCTestCase {
    private func fixture(_ name: String) -> TranscriptDocument {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)", isDirectory: true)
        return TranscriptDocument.load(sessionDir: dir, ownerName: "Dana")
    }

    func testTabsAppearOnlyWhenTheSessionHasBothAndOtherwiseTheExistingOneShows() {
        typealias T = SessionsDetailTab
        // Both: the switch, and the remembered choice.
        XCTAssertTrue(T.layout(hasSummary: true, hasTranscript: true, hasReport: false, stored: .summary).showsTabs)
        XCTAssertEqual(T.layout(hasSummary: true, hasTranscript: true, hasReport: false, stored: .transcript).shown, .transcript)
        XCTAssertEqual(T.layout(hasSummary: true, hasTranscript: true, hasReport: false, stored: .summary).shown, .summary)
        // One of them: no switch, and that one shows whatever was remembered.
        let onlySummary = T.layout(hasSummary: true, hasTranscript: false, hasReport: false, stored: .transcript)
        XCTAssertFalse(onlySummary.showsTabs)
        XCTAssertEqual(onlySummary.shown, .summary)
        let onlyTranscript = T.layout(hasSummary: false, hasTranscript: true, hasReport: false, stored: .summary)
        XCTAssertFalse(onlyTranscript.showsTabs)
        XCTAssertEqual(onlyTranscript.shown, .transcript)
        // A practice run keeps its report and gets no Transcript tab.
        let report = T.layout(hasSummary: false, hasTranscript: false, hasReport: true, stored: .transcript)
        XCTAssertFalse(report.showsTabs)
        XCTAssertEqual(report.shown, .summary)
        XCTAssertFalse(T.layout(hasSummary: true, hasTranscript: true, hasReport: true, stored: .transcript).showsTabs)
    }

    func testTheTabChoiceIsRememberedAppWide() {
        let suite = "dev.fethiverse.verse.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionsDetailTabStore(defaults: defaults)
        XCTAssertEqual(store.tab, .summary, "Summary until a choice is made")
        store.tab = .transcript
        XCTAssertEqual(SessionsDetailTabStore(defaults: defaults).tab, .transcript)
        XCTAssertEqual(defaults.string(forKey: "sessionsDetailTab"), "transcript", "the spec's key")
        defaults.set("nonsense", forKey: "sessionsDetailTab")
        XCTAssertEqual(store.tab, .summary)
    }

    func testJumpRevealsARowByIdOrStampAndRepeatedRequestsChangeTheSerial() {
        let doc = fixture("transcript-forward")
        let jump = TranscriptJump()
        XCTAssertNil(jump.rowID)
        XCTAssertTrue(jump.reveal(stamp: "1:02:05", in: doc))
        XCTAssertEqual(jump.rowID, doc.rows[6].id)
        XCTAssertEqual(jump.serial, 1)
        jump.reveal(rowID: doc.rows[6].id)
        XCTAssertEqual(jump.serial, 2, "the same row twice is two requests")
        XCTAssertFalse(jump.reveal(stamp: "9:59", in: doc))
        XCTAssertEqual(jump.serial, 2, "an unknown stamp changes nothing")
    }

    /// The view is laid out at the detail's smallest width (340 pt column) and at the wide size, and it draws something.
    func testTheViewLaysOutAndDrawsFixturesInLightAndDark() throws {
        for name in ["transcript-forward", "transcript-room", "transcript-legacy-5starts"] {
            for dark in [false, true] {
                for width: CGFloat in [292, 700] {
                    let view = TranscriptView(document: fixture(name), title: "Fixture", meta: "meta", jump: TranscriptJump())
                        .environment(\.homeInk, VT.Window(dark: dark))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: width, height: 480)
                        .background(dark ? Color.black : Color.white)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize.width, width, accuracy: 1, "\(name) \(dark) \(width)")
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    var colours = Set<UInt32>()
                    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                        }
                    }
                    XCTAssertGreaterThan(colours.count, 8, "\(name) \(dark ? "dark" : "light") \(width): the plate drew text and fills")
                }
            }
        }
    }

    func testAnEmptyTranscriptShowsTheEmptyStateInsteadOfARowList() {
        let host = NSHostingView(rootView: TranscriptView(document: .empty, title: "t", meta: "m", jump: TranscriptJump())
            .environment(\.homeInk, VT.Window(dark: false)).frame(width: 600, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(TranscriptDocument.empty.isEmpty)
        XCTAssertFalse(TranscriptDocument.empty.hasCards)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
