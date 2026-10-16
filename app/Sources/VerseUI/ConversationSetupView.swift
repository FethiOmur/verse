import AppKit
import SwiftUI

/// The home window's Prepare page: "Up next" (calendar meetings with Open / Prepare, and the session the menu's Start
/// uses), then "New preparation": the pasted thread, an optional posting (link or text), the company website and a
/// note, then Prepare with progress, warnings and the result. It replaces the "New session from a conversation…" window.
public struct ConversationSetupView: View {
    @ObservedObject var model: ConversationController
    var upNext: HomeUpNextModel?
    var meeting: VerseController?
    var settings: AppSettings?
    @Environment(\.homeInk) private var ink

    public init(model: ConversationController) {
        self.model = model
    }

    init(model: ConversationController, upNext: HomeUpNextModel, meeting: VerseController, settings: AppSettings) {
        self.model = model
        self.upNext = upNext
        self.meeting = meeting
        self.settings = settings
    }

    private var locked: Bool { model.phase == .preparing }

    public var body: some View {
        HomeColumnPage {
            HomePageHeader("Prepare", subtitle: "Paste what you have. Verse builds your answers before the call.")
            if let upNext, let meeting, let settings {
                HomeSectionHeader("Up next")
                HomeUpNextGroup(upNext: upNext, meeting: meeting, settings: settings)
            }
            HomeSectionHeader("New preparation")
            HomeGroup {
                threadRow
                HomeRowDivider()
                postingRows
                HomeRowDivider()
                HomeRow("Company website") {
                    HomeValueField("example.com (optional)", text: $model.companyURL)
                }
                HomeRowDivider()
                HomeRow("Note") {
                    HomeValueField("Anything Verse should know (optional)", text: $model.note, lines: 1...3)
                }
            }
            .disabled(locked)
            runBar.padding(.top, 16)
        }
        .accessibilityIdentifier("verse.home.prepare")
    }

    // MARK: rows

    private var threadRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation").font(VT.Font.body).foregroundStyle(ink.primary)
            HomeTextArea(text: $model.thread, placeholder: "Paste the LinkedIn or email thread.", minHeight: 62)
            HStack {
                Text("\(model.thread.count.formatted()) characters · stays on this Mac")
                    .font(VT.Font.caption).foregroundStyle(ink.tertiary)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { model.thread = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard").font(VT.Font.caption).foregroundStyle(ink.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var postingRows: some View {
        HomeRow("Job posting") {
            HomeValueField("Link (optional)", text: $model.postingLink, onSubmit: model.fetchPosting)
            if model.fetching { ProgressView().controlSize(.small) }
            if model.posting != nil {
                HomeSecondaryButton("Clear", action: model.clearPosting)
            } else {
                HomeSecondaryButton("Fetch", symbol: "link", action: model.fetchPosting)
                    .disabled(model.fetching || model.postingLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let m = model.fetchMessage {
            HomeNote(text: m).padding(.horizontal, 14).padding(.bottom, 10)
        }
        if model.posting == nil, model.postingLink.trimmingCharacters(in: .whitespaces).isEmpty {
            HomeRowDivider()
            HomeRow("Posting text") { HomeValueField("Or paste the posting text (optional)", text: $model.postingPaste, lines: 1...4) }
        }
    }

    // MARK: run bar

    @ViewBuilder private var runBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .setup:
                HStack(spacing: 8) {
                    Spacer()
                    HomeSecondaryButton("Clear", action: clear)
                    HomePrimaryButton("Prepare", hint: "⌘↩", shortcut: KeyboardShortcut(.return, modifiers: .command), action: model.prepare)
                        .disabled(!model.canPrepare)
                }
                if let e = model.error { HomeNote(text: e, isError: true) }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let t0 = model.startedAt {
                        TimelineView(.periodic(from: t0, by: 1)) { ctx in
                            Text("Preparing · \(SimOverlay.elapsed(from: t0, now: ctx.date))")
                                .font(VT.Font.bodyEmph).foregroundStyle(ink.primary).monospacedDigit()
                        }
                    }
                    Spacer()
                    HomeSecondaryButton("Cancel", action: model.cancelPrep)
                }
                if let l = model.lines.last(where: { !$0.hasPrefix("  ...") }) {
                    Text(l.trimmingCharacters(in: .whitespaces)).font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(2)
                }
            case .done:
                if let s = model.summary {
                    Label("\(model.sessionDir?.lastPathComponent ?? "") is ready and selected", systemImage: "checkmark.circle.fill")
                        .font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                    Text("\(s.company.isEmpty ? "Conversation" : s.company) · \(s.bankEntries) questions · \(s.searches) searches · "
                         + "\(s.sourced) sourced, \(s.unverified) unverified · \(String(format: "$%.2f", s.costUSD))")
                        .font(VT.Font.callout).foregroundStyle(ink.secondary)
                }
                ForEach(Array(model.warnings.prefix(3).enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(3)
                }
                if model.warnings.count > 3 {
                    Text("and \(model.warnings.count - 3) more in the session's meta.json").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                }
                HStack(spacing: 8) {
                    Spacer()
                    HomeSecondaryButton("Show in Finder", action: model.revealSession)
                    HomeSecondaryButton("Another conversation", action: model.another)
                    HomePrimaryButton("Open session") {
                        if let n = model.sessionDir?.lastPathComponent {
                            HomeRouter.shared.selectedSession = n
                            HomeRouter.shared.page = .sessions
                        }
                    }
                }
            }
        }
    }

    /// Empties the form (before a run; `another()` does the same after one).
    private func clear() {
        model.thread = ""
        model.note = ""
        model.companyURL = ""
        model.postingPaste = ""
        model.postingLink = ""
        model.clearPosting()
    }
}

/// "Up next": the calendar's next meetings, then the session the menu's Start uses.
struct HomeUpNextGroup: View {
    @ObservedObject var upNext: HomeUpNextModel
    @ObservedObject var meeting: VerseController
    @ObservedObject var settings: AppSettings
    @Environment(\.homeInk) private var ink

    var body: some View {
        HomeGroup {
            if upNext.items.isEmpty {
                HomeRow(upNext.calendarOn ? "No meetings in the next day" : "Calendar is off",
                        detail: upNext.calendarOn ? nil : "Turn on “Use my calendar” in Settings to see your next meetings here.") {
                    if !upNext.calendarOn {
                        HomeSecondaryButton("Settings") { HomeRouter.shared.page = .settings }
                    }
                }
                HomeRowDivider()
            }
            ForEach(upNext.items) { item in
                meetingRow(item)
                HomeRowDivider(inset: 54)
            }
            HomeRow("Session for Start", detail: meeting.sessions.isEmpty ? "No session prepared yet" : nil) {
                HomePopup(selection: $settings.sessionName, options: meeting.sessions.map { HomeOption($0, $0) }, fallback: "None")
                .disabled(meeting.running || meeting.sessions.isEmpty)
            }
            if let m = upNext.message {
                HomeRowDivider()
                HomeNote(text: m, isError: true).padding(14)
            }
        }
        .task { await upNext.refresh() }
    }

    private func meetingRow(_ item: HomeUpNextItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").font(.system(size: 14, weight: .medium)).foregroundStyle(ink.secondary)
                .frame(width: 28, height: 28).background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                Text(item.meta).font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let session = item.session {
                Label("Prepared", systemImage: "checkmark").font(VT.Font.callout).foregroundStyle(ink.secondary)
                HomeSecondaryButton("Open") {
                    if meeting.sessions.contains(session), !meeting.running { settings.sessionName = session }
                    HomeRouter.shared.selectedSession = session
                    HomeRouter.shared.page = .sessions
                }
            } else if upNext.preparing.contains(item.id) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(VT.Font.callout).foregroundStyle(ink.secondary)
            } else {
                Text("Not prepared").font(VT.Font.callout).foregroundStyle(ink.tertiary)
                HomeSecondaryButton("Prepare") { upNext.prepare(item) }
            }
        }
        .padding(.horizontal, 14).frame(height: 56)
    }
}

/// The menu-bar block: opens the home window on Prepare.
public struct ConversationMenuBlock: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("New session from a conversation…") {
            HomeRouter.shared.show(.prepare, openWindow: openWindow)
        }
    }
}

public enum ConversationWindow {
    public static let id = HomeRouter.windowID
}
