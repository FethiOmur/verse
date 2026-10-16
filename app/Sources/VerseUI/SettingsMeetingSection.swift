import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings for meeting detection and the summary-to-vault question. One section, referenced from `SettingsView` by one line.
struct SettingsMeetingSection: View {
    @ObservedObject var meeting: MeetingCoordinator
    @ObservedObject private var settings: MeetingSettings

    init(meeting: MeetingCoordinator) {
        self.meeting = meeting
        _settings = ObservedObject(wrappedValue: meeting.settings)
    }

    var body: some View {
        Section {
            Toggle("Follow my answer", isOn: $settings.followMyAnswer)
            Text("When you leave the card and talk about something else, Verse updates it to continue your line and strikes through the points you make. Takes effect at the next Start.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Offer to start when a meeting is detected", isOn: $settings.detectMeetings)
            Toggle("Use my calendar", isOn: Binding(
                get: { settings.useCalendar },
                set: { on in
                    if on { Task { await meeting.requestCalendarAccess() } } else { settings.useCalendar = false }
                }))
            .disabled(!settings.detectMeetings)
            Text(meeting.calendarStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("After a meeting, offer to save the summary to the vault", isOn: $settings.offerSummaryToVault)
            LabeledContent("Vault") {
                HStack {
                    TextField("", text: $settings.vaultPath, prompt: Text(MeetingSettings.defaultVaultPath))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseVault)
                }
            }
            .disabled(!settings.offerSummaryToVault)
        } header: {
            Text("Meetings")
        } footer: {
            Text("Detection only reads which meeting app (Comet, Brave, Chrome, Safari, Arc, Zoom, Teams) has its microphone on; no audio. Nothing starts without your click. A summary is written only after you press Save, as a new note in 000-Inbox/Verse of the vault.")
        }
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
