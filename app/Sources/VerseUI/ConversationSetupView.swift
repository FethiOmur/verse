import AppKit
import Combine
import SwiftUI

/// The home window's Prepare page: "Up next" (calendar meetings with Open / Prepare, and the session the menu's Start
/// uses), then "New preparation": the pasted thread, an optional posting (link or text), the company website and a
/// note, then Prepare with progress, warnings and the result. It replaces the "New session from a conversation…" window.
public struct ConversationSetupView: View {
    @ObservedObject var model: ConversationController
    var upNext: HomeUpNextModel?
    var meeting: VerseController?
    var settings: AppSettings?
    /// People and briefs for Up next (memory spec 5.4); nil in tests and renders that do not need them.
    var memory: SessionMemoryEnvironment?
    @Environment(\.homeInk) private var ink
    @Environment(\.upNextBriefRender) private var drawnBriefOpen

    public init(model: ConversationController) {
        self.model = model
    }

    init(model: ConversationController, upNext: HomeUpNextModel, meeting: VerseController, settings: AppSettings,
         memory: SessionMemoryEnvironment? = nil) {
        self.model = model
        self.upNext = upNext
        self.meeting = meeting
        self.settings = settings
        self.memory = memory
    }

    private var locked: Bool { model.phase == .preparing }

    public var body: some View {
        HomeColumnPage {
            HomePageHeader("Prepare", subtitle: "Paste what you have. Verse builds your answers before the call.")
            if let upNext, let meeting, let settings {
                HomeSectionHeader("Up next")
                HomeUpNextGroup(upNext: upNext, meeting: meeting, settings: settings, memory: memory)
                    .zIndex(drawnBriefOpen ? 1 : 0)
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
            Text("Conversation", bundle: .module).font(VT.Font.body).foregroundStyle(ink.primary)
            HomeTextArea(text: $model.thread, placeholder: "Paste the LinkedIn or email thread.", minHeight: 62)
            HStack {
                Text("\(model.thread.count.formatted()) characters · stays on this Mac", bundle: .module)
                    .font(VT.Font.caption).foregroundStyle(ink.tertiary)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { model.thread = s }
                } label: {
                    Label { Text("Paste", bundle: .module) } icon: { Image(systemName: "doc.on.clipboard") }.font(VT.Font.caption).foregroundStyle(ink.secondary)
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
            HomeNote(verbatim: m).padding(.horizontal, 14).padding(.bottom, 10)
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
                if let e = model.error { HomeNote(verbatim: e, isError: true) }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let t0 = model.startedAt {
                        TimelineView(.periodic(from: t0, by: 1)) { ctx in
                            Text("Preparing · \(SimOverlay.elapsed(from: t0, now: ctx.date))", bundle: .module)
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
                    Label { Text("\(model.sessionDir?.lastPathComponent ?? "") is ready and selected", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                        .font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                    Text(verbatim: [s.company.isEmpty ? L10n.tr("Conversation") : s.company, L10n.tr("\(s.bankEntries) questions"), L10n.tr("\(s.searches) searches"),
                                    L10n.tr("\(s.sourced) sourced, \(s.unverified) unverified"), L10n.usd(s.costUSD)].joined(separator: " · "))
                        .font(VT.Font.callout).foregroundStyle(ink.secondary)
                }
                ForEach(Array(model.warnings.prefix(3).enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(3)
                }
                if model.warnings.count > 3 {
                    Text("and \(model.warnings.count - 3) more in the session's meta.json", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
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

/// Forwards the changes of the memory objects Up next reads (people, sessions, the brief runner) to the group, which cannot hold an
/// optional `ObservedObject`.
@MainActor
final class UpNextMemoryWatch: ObservableObject {
    let env: SessionMemoryEnvironment?
    private var subscriptions: [AnyCancellable] = []

    init(env: SessionMemoryEnvironment?) {
        self.env = env
        guard let env else { return }
        func forward<O: ObservableObject>(_ o: O) -> AnyCancellable where O.ObjectWillChangePublisher == ObservableObjectPublisher {
            o.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        subscriptions = [forward(env.people), forward(env.sessions), forward(env.memory), forward(env.briefs)]
    }

    /// The entity an Up next item is about and its past meetings (held, newest first, without the item's own session); nil when there
    /// is none to speak of.
    func about(_ item: HomeUpNextItem) -> (entity: MemoryEntity, past: [HomeSession])? {
        guard let env, let event = item.event,
              let e = EntityResolver.primaryEntity(for: event, file: env.people.file, folders: env.sessions.folders.file, sessions: env.sessions.sessions)
        else { return nil }
        let past = EntityResolver.pastSessions(of: e.id, excluding: item.session, file: env.people.file, folders: env.sessions.folders.file,
                                               sessions: env.sessions.sessions)
        return past.isEmpty ? nil : (e, past)
    }

    /// "Met 3 times · last 19 Oct".
    static func caption(count: Int, last: Date) -> String {
        let date = last.formatted(BriefLayout.shortDate)
        return count == 1 ? L10n.tr("Met once · last \(date)") : L10n.tr("Met \(count) times · last \(date)")
    }
}

/// "Up next": the calendar's next meetings, then the session the menu's Start uses.
struct HomeUpNextGroup: View {
    @ObservedObject var upNext: HomeUpNextModel
    @ObservedObject var meeting: VerseController
    @ObservedObject var settings: AppSettings
    @StateObject private var watch: UpNextMemoryWatch
    @Environment(\.homeInk) private var ink

    init(upNext: HomeUpNextModel, meeting: VerseController, settings: AppSettings, memory: SessionMemoryEnvironment? = nil) {
        self.upNext = upNext
        self.meeting = meeting
        self.settings = settings
        _watch = StateObject(wrappedValue: UpNextMemoryWatch(env: memory))
    }

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
                HomePopup(selection: $settings.sessionName, options: meeting.sessions.map { HomeOption(verbatim: $0, $0) }, fallback: "None")
                .disabled(meeting.running || meeting.sessions.isEmpty)
            }
            if let m = upNext.message {
                HomeRowDivider()
                HomeNote(verbatim: m, isError: true).padding(14)
            }
        }
        .task { await upNext.refresh() }
    }

    private func meetingRow(_ item: HomeUpNextItem) -> some View {
        let about = watch.about(item)
        let makingBrief = item.session.map { watch.env?.briefs.making.contains($0) ?? false } ?? false
        return HStack(spacing: 12) {
            Image(systemName: "calendar").font(.system(size: 14, weight: .medium)).foregroundStyle(ink.secondary)
                .frame(width: 28, height: 28).background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                Text(item.meta).font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
                if let about, let last = about.past.first {
                    Text(verbatim: UpNextMemoryWatch.caption(count: about.past.count, last: last.date)).font(VT.Font.caption)
                        .foregroundStyle(ink.tertiary).lineLimit(1)
                        .accessibilityIdentifier("verse.home.prepare.met")
                }
            }
            Spacer(minLength: 12)
            if let session = item.session {
                if makingBrief {
                    ProgressView().controlSize(.small)
                    Text("Making brief…", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
                } else {
                    Label { Text("Prepared", bundle: .module) } icon: { Image(systemName: "checkmark") }.font(VT.Font.callout).foregroundStyle(ink.secondary)
                }
                briefButton(item, about: about, making: makingBrief)
                HomeSecondaryButton("Practise") { HomeRouter.shared.showPractice(session: session) }
                    .disabled(meeting.running)
                HomeSecondaryButton("Open") {
                    if meeting.sessions.contains(session), !meeting.running { settings.sessionName = session }
                    HomeRouter.shared.selectedSession = session
                    HomeRouter.shared.page = .sessions
                }
            } else if upNext.preparing.contains(item.id) {
                ProgressView().controlSize(.small)
                Text("Preparing…", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
            } else {
                Text("Not prepared", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.tertiary)
                briefButton(item, about: about, making: false)
                HomeSecondaryButton("Prepare") { upNext.prepare(item) }
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 56)
        .padding(.vertical, about == nil ? 0 : 6)
    }

    @ViewBuilder private func briefButton(_ item: HomeUpNextItem, about: (entity: MemoryEntity, past: [HomeSession])?, making: Bool) -> some View {
        if let env = watch.env, let about {
            UpNextBriefButton(item: item, entity: about.entity, past: about.past, env: env, ownerName: settings.ownerName, busyElsewhere: making)
        }
    }
}

/// Render only: Up next's Brief popover drawn open under its button (a real popover is a window of its own and is not in a capture).
struct UpNextBriefRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var upNextBriefRender: Bool {
        get { self[UpNextBriefRenderKey.self] }
        set { self[UpNextBriefRenderKey.self] = newValue }
    }
}

/// The **Brief** button of an Up next item (memory spec 5.4): a fresh brief opens a popover; none makes the entity's brief first
/// (a spinner and "Brief…") and then opens it.
struct UpNextBriefButton: View {
    var item: HomeUpNextItem
    var entity: MemoryEntity
    var past: [HomeSession]
    var env: SessionMemoryEnvironment
    var ownerName: String
    /// The automatic brief of this item's session is being made: the button waits.
    var busyElsewhere = false
    @ObservedObject private var memory: MemoryService
    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.upNextBriefRender) private var drawnOpen
    @State private var brief: BriefFile?
    @State private var presenting = false
    @State private var failure: ChatFailure?
    @State private var animated = false

    init(item: HomeUpNextItem, entity: MemoryEntity, past: [HomeSession], env: SessionMemoryEnvironment, ownerName: String, busyElsewhere: Bool = false) {
        self.item = item
        self.entity = entity
        self.past = past
        self.env = env
        self.ownerName = ownerName
        self.busyElsewhere = busyElsewhere
        _memory = ObservedObject(wrappedValue: env.memory)
    }

    private var making: Bool { busyElsewhere || memory.briefsInFlight.contains(entity.id) }

    var body: some View {
        HStack(spacing: 6) {
            if making && !busyElsewhere { ProgressView().controlSize(.small) }
            HomeSecondaryButton(making ? "Brief…" : "Brief", symbol: "text.document", action: tap)
                .disabled(making)
                .help(Text(verbatim: L10n.tr("About $0.05 on your Anthropic key")))
                .accessibilityIdentifier("verse.home.prepare.brief")
        }
        .popover(isPresented: $presenting, arrowEdge: .bottom) { popover }
        .overlay(alignment: .topTrailing) {
            if drawnOpen, brief != nil {
                popover
                    .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous).strokeBorder(ink.floatingEdge, lineWidth: 1) }
                    .shadow(color: .black.opacity(ink.dark ? 0.45 : 0.14), radius: 14, y: 6)
                    .fixedSize()
                    .offset(y: 34)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(drawnOpen ? 1 : 0)
        .task(id: "\(entity.id)|\(item.session ?? "")") { reload() }
        .onChange(of: memory.briefsInFlight) { _, _ in reload() }
    }

    private func reload() {
        let own = item.session.flatMap { BriefStore.load(sessionDir: env.sessions.root.appendingPathComponent($0, isDirectory: true)) }
        brief = own ?? BriefStore.load(entity: entity.id, paths: env.memory.paths)
    }

    private func tap() {
        switch Self.action(brief: brief, failure: failure) {
        case .open: presenting = true
        case .make: make()
        }
    }

    enum Action: Equatable { case open, make }

    /// A brief opens its popover; none makes the entity's brief first (spec 5.4).
    static func action(brief: BriefFile?, failure: ChatFailure?) -> Action { brief != nil && failure == nil ? .open : .make }

    private func make() {
        guard let event = item.event,
              let request = BriefPlanning.request(for: event, session: item.session, file: env.people.file, folders: env.sessions.folders.file,
                                                  sessions: env.sessions.sessions, sessionsRoot: env.sessions.root) else { return }
        failure = nil
        Task { @MainActor in
            switch await env.briefs.run(request, session: item.session) {
            case .success:
                reload()
                animated = true
            case .failure(let f):
                if f.kind != "cancelled" { failure = f }
            }
            presenting = true
        }
    }

    private func briefView(_ b: BriefFile) -> BriefView {
        var view = BriefView(brief: b, ownerName: ownerName, availableSessions: Set(env.sessions.sessions.map(\.name))) { cite in
            presenting = false
            env.router.showSession(cite.session, reveal: EntityPageView.reveal(for: cite))
        }
        view.animated = animated
        return view
    }

    private var popover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HomeSecondaryButton(verbatim: entity.kind == .person ? L10n.tr("Open \(PeopleModel.shortName(entity))'s page") : L10n.tr("Open \(entity.name)")) {
                    presenting = false
                    env.router.showEntity(entity.id)
                }
                if let failure {
                    HomeNote(verbatim: PeopleModel.failureText(failure), isError: true)
                    HomeSecondaryButton("Retry") { make() }
                } else if let brief {
                    if let newest = past.first, brief.isStale(newestSession: newest.name) {
                        HStack(spacing: 12) {
                            Text("Made before your \(PeopleModel.date(newest.date)) meeting.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
                            Spacer(minLength: 8)
                            HomeSecondaryButton("Update") { presenting = false; make() }
                        }
                    }
                    briefView(brief)
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: 520)
        .background(ink.floating)
        .accessibilityIdentifier("verse.home.prepare.briefPopover")
    }
}

/// The menu-bar block: opens the home window on Prepare.
public struct ConversationMenuBlock: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button {
            HomeRouter.shared.show(.prepare, openWindow: openWindow)
        } label: { Text("New session from a conversation…", bundle: .module) }
    }
}

public enum ConversationWindow {
    public static let id = HomeRouter.windowID
}
