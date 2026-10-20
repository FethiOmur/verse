import SwiftUI
import VersePrompter

/// Settings > Teleprompter: one group of the Settings page.
public struct PrompterSettingsSection: View {
    @ObservedObject var settings: PrompterSettings
    @Environment(\.homeInk) private var ink

    public init(settings: PrompterSettings) { self.settings = settings }

    public var body: some View {
        HomeGroup {
            HomeRow("Mode", verbatimDetail: settings.mode.explanation) {
                HomePopup(selection: $settings.mode, options: PrompterMode.allCases.map { HomeOption(verbatim: $0.title, $0) })
            }
            HomeRowDivider()
            HomeRow("Speed") {
                Text("\(Int(settings.wordsPerMinute)) words per minute", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit()
                Stepper("", value: $settings.wordsPerMinute, in: PrompterSettings.wordsPerMinuteRange, step: PrompterSession.speedStep).labelsHidden()
            }
            HomeRowDivider()
            HomeRow("Font size") {
                Text("\(Int(settings.fontSize)) pt", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit()
                Stepper("", value: $settings.fontSize, in: PrompterSettings.fontSizeRange, step: 2).labelsHidden()
            }
            HomeRowDivider()
            HomeToggleRow("Mirror the text", isOn: $settings.mirror)
            HomeRowDivider()
            HomeToggleRow("Hide Verse from screen sharing (cards and prompter)", isOn: $settings.hideFromShare)
            HomeRowDivider()
            HomeToggleRow("Read meeting cards on the prompter", isOn: $settings.followMeetingCards)
        }
        HomeFootnote(verbatim: L10n.tr("Hiding asks macOS to leave the panel out of captures, only while the prompter is open. Some capture paths ignore it, so test it with your meeting app before relying on it.") + " "
                     + L10n.tr("Shortcuts while the prompter is open: \(PrompterCommand.allCases.map { "\($0.shortcut) \($0.title.lowercased(with: L10n.locale))" }.joined(separator: ", "))."))
    }
}
