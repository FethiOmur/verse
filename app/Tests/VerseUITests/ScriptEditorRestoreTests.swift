import Foundation
import Testing
import VersePrompter
@testable import VerseUI

/// Review V5 (unsaved text replaced without a word) and V11 (the script parsed once per text change).
@Suite("Script editor: replaced text and parsing")
@MainActor
struct ScriptEditorRestoreTests {
    private struct NoWriter: ScriptWriting {
        func write(topic: String, seconds: Int, use: ScriptUse) async throws -> ScriptDraft { throw ScriptWriteError.badOutput }
    }

    private func editor() throws -> ScriptEditorModel {
        ScriptEditorModel(store: ScriptStore(directory: try tempDirectory().appendingPathComponent("scripts")), writer: NoWriter())
    }

    @Test
    func openingASavedScriptOverUnsavedTextKeepsItForRestore() throws {
        let e = try editor()
        e.name = "Saved one"
        e.text = "saved words"
        #expect(e.save())
        e.newScript()
        e.text = "pasted and never saved"
        e.open(e.entries[0])
        #expect(e.text == "saved words")
        #expect(e.previousText == "pasted and never saved")
        #expect(e.message?.isError == false, "a note tells him why the restore link is there")

        e.restorePreviousText()
        #expect(e.text == "pasted and never saved" && e.name == ScriptEditorModel.untitled && e.isDirty)
        #expect(e.save())                                          // goes to a new file, never over "Saved one"
        #expect(Set(e.entries.map(\.name)) == ["Saved one", "Untitled"])
        e.open(e.entries.first { $0.name == "Saved one" }!)
        #expect(e.text == "saved words")
    }

    @Test
    func restoringEditsOfASavedScriptPutsThemBackOnThatScript() throws {
        let e = try editor()
        e.name = "Talk"
        e.text = "version one"
        e.save()
        e.text = "version two, unsaved"
        e.newScript()
        #expect(e.text.isEmpty && e.previousText == "version two, unsaved")
        e.restorePreviousText()
        #expect(e.name == "Talk" && e.text == "version two, unsaved" && e.isDirty)
        e.save()
        #expect(e.entries.map(\.name) == ["Talk"])
        #expect(!e.isDirty)
    }

    @Test
    func importOverUnsavedTextKeepsItForRestore() throws {
        let e = try editor()
        e.text = "my draft"
        let md = try tempDirectory().appendingPathComponent("talk.md")
        try "Imported words.".write(to: md, atomically: true, encoding: .utf8)
        e.importFile(md)
        #expect(e.text == "Imported words." && e.previousText == "my draft")
        e.restorePreviousText()
        #expect(e.text == "my draft")
    }

    @Test
    func savedOrEmptyTextIsReplacedWithoutARestoreOffer() throws {
        let e = try editor()
        e.name = "A"
        e.text = "saved"
        e.save()
        e.newScript()
        #expect(e.previousText == nil && e.message == nil)
        e.text = "   "
        e.newScript()
        #expect(e.previousText == nil)
    }

    @Test
    func theScriptFollowsEveryTextChange() throws {
        let e = try editor()
        e.text = "one two three"
        #expect(e.wordCount == 3 && e.pageCount == 1)
        e.text = "one two\n\n---\n\nthree four five"
        #expect(e.wordCount == 5 && e.pageCount == 2 && e.script.pages[1].text == "three four five")
        e.text = ""
        #expect(e.script.isEmpty)
    }
}
