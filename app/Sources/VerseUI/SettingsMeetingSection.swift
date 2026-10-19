import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings for meeting detection and the summary-to-vault question: the Meetings group of the Settings page.
struct SettingsMeetingSection: View {
    @ObservedObject var meeting: MeetingCoordinator
    @ObservedObject private var settings: MeetingSettings
    /// Anytime calls: the profile toggle, the default call language and the room cards.
    @ObservedObject var app: AppSettings
    @Environment(\.homeInk) private var ink

    init(meeting: MeetingCoordinator, settings app: AppSettings) {
        self.meeting = meeting
        self.app = app
        _settings = ObservedObject(wrappedValue: meeting.settings)
    }

    var body: some View {
        HomeGroup {
            HomeToggleRow("Use my profile in every session",
                          detail: "Your experience, projects and numbers go into every call, prepared or not. Edit them on the Me page. Takes effect at the next Start.",
                          isOn: $app.useMeProfile)
            HomeRowDivider()
            HomeToggleRow("Use my general prep in unprepared calls",
                          detail: "Unprepared calls start with your standing answers",
                          isOn: $app.useGeneralPrep)
            HomeRowDivider()
            HomeRow("Default call language",
                    detail: "What ⌥⌘V and Start now listen in. Change it during a call from the island or the menu.") {
                HomePopup(selection: $app.defaultCallLanguage,
                          options: AppSettings.callLanguages.map { HomeOption(verbatim: StartRoutes.languageName($0), $0) })
            }
            HomeRowDivider()
            HomeToggleRow("Automatic cards in room mode",
                          detail: "On: a card appears for a question the microphone hears. Off: only ⌥⌘↩ asks for one. Room mode is a call on speaker next to the Mac.",
                          isOn: $app.roomAutoCards)
            HomeRowDivider()
            HomeToggleRow("Follow my answer when I change the subject",
                          detail: "When you leave the card and talk about something else, Verse updates it to continue your line and strikes through the points you make. Takes effect at the next Start.",
                          isOn: $settings.followMyAnswer)
            HomeRowDivider()
            HomeToggleRow("Offer to start when a meeting is detected", isOn: $settings.detectMeetings)
            HomeRowDivider()
            HomeToggleRow("Use my calendar", verbatimDetail: meeting.calendarStatus, isOn: Binding(
                get: { settings.useCalendar },
                set: { on in
                    if on { Task { await meeting.requestCalendarAccess() } } else { settings.useCalendar = false }
                }))
            .disabled(!settings.detectMeetings)
            HomeRowDivider()
            HomeToggleRow("After a meeting, offer to save the summary to the vault", isOn: $settings.offerSummaryToVault)
            HomeRowDivider()
            HomeRow("Vault") {
                HomeValueField(verbatim: MeetingSettings.defaultVaultPath, text: $settings.vaultPath)
                HomeSecondaryButton("Choose…", action: chooseVault)
            }
            .disabled(!settings.offerSummaryToVault)
        }
        HomeFootnote("Detection only reads which meeting app (Comet, Brave, Chrome, Safari, Arc, Zoom, Teams) has its microphone on; no audio. Nothing starts without your click. A summary is written only after you press Save, as a new note in 000-Inbox/Verse of the vault.")
    }

    private func chooseVault() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { settings.vaultPath = u.path }
    }
}

/// The menu's "Play test file as remote…" file picker.
public enum RemoteFilePicker {
    @MainActor
    public static func choose() -> URL? {
        NSApp.activate()
        let p = NSOpenPanel()
        p.title = "Play test file as remote"
        p.message = "The file plays as the other side of the call. Your microphone stays you."
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }
}
