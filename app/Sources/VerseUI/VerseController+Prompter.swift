import SwiftUI
import VersePrompter

/// The teleprompter's side of the app controller. Kept in its own file so the controller itself gets only a few lines.
extension VerseController {
    /// Parses `text` into pages and starts reading it on the notch panel. Does nothing for an empty script.
    public func readScript(_ text: String) async {
        let script = ScriptParser.parse(text)
        guard !script.isEmpty else { return }
        showOverlayPanel()   // the panel exists before the prompter opens, so it can show and hide itself
        await prompter.open(script: script, source: .script, autostart: true)
    }
}
