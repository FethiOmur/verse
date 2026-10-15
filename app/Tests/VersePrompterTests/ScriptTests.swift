import Foundation
import Testing
@testable import VersePrompter

@Suite("Script parsing and files")
struct ScriptTests {
    @Test
    func blankLineThenDashesBreaksThePage() {
        let script = ScriptParser.parse("First page here.\n\n---\nSecond page.\n\n---\n\nThird page.")
        #expect(script.pages.map(\.text) == ["First page here.", "Second page.", "Third page."])
    }

    @Test
    func dashesDirectlyUnderTextAreNotABreak() {
        let script = ScriptParser.parse("A heading\n---\nstill the same page")
        #expect(script.pages.count == 1)
        #expect(script.pages[0].words.map(\.text).prefix(2) == ["A", "heading"])
    }

    @Test
    func emptyPagesEmptyLinesAndCRLFAreHandled() {
        let script = ScriptParser.parse("One\r\n\r\n\r\n---\r\n\r\n---\r\nTwo\r\n\r\n\r\nstill two\r\n")
        #expect(script.pages.map(\.text) == ["One", "Two still two"])
        #expect(ScriptParser.parse("").isEmpty)
        #expect(ScriptParser.parse("\n\n   \n").isEmpty)
    }

    @Test
    func bracketedCuesAreMarkedAndNotCountedAsSpeech() {
        let page = ScriptParser.parse("Hello [look at the camera] world").pages[0]
        #expect(page.words.map(\.isCue) == [false, true, true, true, true, false])
        #expect(page.words.filter { !$0.isCue }.map(\.text) == ["Hello", "world"])
    }

    @Test
    func replacingUnreadKeepsTheReadPrefix() {
        let page = PromptPage(text: "alpha beta gamma delta epsilon")
        let offset = page.characterOffset(forWordProgress: 2)        // "alpha beta " read
        let result = page.replacingUnread(from: offset, with: "one two three")
        #expect(result.page.text == "alpha beta one two three")
        #expect(result.readOffset == "alpha beta".count)
        #expect(result.page.wordProgress(forCharacterOffset: result.readOffset) == 2)
    }

    @Test
    func replacingUnreadTreatsAHalfReadWordAsRead() {
        let page = PromptPage(text: "alpha beta gamma")
        let result = page.replacingUnread(from: 8, with: "new tail")   // inside "beta"
        #expect(result.page.text == "alpha beta new tail")
    }

    @Test
    func replacingUnreadWithNothingReadReplacesEverything() {
        let page = PromptPage(text: "alpha beta")
        #expect(page.replacingUnread(from: 0, with: "fresh start").page.text == "fresh start")
    }

    @Test
    func pptxNotesBecomeOnePagePerSlide() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try PPTXFixture.make(slides: [["Welcome everyone.", "Today: the plan."], ["Second slide notes."]], in: dir)

        let script = try ScriptLoader.load(from: deck)
        #expect(script.pages.map(\.text) == ["Welcome everyone. Today: the plan.", "Second slide notes."])
    }

    @Test
    func pptxWithoutNotesThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try PPTXFixture.make(slides: [[""]], in: dir)
        #expect(throws: PresentationNotesExtractor.ExtractionError.noNotesFound) { try ScriptLoader.load(from: deck) }
    }

    @Test
    func markdownAndTextFilesLoadAndOtherTypesAreRejected() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("talk.md")
        try "Intro line.\n\n---\nBody line.".write(to: md, atomically: true, encoding: .utf8)
        #expect(try ScriptLoader.load(from: md).pages.count == 2)

        let txt = dir.appendingPathComponent("note.txt")
        try "Just text.".write(to: txt, atomically: true, encoding: .utf8)
        #expect(try ScriptLoader.load(from: txt).pages.count == 1)

        let key = dir.appendingPathComponent("deck.key")
        try Data().write(to: key)
        #expect(throws: ScriptLoader.LoadError.unsupportedType("key")) { try ScriptLoader.load(from: key) }
    }

    @Test
    func scriptStoreWritesMarkdownUnderTheGivenDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(directory: root.appendingPathComponent("scripts"))   // does not exist yet

        let url = try store.write("Hello there.", name: "Demo talk")
        #expect(url.lastPathComponent == "Demo talk.md")
        #expect(url.deletingLastPathComponent().lastPathComponent == "scripts")
        #expect(try store.read(name: "Demo talk") == "Hello there.")
        #expect(try store.list().map(\.name) == ["Demo talk"])

        // A name cannot escape the directory.
        let sneaky = try store.write("x", name: "../../evil")
        #expect(sneaky.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
    }
}
