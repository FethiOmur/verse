import AppKit
import SwiftUI

/// Which tab of a session's detail is open. The last choice is remembered app-wide (`sessionsDetailTab`, spec 3.7).
enum SessionsDetailTab: String, Sendable {
    case summary, transcript
}

extension SessionsDetailTab {
    /// Which tabs a session's detail offers. The switch appears when the session has both a summary and a transcript (a practice
    /// run shows its report and never a transcript tab); with only one of them, that one shows; `stored` is the remembered choice.
    static func layout(hasSummary: Bool, hasTranscript: Bool, hasReport: Bool, stored: SessionsDetailTab) -> (showsTabs: Bool, shown: SessionsDetailTab) {
        if hasReport { return (false, .summary) }
        if hasSummary, hasTranscript { return (true, stored) }
        return (false, hasTranscript && !hasSummary ? .transcript : .summary)
    }
}

@MainActor
struct SessionsDetailTabStore {
    var defaults = Bundle.main.bundleIdentifier == AppSettings.suiteName ? UserDefaults.standard
        : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard

    var tab: SessionsDetailTab {
        get { SessionsDetailTab(rawValue: defaults.string(forKey: "sessionsDetailTab") ?? "") ?? .summary }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "sessionsDetailTab") }
    }
}

/// The Sessions page's detail: header with actions, a Summary · Transcript switch when the session has both, then the reading plate
/// (summary, follow up, questions, the transcript, or a practice report).
struct HomeSessionDetailView: View {
    var session: HomeSession
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    /// Where Ask's citation chips ask the transcript to reveal a row (F2b passes the page's). Without one the view keeps its own.
    var jump: TranscriptJump?
    @StateObject private var ownJump = TranscriptJump()
    @Environment(\.sessionsDetailRender) private var render
    @State private var detail = HomeSessionDetail()
    /// nil until the files are read, so the plate does not flash its empty state.
    @State private var transcript: TranscriptDocument?
    @State private var tab = SessionsDetailTabStore().tab
    @State private var done: Set<String> = []
    @State private var message: String?
    @State private var messageIsError = false
    @State private var contentHeight: CGFloat = .infinity
    @Environment(\.homeInk) private var ink
    private let checklist = HomeChecklistStore()

    private static let tabItems: [(label: LocalizedStringKey, value: SessionsDetailTab)] = [
        (label: "Summary", value: .summary), (label: "Transcript", value: .transcript),
    ]

    private var activeJump: TranscriptJump { jump ?? ownJump }
    private var hasSummary: Bool { session.kind != .practice && session.summaryURL != nil }
    private var hasTranscript: Bool { session.kind != .practice && session.transcriptURL != nil }
    private var tabLayout: (showsTabs: Bool, shown: SessionsDetailTab) {
        SessionsDetailTab.layout(hasSummary: hasSummary, hasTranscript: hasTranscript, hasReport: session.reportURL != nil, stored: render?.tab ?? tab)
    }
    private var showsTabs: Bool { tabLayout.showsTabs }
    private var shownTab: SessionsDetailTab { tabLayout.shown }

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
                if session.summaryURL != nil, session.kind != .practice {
                    HomePrimaryButton("Save to vault", action: saveToVault)
                }
                SessionChromeMenu(symbol: "ellipsis.circle", help: "More") {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([session.dir]) } label: { Text("Show in Finder", bundle: .module) }
                }
            }
            if let message { HomeNote(verbatim: message, isError: messageIsError).padding(.top, 8) }
            if showsTabs {
                HomeSegmented(Self.tabItems,
                              selection: Binding(get: { render?.tab ?? tab }, set: { tab = $0; SessionsDetailTabStore().tab = $0 }))
                    .padding(.top, 16)
            }
            plate.padding(.top, showsTabs ? 14 : 18)
        }
        .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.name) {
            detail = HomeSessionDetail.load(session)
            done = checklist.done(session: session.name)
            if hasTranscript {
                let dir = session.dir, owner = settings.ownerName
                transcript = await Task.detached { TranscriptDocument.load(sessionDir: dir, ownerName: owner) }.value
            }
        }
        // A citation chip in Ask asks for a row: the transcript is where it lives.
        .onReceive(activeJump.$serial.dropFirst()) { _ in
            guard hasTranscript else { return }
            tab = .transcript
        }
    }

    @ViewBuilder private var plate: some View {
        if let report = session.reportURL {
            HomeGroup(plate: true) {
                HomeReportView(url: report, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        } else if shownTab == .transcript {
            if let transcript {
                TranscriptView(document: transcript, title: session.title,
                               meta: TranscriptDocument.metaLine(date: session.date, kind: session.kindText, turns: transcript.rows.count),
                               jump: activeJump)
            } else {
                HomeGroup(plate: true) { Color.clear }.frame(maxHeight: .infinity)
            }
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
