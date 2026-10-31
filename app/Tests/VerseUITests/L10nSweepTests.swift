import AppKit
import SwiftUI
@testable import VerseUI
import XCTest

/// The sweep (spec 2.5, package L1): the interface follows the language at run time, dates and numbers follow it, plurals come
/// from the catalog, and no hand-built English plural is left. Every test that changes the language puts English back.
@MainActor
final class L10nSweepTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10nState.shared.apply(.en)
    }

    override func tearDown() {
        L10nState.shared.apply(.en)
        super.tearDown()
    }

    // MARK: Run-time switch

    /// A hosted `HomeRow("Practice")` is wider in Italian ("Esercitazione") than in English and narrower in Turkish ("Pratik"):
    /// the same view repaints when the setting changes, no relaunch.
    func testSwitchingTheLanguageChangesARenderedHomeRowTitle() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HomeRow("Practice") { EmptyView() }.fixedSize().interfaceLocale())
        func width(_ lang: InterfaceLanguage) -> CGFloat {
            L10nState.shared.apply(lang)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let en = width(.en), it = width(.it), tr = width(.tr)
        XCTAssertGreaterThan(it, en + 20, "Esercitazione is longer than Practice")
        XCTAssertLessThan(tr, en - 10, "Pratik is shorter than Practice")
        XCTAssertEqual(width(.en), en, accuracy: 0.5, "and back again")
    }

    func testTheWindowTitlesFollowTheLanguage() {
        XCTAssertEqual(HomePage.sessions.title, "Sessions")
        L10nState.shared.apply(.it)
        XCTAssertEqual(HomePage.allCases.map(\.title), ["Prepara", "Profilo", "Sessioni", "Persone", "Esercitazione", "Copioni", "Impostazioni"])
        L10nState.shared.apply(.tr)
        XCTAssertEqual(HomePage.allCases.map(\.title), ["Hazırla", "Profil", "Oturumlar", "Kişiler", "Pratik", "Metinler", "Ayarlar"])
    }

    // MARK: Dates and numbers

    func testHomeFormatDayIsLocalized() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(HomeFormat.day(now), "Today")
        XCTAssertEqual(HomeFormat.day(yesterday), "Yesterday")
        L10nState.shared.apply(.it)
        XCTAssertEqual(HomeFormat.day(now).lowercased(), "oggi")
        XCTAssertEqual(HomeFormat.day(yesterday).lowercased(), "ieri")
        L10nState.shared.apply(.tr)
        XCTAssertEqual(HomeFormat.day(now), "Bugün")
        XCTAssertEqual(HomeFormat.day(yesterday), "Dün")
    }

    func testDatesFollowTheFormatLocale() throws {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 23; c.hour = 14; c.minute = 30
        let d = try XCTUnwrap(Calendar.current.date(from: c))
        XCTAssertEqual(d.formatted(HomeFormat.time), "14:30", "English keeps 24-hour time")
        L10nState.shared.apply(.it)
        XCTAssertEqual(d.formatted(HomeFormat.time), "14:30")
        XCTAssertTrue(d.formatted(HomeFormat.dayMonth).lowercased().contains("ott"), "Italian month: \(d.formatted(HomeFormat.dayMonth))")
        L10nState.shared.apply(.tr)
        XCTAssertEqual(d.formatted(HomeFormat.time), "14:30")
        XCTAssertTrue(d.formatted(HomeFormat.dayMonth).contains("Eki"), "Turkish month: \(d.formatted(HomeFormat.dayMonth))")
    }

    func testMoneyAndPercentFollowTheLanguage() {
        XCTAssertEqual(L10n.usd(0.012, digits: 3), "$0.012")
        XCTAssertEqual(L10n.percent(0.5), "50%")
        L10nState.shared.apply(.it)
        XCTAssertEqual(L10n.usd(0.012, digits: 3), "$0,012", "decimal comma")
        L10nState.shared.apply(.tr)
        XCTAssertEqual(L10n.usd(0.012, digits: 3), "$0,012")
        XCTAssertEqual(L10n.percent(0.5), "%50", "Turkish writes the percent sign first")
    }

    // MARK: Plurals

    func testPluralsComeFromTheCatalog() {
        func q(_ n: Int, _ lang: String) -> String { L10n.tr("\(n) likely questions", locale: Locale(identifier: lang)) }
        XCTAssertEqual(q(1, "en"), "1 likely question")
        XCTAssertEqual(q(14, "en"), "14 likely questions")
        XCTAssertEqual(q(1, "it"), "1 domanda probabile")
        XCTAssertEqual(q(14, "it"), "14 domande probabili")
        XCTAssertEqual(q(1, "tr"), "1 olası soru")
        XCTAssertEqual(q(14, "tr"), "14 olası soru", "Turkish keeps the noun singular after a number")
        func turns(_ n: Int, _ lang: String) -> String { L10n.tr("\(n) turns", locale: Locale(identifier: lang)) }
        XCTAssertEqual(turns(1, "en"), "1 turn")
        XCTAssertEqual(turns(3, "it"), "3 interventi")
        XCTAssertEqual(turns(1, "it"), "1 intervento")
    }

    func testNoHandBuiltPluralIsLeftInTheSources() throws {
        // `\(n) thing\(n == 1 ? "" : "s")` and its siblings: a plural built by hand stays English in Italian and Turkish.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VerseUI", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"== 1 \? "" : "s"|== 1 \? "[a-z]+" : "[a-z]+s""#)
        var offenders: [String] = []
        for f in files {
            for (i, line) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil && !line.contains("// l10n:verbatim") {
                offenders.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "use a catalog plural (a key like \"%lld questions\") instead")
    }

    // MARK: Models

    func testModelStringsFollowTheLanguage() {
        XCTAssertEqual(OverlayStatus.offline.title, "No connection")
        XCTAssertEqual(HomeSession.title(forFolder: "adhoc-20261016-1432-room"), "Call at 14:32")
        L10nState.shared.apply(.it)
        XCTAssertEqual(OverlayStatus.rateLimited.title, "Limite raggiunto")
        XCTAssertEqual(HomeSession.title(forFolder: "adhoc-20261016-1432-room"), "Chiamata alle 14:32")
        L10nState.shared.apply(.tr)
        XCTAssertEqual(OverlayStatus.rateLimited.title, "Hız sınırı aşıldı")
        XCTAssertEqual(HomeSession.title(forFolder: "adhoc-20261016-1432-room"), "14:32 görüşmesi")
    }

    func testSummaryHeadingsAreMappedAndTheFileStaysEnglish() {
        // The headings of `summary.md` stay English on disk (the file is also saved to the vault); the page maps the known ones.
        L10nState.shared.apply(.tr)
        XCTAssertEqual(L10n.tr("Follow up"), "Yapılacaklar")
        XCTAssertEqual(L10n.tr("Still open"), "Açık kalanlar")
    }
}
