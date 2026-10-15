import SwiftUI
import VersePrompter

/// Settings > Teleprompter. One line in `SettingsView` puts it in the form.
public struct PrompterSettingsSection: View {
    @ObservedObject var settings: PrompterSettings

    public init(settings: PrompterSettings) { self.settings = settings }

    public var body: some View {
        Section {
            Picker("Mode", selection: $settings.mode) {
                ForEach(PrompterMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(settings.mode.explanation).font(.caption).foregroundStyle(.secondary)
            Stepper(value: $settings.wordsPerMinute, in: PrompterSettings.wordsPerMinuteRange, step: PrompterSession.speedStep) {
                LabeledContent("Speed", value: "\(Int(settings.wordsPerMinute)) words per minute")
            }
            Stepper(value: $settings.fontSize, in: PrompterSettings.fontSizeRange, step: 2) {
                LabeledContent("Font size", value: "\(Int(settings.fontSize)) pt")
            }
            Toggle("Mirror the text", isOn: $settings.mirror)
            Toggle("Hide the prompter from screen sharing", isOn: $settings.hideFromShare)
            Toggle("Read meeting cards on the prompter", isOn: $settings.followMeetingCards)
        } header: {
            Text("Teleprompter")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hiding asks macOS to leave the panel out of captures, only while the prompter is open. Some capture paths ignore it, so test it with your meeting app before relying on it.")
                Text("Shortcuts while the prompter is open: " + PrompterCommand.allCases.map { "\($0.shortcut) \($0.title.lowercased())" }.joined(separator: ", ") + ".")
            }
        }
    }
}
