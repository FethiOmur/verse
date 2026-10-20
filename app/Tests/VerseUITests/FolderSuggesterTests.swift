import Foundation
@testable import VerseUI
import XCTest

final class FolderSuggesterTests: XCTestCase {
    private func folder(_ name: String, used: TimeInterval = 0) -> SessionFolder {
        let base = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!
        return SessionFolder(id: "f-" + String(name.lowercased().filter(\.isLetter).prefix(8)), name: name, createdAt: base, usedAt: base.addingTimeInterval(used))
    }

    private func signals(_ name: String, title: String? = nil, conv: String? = nil, sim: String? = nil, source: String? = nil, facts: [String] = []) -> FolderSignals {
        FolderSignals(folderName: name, title: title ?? HomeSession.title(forFolder: name), conversationCompany: conv, simCompany: sim,
                      sourceSession: source, factNames: facts)
    }

    func testAFolderNameMatchesTheSessionFolderNamesWords() {
        let ironwood = folder("Ironwood")
        let s = FolderSuggester.suggestion(for: signals("ironwood-lena"), folders: [folder("Acme"), ironwood])
        XCTAssertEqual(s, .existing(ironwood))
    }

    func testMatchingIsWholeWordsInOrderAndIgnoresCaseAndAccents() {
        XCTAssertNil(FolderSuggester.suggestion(for: signals("portland-sync"), folders: [folder("Port")]), "Port is not Portland")
        XCTAssertNotNil(FolderSuggester.suggestion(for: signals("cafe-muller-intro"), folders: [folder("Café Müller")]))
        XCTAssertNil(FolderSuggester.suggestion(for: signals("muller-cafe-intro"), folders: [folder("Café Müller")]), "in order")
        XCTAssertNotNil(FolderSuggester.suggestion(for: signals("x", title: "ISTANBUL kickoff"), folders: [folder("İstanbul")]))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("rank", sim: "Maps Rank"), folders: [folder("Northwind Labs")]), .new("Maps Rank"),
                       "the words are not the folder's, so only the company can start a folder")
    }

    func testTheCompanyTheTitleAndTheFactsCountAsHaystack() {
        let rank = folder("Northwind Labs"), harbor = folder("Harbor Ledger"), north = folder("Northwind")
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("conv-1", title: "x", conv: "Northwind Labs"), folders: [rank]), .existing(rank))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("sim-1", title: "x", sim: "Harbor Ledger"), folders: [harbor]), .existing(harbor))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("call", title: "Call with Harbor Ledger"), folders: [harbor]), .existing(harbor))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("call", title: "Call", facts: ["The client is Northwind Labs. Northwind Labs"]), folders: [north]), .existing(north))
        XCTAssertNil(FolderSuggester.suggestion(for: signals("call", title: "Call", facts: ["Northwind"]), folders: [harbor]))
    }

    func testOnlyTheFirst40FactNamesAreRead() {
        let facts = (0..<45).map { $0 == 41 ? "Northwind" : "line \($0)" }
        XCTAssertNil(FolderSuggester.suggestion(for: signals("call", title: "Call", facts: facts), folders: [folder("Northwind")]))
        let early = (0..<45).map { $0 == 39 ? "Northwind" : "line \($0)" }
        XCTAssertNotNil(FolderSuggester.suggestion(for: signals("call", title: "Call", facts: early), folders: [folder("Northwind")]))
    }

    func testTheLongestNameWinsAndATieGoesToTheMostRecentlyUsedFolder() {
        let short = folder("Rank"), long = folder("Northwind Labs")
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("northwind-labs-intro"), folders: [short, long]), .existing(long))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("northwind-labs-intro"), folders: [long, short]), .existing(long))

        // Two folders of the same length that both match: the one used last.
        let x = folder("Delta One", used: 0), y = folder("Delta Two", used: 900)
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("delta-one-two", title: "Delta One Delta Two"), folders: [x, y]), .existing(y))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("delta-one-two", title: "Delta One Delta Two"), folders: [y, x]), .existing(y))
    }

    func testANewFolderComesOnlyFromACompanyAndOnlyWhenNothingMatched() {
        let none = FolderSuggester.suggestion(for: signals("conv-20261015-1857-northwind-labs", conv: "Northwind Labs"), folders: [folder("Acme")])
        XCTAssertEqual(none, .new("Northwind Labs"))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("sim-x", sim: "Harbor  Ledger "), folders: []), .new("Harbor Ledger"))
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("c", conv: "Northwind Labs", sim: "Other"), folders: []), .new("Northwind Labs"), "conversation first")
        XCTAssertNil(FolderSuggester.suggestion(for: signals("plain-call"), folders: []), "no company, no suggestion")
        XCTAssertNil(FolderSuggester.suggestion(for: signals("sim-y", sim: "Unknown company"), folders: []), "the sim prep's placeholder is not a company")
        XCTAssertNil(FolderSuggester.suggestion(for: signals("c", conv: String(repeating: "x", count: 61)), folders: []))
        // An existing folder that matched blocks the new one, even when it was turned down.
        XCTAssertNil(FolderSuggester.suggestion(for: signals("c", conv: "Northwind Labs"), folders: [folder("Northwind Labs")], dismissed: ["northwind labs"]))
    }

    func testADismissedSuggestionIsNotSuggestedAgain() {
        let plural = folder("Ironwood")
        XCTAssertNil(FolderSuggester.suggestion(for: signals("ironwood-lena"), folders: [plural], dismissed: ["IRONWOOD"]))
        XCTAssertNil(FolderSuggester.suggestion(for: signals("c", conv: "Northwind Labs"), folders: [], dismissed: ["Northwind Labs"]))
        // Another match is still offered.
        let lena = folder("Lena")
        XCTAssertEqual(FolderSuggester.suggestion(for: signals("ironwood-lena"), folders: [plural, lena], dismissed: ["Ironwood"]), .existing(lena))
    }

    func testASimWithASourceSessionAutoAssignsToItsFolder() {
        let s = signals("sim-20261020-0900-harbor-kickoff", source: "harbor-kickoff")
        XCTAssertEqual(FolderSuggester.autoAssignment(for: s, assigned: { $0 == "harbor-kickoff" ? "f-harbor" : nil }), "f-harbor")
        XCTAssertNil(FolderSuggester.autoAssignment(for: s, assigned: { _ in nil }), "its source is unfiled")
        XCTAssertNil(FolderSuggester.autoAssignment(for: signals("sim-posting"), assigned: { _ in "f-any" }), "a posting run has no source session")
    }

    func testSignalsAreReadFromTheSessionFolder() throws {
        let root = try FolderFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = """
        ## FACTS
        [f001] name | The client is Harbor Ledger, a fictional bookkeeping app. | Harbor Ledger | prep:L1
        [f002] product | Harbor Ledger sells invoices. | invoices | prep:L2
        [f003] name | Dana Reyes runs partnerships. | Dana Reyes | prep:L3

        ## GLOSSARY
        [g001] name: not a fact line
        """
        let conv = try FolderFixtures.session("conv-20261015-1857-northwind", in: root, pack: pack,
                                              files: ["meta.json": #"{"conversation":{"company":"Northwind Labs"}}"#])
        let s = FolderSuggester.signals(folderName: "conv-20261015-1857-northwind", title: "Northwind", dir: conv)
        XCTAssertEqual(s.conversationCompany, "Northwind Labs")
        XCTAssertNil(s.simCompany, "sim.json is read for sim- folders only")
        XCTAssertEqual(s.factNames, ["The client is Harbor Ledger, a fictional bookkeeping app. Harbor Ledger", "Dana Reyes runs partnerships. Dana Reyes"])

        let sim = try FolderFixtures.session("sim-20261020-0900-northwind", in: root,
                                             files: ["sim.json": #"{"company":"Northwind Labs","source":"session","source_session":"conv-20261015-1857-northwind"}"#])
        let t = FolderSuggester.signals(folderName: "sim-20261020-0900-northwind", title: "Practice", dir: sim)
        XCTAssertEqual(t.simCompany, "Northwind Labs")
        XCTAssertEqual(t.sourceSession, "conv-20261015-1857-northwind")
    }
}
