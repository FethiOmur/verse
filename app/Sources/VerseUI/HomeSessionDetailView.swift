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
    /// The Ask button (spec 2.2): `.hidden` for practice runs and prepared sessions, disabled with a hint while the call is recorded or
    /// when there is no transcript. `onAsk` opens the panel; with the panel open the header stacks its actions under the title.
    var askAvailability: AskAvailability = .hidden
    var askOpen = false
    var onAsk: () -> Void = {}
    /// The Practise button, its More item and the prepared card's call to action: they open Practice on this session
    /// (`HomeSessionsPage` passes `router.showPractice(session:)`).
    var onPractice: () -> Void = {}
    /// The Trash button and the More menu's Move to Trash act on the selection (`HomeSessionsPage.performTrash`).
    var trash = SessionTrashControl()
    /// Verse's memory (memory spec 5.3): the people row, the brief before a prepared meeting and the brief a past meeting had. nil in
    /// tests and renders that do not need it.
    var memory: SessionMemoryEnvironment?
    /// Where the page asks this detail to be (a citation to the Summary, or to a transcript line that is gone), and the note then.
    var place: SessionDetailPlace?
    var note: String?
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
    /// nil: no Practise button (a practice run, an unprepared call, no pack, or the session being recorded).
    private var practiceStyle: PracticeFromSession.Style? {
        PracticeFromSession.style(for: session, recordingSession: controller.recordingSessionName)
    }
    private var showsTabs: Bool { tabLayout.showsTabs }
    private var shownTab: SessionsDetailTab { tabLayout.shown }

    private var meta: String {
        var parts = [session.unprepared ? L10n.tr("Unprepared · \(session.kindText)") : session.kind.label,
                     "\(HomeFormat.day(session.date)) \(session.date.formatted(HomeFormat.time))"]
        if session.spend > 0 { parts.append(L10n.tr("\(L10n.usd(session.spend)) spent")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message { HomeNote(verbatim: message, isError: messageIsError).padding(.top, 8) }
            if let note { HomeNote(verbatim: note).padding(.top, 8).accessibilityIdentifier("verse.home.sessions.revealNote") }
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
        // A citation of a summary, or of a line that is no longer in the transcript.
        .onChange(of: place) { _, p in
            guard let p else { return }
            if p.tab == .transcript ? hasTranscript : hasSummary { tab = p.tab }
        }
    }

    // MARK: header

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary).lineLimit(2)
            Text(meta).font(VT.Font.callout).foregroundStyle(ink.secondary)
            if let memory, session.kind != .practice {
                SessionPeopleRow(session: session, env: memory).padding(.top, 1)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if session.kind != .practice, !session.unprepared, controller.sessions.contains(session.name) {
            if settings.sessionName == session.name {
                Label { Text("Used for Start", bundle: .module) } icon: { Image(systemName: "checkmark") }.font(VT.Font.callout).foregroundStyle(ink.secondary)
            } else {
                HomeSecondaryButton("Use for Start") { settings.sessionName = session.name }.disabled(controller.running)
            }
        }
        if askAvailability != .hidden {
            HomeSecondaryButton("Ask", symbol: "bubble.left.and.text.bubble.right", action: onAsk)
                .disabled(!askAvailability.isAvailable)
                .help(askHelp)
                .accessibilityIdentifier("verse.home.sessions.ask")
        }
        if let style = practiceStyle {
            switch style {
            case .prominent:
                HomePrimaryButton("Practise", symbol: PracticeFromSession.symbol, action: onPractice)
                    .accessibilityIdentifier("verse.home.sessions.practise")
            case .secondary:
                HomeSecondaryButton("Practise", symbol: PracticeFromSession.symbol, action: onPractice)
                    .accessibilityIdentifier("verse.home.sessions.practise")
            }
        }
        if session.summaryURL != nil, session.kind != .practice {
            HomePrimaryButton("Save to vault", action: saveToVault)
        }
        SessionTrashButton(control: trash)
        SessionChromeMenu(symbol: "ellipsis.circle", help: "More") {
            if practiceStyle != nil {
                Button(action: onPractice) {
                    Label { Text("Practise this meeting", bundle: .module) } icon: { Image(systemName: PracticeFromSession.symbol) }
                }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([session.dir]) } label: { Text("Show in Finder", bundle: .module) }
            Divider()
            Button(role: .destructive) { trash.action() } label: { Text("Move to Trash", bundle: .module) }
                .disabled(!trash.enabled)
        }
    }

    private var askHelp: Text {
        switch askAvailability {
        case .recording: Text("Available when the call ends", bundle: .module)
        case .noTranscript: Text("This session has no transcript to ask about", bundle: .module)
        default: Text("Ask this meeting", bundle: .module)
        }
    }

    @ViewBuilder private var header: some View {
        if askOpen {
            // The panel leaves this column 340 pt: the actions go under the title.
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                AskFlow(space: 8, lineSpacing: 8, uniformSpace: true) { actions }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                titleBlock
                Spacer(minLength: 8)
                actions
            }
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
        } else if SessionBriefPlacement.showsPlate(session), let memory {
            // A prepared session: "Before this meeting" above the prepared card (memory spec 5.3).
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SessionBriefPlate(session: session, ownerName: settings.ownerName, env: memory)
                    HomeGroup(plate: true) {
                        VStack(alignment: .leading, spacing: 14) { content }
                            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
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
            Text(verbatim: session.kind == .prepared
                 ? L10n.tr("Prepared, not used in a meeting yet. Pick it with “Use for Start” and press Start in the menu, or open a meeting that matches it.")
                 : L10n.tr("Nothing was written for this session."))
                .font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(4)
            if session.kind == .prepared, practiceStyle != nil {
                HomeSecondaryButton("Practise this meeting", symbol: PracticeFromSession.symbol, action: onPractice)
                    .accessibilityIdentifier("verse.home.sessions.practiseCard")
            }
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
            Text("Questions you got", bundle: .module).font(VT.Font.title).foregroundStyle(ink.primary).padding(.top, 4)
            ForEach(Array(detail.questions.prefix(12)), id: \.self) { q in
                Text(q).font(VT.Font.body).foregroundStyle(ink.primary).fixedSize(horizontal: false, vertical: true)
            }
            if detail.questions.count > 12 {
                Text("and \(detail.questions.count - 12) more in the transcript", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
            }
        }
        // The brief this meeting had, collapsed (memory spec 5.3).
        if let memory, SessionBriefPlacement.showsDisclosure(session) {
            SessionBriefDisclosure(session: session, ownerName: settings.ownerName, env: memory)
        }
    }

    private static let cap = 8

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > Self.cap {
            Text("and \(count - Self.cap) more in summary.md", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
        }
    }

    private static func heading(_ s: String) -> String {
        switch s {
        case "Summary": L10n.tr("Summary")
        case "Decisions": L10n.tr("Decisions")
        case "Actions": L10n.tr("Follow up")
        case "Open questions": L10n.tr("Still open")
        case "Conflicts with the fact sheet": L10n.tr("Conflicts with the fact sheet")
        case "Metrics": L10n.tr("Metrics")
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
            message = L10n.tr("Saved to \((url.path as NSString).abbreviatingWithTildeInPath)")
            messageIsError = false
        } catch {
            message = "\(error)"
            messageIsError = true
        }
    }
}

// MARK: - Memory in the detail (memory spec 5.3)

/// What a session's detail and Up next need to show people and briefs. References, so a change anywhere redraws the views that watch.
struct SessionMemoryEnvironment {
    let memory: MemoryService
    let people: EntityStore
    let sessions: HomeSessionsModel
    let router: HomeRouter
    let briefs: AutoBriefCenter
}

/// "Making the brief…": one quiet line that breathes like Ask's Thinking line (1.1 s per half cycle); still under Reduce Motion.
struct BriefMakingLine: View {
    var animated: Bool
    @Environment(\.homeInk) private var ink
    @State private var dim = false

    var body: some View {
        Text("Making the brief…", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary)
            .opacity(animated && dim ? 0.45 : 1)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityElement(children: .combine)
    }
}

/// The session's people under its meta line: plain text links to their pages, and "Add person…" to link one by hand or take one out.
struct SessionPeopleRow: View {
    var session: HomeSession
    var env: SessionMemoryEnvironment
    @ObservedObject private var people: EntityStore
    @ObservedObject private var sessions: HomeSessionsModel
    @Environment(\.homeInk) private var ink
    @State private var adding = false

    init(session: HomeSession, env: SessionMemoryEnvironment) {
        self.session = session
        self.env = env
        _people = ObservedObject(wrappedValue: env.people)
        _sessions = ObservedObject(wrappedValue: env.sessions)
    }

    private var entities: [MemoryEntity] { people.entities(of: session.name, folders: sessions.folders.file) }

    var body: some View {
        AskFlow(space: 6, lineSpacing: 2, uniformSpace: true) {
            ForEach(Array(entities.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 6) {
                    PersonLink(name: e.name) { env.router.showEntity(e.id) }
                    if i < entities.count - 1 { Text(verbatim: "·").font(VT.Font.callout).foregroundStyle(ink.tertiary) }
                }
            }
            Button { adding = true } label: {
                Text("Add person…", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary).frame(height: 18)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                SessionPeoplePicker(session: session.name, env: env)
            }
            .accessibilityIdentifier("verse.home.sessions.addPerson")
        }
        .accessibilityElement(children: .contain)
    }
}

/// A name that is a link: secondary text, underlined while the pointer is on it.
private struct PersonLink: View {
    var name: String
    var action: () -> Void
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: name).font(VT.Font.callout).foregroundStyle(hover ? ink.primary : ink.secondary).underline(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(AskMotion.tint, value: hover)
    }
}

/// The popover of "Add person…": every person and company, the ones in this meeting ticked. A click links or unlinks.
private struct SessionPeoplePicker: View {
    var session: String
    var env: SessionMemoryEnvironment
    @ObservedObject private var people: EntityStore
    @ObservedObject private var sessions: HomeSessionsModel
    @Environment(\.homeInk) private var ink
    @State private var query = ""

    init(session: String, env: SessionMemoryEnvironment) {
        self.session = session
        self.env = env
        _people = ObservedObject(wrappedValue: env.people)
        _sessions = ObservedObject(wrappedValue: env.sessions)
    }

    private var members: Set<String> { Set(people.entities(of: session, folders: sessions.folders.file).map(\.id)) }

    private var candidates: [MemoryEntity] {
        let q = TextFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let inside = members
        return people.file.entities.filter { !$0.hidden && (q.isEmpty || $0.foldedNames.contains { $0.contains(q) }) }
            .sorted { a, b in
                let ia = inside.contains(a.id), ib = inside.contains(b.id)
                if ia != ib { return ia }
                if a.kind != b.kind { return a.kind == .person }
                return TextFold.fold(a.name) < TextFold.fold(b.name)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.tertiary)
                TextField("", text: $query, prompt: Text("Search people and companies", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { e in row(e) }
                    if candidates.isEmpty {
                        Text("Nobody matches.", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary).padding(10)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12).frame(width: 320)
    }

    private func row(_ e: MemoryEntity) -> some View {
        let inside = members.contains(e.id)
        return Button {
            if inside { people.unlink(session, from: e.id) } else { people.link(session, to: e.id) }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: e.name).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.primary).lineLimit(1)
                Text(e.kind == .person ? "Person" : "Company", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
                Spacer(minLength: 6)
                Image(systemName: inside ? "checkmark" : "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(inside ? ink.primary : ink.tertiary)
            }
            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(inside ? .isSelected : [])
    }
}

/// What a session's detail shows about its brief (memory spec 5.3), apart from the views.
enum SessionBriefPlacement {
    /// The plate above the prepared card is for a session that was not held; a held one keeps its brief in the Summary tab's disclosure.
    static func showsPlate(_ s: HomeSession) -> Bool { s.kind == .prepared && !EntityResolver.wasHeld(s) }

    static func showsDisclosure(_ s: HomeSession) -> Bool { s.kind != .practice && EntityResolver.wasHeld(s) }

    /// The session's own `brief.json`, else the latest brief of its primary entity.
    static func brief(for session: HomeSession, entity: MemoryEntity?, paths: MemoryPaths) -> BriefFile? {
        BriefStore.load(sessionDir: session.dir) ?? entity.flatMap { BriefStore.load(entity: $0.id, paths: paths) }
    }

    /// The primary entity of the session and its past meetings (held, newest first, without the session itself).
    static func about(_ session: HomeSession, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> (entity: MemoryEntity, past: [HomeSession])? {
        guard let e = BriefPlanning.primaryEntity(of: session.name, file: file, folders: folders, sessions: sessions) else { return nil }
        return (e, EntityResolver.pastSessions(of: e.id, excluding: session.name, file: file, folders: folders, sessions: sessions))
    }

    /// `hidden` (no plate) without a past meeting; "You've met Marta 3 times. Make a brief?" without a brief; Update when stale.
    static func state(past: [HomeSession], brief: BriefFile?, making: Bool, failure: ChatFailure?) -> PeopleModel.BriefState {
        PeopleModel.briefState(past: past, brief: brief, making: making, failure: failure)
    }
}

/// "Before this meeting": the brief of a prepared session, above its prepared card (memory spec 5.3).
struct SessionBriefPlate: View {
    var session: HomeSession
    var ownerName: String
    var env: SessionMemoryEnvironment
    @ObservedObject private var people: EntityStore
    @ObservedObject private var sessions: HomeSessionsModel
    @ObservedObject private var memory: MemoryService
    @ObservedObject private var briefs: AutoBriefCenter
    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var brief: BriefFile?
    @State private var animated = false

    init(session: HomeSession, ownerName: String, env: SessionMemoryEnvironment) {
        self.session = session
        self.ownerName = ownerName
        self.env = env
        _people = ObservedObject(wrappedValue: env.people)
        _sessions = ObservedObject(wrappedValue: env.sessions)
        _memory = ObservedObject(wrappedValue: env.memory)
        _briefs = ObservedObject(wrappedValue: env.briefs)
    }

    private var about: (entity: MemoryEntity, past: [HomeSession])? {
        SessionBriefPlacement.about(session, file: people.file, folders: sessions.folders.file, sessions: sessions.sessions)
    }

    private var entity: MemoryEntity? { about?.entity }
    private var past: [HomeSession] { about?.past ?? [] }

    private var making: Bool {
        briefs.making.contains(session.name) || (entity.map { memory.briefsInFlight.contains($0.id) } ?? false)
    }

    private var state: PeopleModel.BriefState {
        SessionBriefPlacement.state(past: past, brief: brief, making: making, failure: briefs.failures[session.name])
    }

    var body: some View {
        let state = state
        Group {
            if state != .hidden, let entity {
                EntityPlate(title: "Before this meeting", caption: caption(state)) {
                    stateBody(state, entity: entity)
                }
                .accessibilityIdentifier("verse.home.sessions.briefPlate")
            }
        }
        .task(id: session.name) { reload() }
        .onChange(of: memory.briefsInFlight) { old, new in
            reload()
            if !old.isEmpty, new.isEmpty, brief != nil { animated = true }
        }
        .onChange(of: briefs.making) { _, _ in reload() }
    }

    private func reload() {
        brief = SessionBriefPlacement.brief(for: session, entity: entity, paths: memory.paths)
    }

    private func caption(_ state: PeopleModel.BriefState) -> String? {
        switch state {
        case .ready(let b), .stale(let b, _):
            var parts = [L10n.tr("Made \(PeopleModel.date(b.madeAt))"), AskModel.displayName(forModelID: b.model)]
            if b.costUSD > 0 { parts.append(L10n.usd(b.costUSD)) }
            return parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    @ViewBuilder private func stateBody(_ state: PeopleModel.BriefState, entity: MemoryEntity) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .none(let n):
            HStack(spacing: 12) {
                Text(verbatim: metText(n, entity: entity)).font(VT.Font.body).foregroundStyle(ink.secondary)
                Spacer(minLength: 8)
                HomeSecondaryButton("Make brief") { make() }.accessibilityIdentifier("verse.home.sessions.makeBrief")
            }
        case .making:
            HStack(spacing: 14) {
                BriefMakingLine(animated: !reduceMotion)
                Spacer(minLength: 8)
                HomeSecondaryButton("Cancel") { memory.cancelBrief(entity: entity.id) }
            }
        case .failed(let f):
            VStack(alignment: .leading, spacing: 10) {
                HomeNote(verbatim: L10n.tr("The brief could not be made: \(PeopleModel.failureText(f))"), isError: true)
                HomeSecondaryButton("Retry") { retry() }.accessibilityIdentifier("verse.home.sessions.retryBrief")
            }
        case .ready(let b):
            briefView(b)
        case .stale(let b, let newest):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Made before your \(PeopleModel.date(newest.date)) meeting.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
                    Spacer(minLength: 8)
                    HomeSecondaryButton("Update") { make() }.accessibilityIdentifier("verse.home.sessions.updateBrief")
                }
                briefView(b)
            }
        }
    }

    /// "You've met Marta 3 times. Make a brief?"
    private func metText(_ n: Int, entity: MemoryEntity) -> String {
        let who = PeopleModel.shortName(entity)
        return n == 1 ? L10n.tr("You've met \(who) once. Make a brief?") : L10n.tr("You've met \(who) \(n) times. Make a brief?")
    }

    private func briefView(_ b: BriefFile) -> some View {
        var view = BriefView(brief: b, ownerName: ownerName, availableSessions: Set(sessions.sessions.map(\.name))) { cite in
            env.router.showSession(cite.session, reveal: EntityPageView.reveal(for: cite))
        }
        view.animated = animated
        return view
    }

    private func make() {
        guard let request = BriefPlanning.request(forSession: session.name, file: people.file, folders: sessions.folders.file,
                                                  sessions: sessions.sessions, sessionsRoot: sessions.root) else { return }
        briefs.clearFailure(session: session.name)
        Task { @MainActor in
            if case .success = await briefs.run(request, session: session.name) { animated = true }
            reload()
        }
    }

    private func retry() {
        briefs.clearFailure(session: session.name)
        briefs.retry(session: session.name)
    }
}

/// "Your brief before this meeting": collapsed at the end of a past meeting's Summary tab (memory spec 5.3). Open or closed is kept in
/// view state only.
struct SessionBriefDisclosure: View {
    var session: HomeSession
    var ownerName: String
    var env: SessionMemoryEnvironment
    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var brief: BriefFile?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let brief {
                Button {
                    withAnimation(reduceMotion ? AskMotion.crossfade : AskMotion.tint) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(ink.tertiary)
                            .rotationEffect(.degrees(open && !reduceMotion ? 90 : 0))
                        Text("Your brief before this meeting", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(Text(open ? "Expanded" : "Collapsed", bundle: .module))
                .accessibilityIdentifier("verse.home.sessions.pastBrief")
                if open {
                    BriefView(brief: brief, ownerName: ownerName, availableSessions: Set(env.sessions.sessions.map(\.name))) { cite in
                        env.router.showSession(cite.session, reveal: EntityPageView.reveal(for: cite))
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.top, brief == nil ? 0 : 6)
        .task(id: session.name) { brief = BriefStore.load(sessionDir: session.dir) }
    }
}
