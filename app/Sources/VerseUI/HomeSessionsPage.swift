import AppKit
import SwiftUI

/// The home window's Sessions page: every session folder (meetings, practice runs, prepared packs) on the left, the
/// selected one on a reading plate: Summary, Follow up (checkable), what is still open, the questions heard, and for a
/// practice run its report. It replaces the practice report window and shows the vault summary before saving it.
struct HomeSessionsPage: View {
    @ObservedObject var model: HomeSessionsModel
    @ObservedObject var router: HomeRouter
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    @Environment(\.homeInk) private var ink

    private var selected: HomeSession? { model.session(named: router.selectedSession) ?? model.sessions.first }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list
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

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions").font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                .padding(.leading, 10).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sessions) { s in
                        Button { router.selectedSession = s.name } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text("\(HomeFormat.day(s.date)) · \(s.kindText)").font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
                                    if s.unprepared { UnpreparedTag() }
                                }
                            }
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(s.name == selected?.name ? ink.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.sessions.isEmpty {
                        Text("No sessions yet. Prepare one for your next meeting.").font(VT.Font.callout).foregroundStyle(ink.tertiary)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: 236).padding(.leading, 18).padding(.top, 22)
    }
}

/// "Unprepared": a call that started without a prepared session. A neutral fill, like every tag on the window glass.
struct UnpreparedTag: View {
    @Environment(\.homeInk) private var ink
    var body: some View {
        Text("Unprepared").font(VT.Font.caption).foregroundStyle(ink.secondary)
            .padding(.horizontal, 6).frame(height: 16)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            .fixedSize()
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

private struct HomeSessionDetailView: View {
    var session: HomeSession
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    @State private var detail = HomeSessionDetail()
    @State private var done: Set<String> = []
    @State private var message: String?
    @State private var messageIsError = false
    @State private var contentHeight: CGFloat = .infinity
    @Environment(\.homeInk) private var ink
    private let checklist = HomeChecklistStore()

    private var meta: String {
        var parts = [session.unprepared ? "Unprepared · \(session.kindText)" : (session.kind == .practice ? "Practice" : session.kind.rawValue),
                     "\(HomeFormat.day(session.date)) \(session.date.formatted(HomeFormat.time))"]
        if session.spend > 0 { parts.append(String(format: "$%.2f spent", session.spend)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary).lineLimit(2)
                    Text(meta).font(VT.Font.callout).foregroundStyle(ink.secondary)
                }
                Spacer(minLength: 8)
                if session.kind != .practice, !session.unprepared, controller.sessions.contains(session.name) {
                    if settings.sessionName == session.name {
                        Label("Used for Start", systemImage: "checkmark").font(VT.Font.callout).foregroundStyle(ink.secondary)
                    } else {
                        HomeSecondaryButton("Use for Start") { settings.sessionName = session.name }.disabled(controller.running)
                    }
                }
                if let t = session.transcriptURL {
                    HomeSecondaryButton("Transcript") { NSWorkspace.shared.activateFileViewerSelecting([t]) }
                } else {
                    HomeSecondaryButton("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.dir]) }
                }
                if session.summaryURL != nil, session.kind != .practice {
                    HomePrimaryButton("Save to vault", action: saveToVault)
                }
            }
            if let message { HomeNote(text: message, isError: messageIsError).padding(.top, 8) }
            plate.padding(.top, 18)
        }
        .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.name) {
            detail = HomeSessionDetail.load(session)
            done = checklist.done(session: session.name)
        }
    }

    @ViewBuilder private var plate: some View {
        if let report = session.reportURL {
            HomeGroup(plate: true) {
                HomeReportView(url: report, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        } else {
            HomeGroup(plate: true) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(maxHeight: contentHeight)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if detail.sections.isEmpty, detail.questions.isEmpty {
            Text(session.kind == .prepared
                 ? "Prepared, not used in a meeting yet. Pick it with “Use for Start” and press Start in the menu, or open a meeting that matches it."
                 : "Nothing was written for this session.")
                .font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(4)
        }
        ForEach(detail.sections) { section in
            Text(Self.heading(section.title)).font(VT.Font.title).foregroundStyle(ink.primary).padding(.top, section.id == detail.sections.first?.id ? 0 : 4)
            if section.isParagraph {
                ForEach(section.items, id: \.self) { p in
                    Text(p).font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            } else if section.title == "Actions" {
                ForEach(Array(section.items.prefix(Self.cap)), id: \.self) { item in followRow(item) }
                more(section.items.count)
            } else {
                ForEach(Array(section.items.prefix(Self.cap)), id: \.self) { item in
                    Text(item).font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                more(section.items.count)
            }
        }
        if !detail.questions.isEmpty {
            Text("Questions you got").font(VT.Font.title).foregroundStyle(ink.primary).padding(.top, 4)
            ForEach(Array(detail.questions.prefix(12)), id: \.self) { q in
                Text(q).font(VT.Font.body).foregroundStyle(ink.primary).fixedSize(horizontal: false, vertical: true)
            }
            if detail.questions.count > 12 {
                Text("and \(detail.questions.count - 12) more in the transcript").font(VT.Font.caption).foregroundStyle(ink.tertiary)
            }
        }
    }

    private static let cap = 8

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > Self.cap {
            Text("and \(count - Self.cap) more in summary.md").font(VT.Font.caption).foregroundStyle(ink.tertiary)
        }
    }

    private static func heading(_ s: String) -> String {
        switch s {
        case "Actions": "Follow up"
        case "Open questions": "Still open"
        default: s
        }
    }

    private func followRow(_ item: String) -> some View {
        let on = done.contains(item)
        return Button {
            if on { done.remove(item) } else { done.insert(item) }
            checklist.set(item, done: !on, session: session.name)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? ink.primary : ink.tertiary, lineWidth: 1.3)
                    if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.primary) }
                }
                .frame(width: 15, height: 15).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(item).font(VT.Font.body).foregroundStyle(on ? ink.secondary : ink.primary)
                    .strikethrough(on, color: ink.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func saveToVault() {
        guard let summary = session.summaryURL else { return }
        let writer = VaultSummaryWriter(vaultRoot: controller.meeting.settings.vaultURL)
        do {
            let url = try writer.write(summaryAt: summary, title: session.title, date: session.date)
            message = "Saved to \((url.path as NSString).abbreviatingWithTildeInPath)"
            messageIsError = false
        } catch {
            message = "\(error)"
            messageIsError = true
        }
    }
}
