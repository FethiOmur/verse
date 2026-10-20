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

/// The menu-bar block for the teleprompter: the editor, pause and close while it is open, and the meeting-card toggle.
public struct PrompterMenuBlock: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var prompter: PrompterModel
    @ObservedObject var settings: PrompterSettings
    @Environment(\.openWindow) private var openWindow

    public init(controller: VerseController) {
        self.controller = controller
        prompter = controller.prompter
        settings = controller.prompter.settings
    }

    public var body: some View {
        Divider()
        Button {
            HomeRouter.shared.show(.scripts, openWindow: openWindow)
        } label: { Text("Teleprompter scripts…", bundle: .module) }
        if prompter.isOpen {
            Button { prompter.send(.toggle) } label: {
                if prompter.state.isPaused { Text("Start prompter", bundle: .module) } else { Text("Pause prompter", bundle: .module) }
            }
            Button { prompter.send(.close) } label: { Text("Close prompter", bundle: .module) }
        }
        Toggle(isOn: $settings.followMeetingCards) { Text("Prompter on meeting cards", bundle: .module) }
    }
}
