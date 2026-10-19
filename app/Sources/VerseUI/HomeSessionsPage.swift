import AppKit
import SwiftUI

/// The home window's Sessions page: every session folder (meetings, practice runs, prepared packs) on the left, the
/// selected one on a reading plate: Summary, Follow up (checkable), what is still open, the questions heard, and for a
/// practice run its report. It replaces the practice report window and shows the vault summary before saving it.
/// This file is the container; the list column is `HomeSessionsList.swift` and the detail `HomeSessionDetailView.swift`.
struct HomeSessionsPage: View {
    @ObservedObject var model: HomeSessionsModel
    @ObservedObject var router: HomeRouter
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings

    private var selected: HomeSession? { model.session(named: router.selectedSession) ?? model.sessions.first }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HomeSessionsList(model: model, router: router, selectedName: selected?.name)
            if let s = selected {
                HomeSessionDetailView(session: s, controller: controller, settings: settings)
                    .id(s.name)
            } else {
                Spacer()
            }
        }
        .onAppear { model.reload() }
        .accessibilityIdentifier("verse.home.sessions")
    }
}

/// The window's text is English whatever the system region; dates follow it.
enum HomeFormat {
    static let locale = Locale(identifier: "en_GB")
    static var time: Date.FormatStyle { Date.FormatStyle().locale(locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits) }
    static var dayMonth: Date.FormatStyle { Date.FormatStyle().locale(locale).weekday(.abbreviated).day().month(.abbreviated) }

    /// "Today", "Yesterday", "Tue 14 Oct".
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(dayMonth)
    }
}
