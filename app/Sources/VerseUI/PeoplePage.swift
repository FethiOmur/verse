import AppKit
import SwiftUI
import VerseMeet

// The People page (memory spec 5.1): a list column of the people and companies of the owner's meetings, and the entity page in the
// detail column. This file holds the container, the list column and the pure model they draw from (`PeopleModel`); the entity page is
// `EntityPageView.swift`, the brief's reading column `BriefView.swift`.

// MARK: - Model (pure)

enum PeopleModel {
    /// One row of the list column.
    struct Row: Equatable, Identifiable {
        var id: String
        var kind: MemoryEntity.Kind
        var name: String
        /// A person's company.
        var companyName: String?
        /// A company's people that are listed (have a session or an upcoming event).
        var people = 0
        /// Held meetings (transcript or summary).
        var meetings = 0
        var lastMet: Date?
        /// The start of the soonest upcoming event.
        var next: Date?
        /// Folded name, aliases, emails, domains and company: what a search looks in.
        var haystack: [String] = []
    }

    struct List: Equatable {
        var people: [Row] = []
        var companies: [Row] = []
        var hidden: [Row] = []

        var isEmpty: Bool { people.isEmpty && companies.isEmpty && hidden.isEmpty }
        /// The rows in the order the list shows them, for the arrow keys. A collapsed Hidden section is skipped.
        func order(includingHidden: Bool) -> [String] {
            (people + companies + (includingHidden ? hidden : [])).map(\.id)
        }
    }

    /// Upcoming first (soonest), then last met (newest first), then by name.
    static func ordered(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            switch (a.next, b.next) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.lastMet != b.lastMet { return (a.lastMet ?? .distantPast) > (b.lastMet ?? .distantPast) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The listed entities: those with a session or an upcoming event (spec 2.5 "Listed"), not hidden; hidden ones are in `hidden` so
    /// they can be brought back. `query` filters by folded name, alias, email, domain or company.
    static func list(file: PeopleFile, folders: FoldersFile, sessions: [HomeSession], upcoming: [HomeUpNextItem], query: String = "") -> List {
        let q = TextFold.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        var out = List()
        let nameOf: [String: String] = Dictionary(uniqueKeysWithValues: file.entities.map { ($0.id, $0.name) })
        for e in file.entities {
            let mine = EntityResolver.sessions(of: e.id, file: file, folders: folders, sessions: sessions)
            let held = mine.filter(EntityResolver.wasHeld)
            let next = EntityResolver.upcoming(of: e.id, file: file, folders: folders, items: upcoming).first
            let company = e.company.flatMap { nameOf[$0] }
            var row = Row(id: e.id, kind: e.kind, name: e.name, companyName: company, meetings: held.count,
                          lastMet: held.first?.date, next: next?.event?.start)
            row.haystack = (e.foldedNames + e.emails + e.domains + [company.map(TextFold.fold)].compactMap { $0 })
            if !q.isEmpty, !row.haystack.contains(where: { $0.contains(q) }) { continue }
            if e.hidden { out.hidden.append(row); continue }
            guard !mine.isEmpty || next != nil else { continue }
            if e.kind == .person { out.people.append(row) } else { out.companies.append(row) }
        }
        for i in out.companies.indices {
            let id = out.companies[i].id
            out.companies[i].people = out.people.filter { p in file.entities.first { $0.id == p.id }?.company == id }.count
        }
        out.people = ordered(out.people)
        out.companies = ordered(out.companies)
        out.hidden = out.hidden.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }

    /// What an entity page shows, worked out from the files.
    struct Page: Equatable {
        var entity: MemoryEntity
        /// A person's company.
        var company: MemoryEntity?
        /// A company's people.
        var people: [MemoryEntity]
        /// Held meetings, newest first (transcript or summary).
        var meetings: [HomeSession]
        /// Up next events that are about the entity, soonest first.
        var upcoming: [HomeUpNextItem]
        /// "Maybe also": sessions that mention the entity.
        var suggestions: [HomeSession]
        var mergeSuggestion: MemoryEntity?
    }

    static func page(for id: String, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession], upcoming: [HomeUpNextItem]) -> Page? {
        guard let entity = EntityStore.resolve(id: id, in: file) else { return nil }
        let all = EntityResolver.sessions(of: entity.id, file: file, folders: folders, sessions: sessions)
        let names = Set(EntityResolver.suggestions(for: entity.id, file: file, folders: folders, sessions: sessions))
        return Page(
            entity: entity,
            company: entity.company.flatMap { c in file.entities.first { $0.id == c } },
            people: entity.kind == .company ? file.entities.filter { $0.kind == .person && $0.company == entity.id && !$0.hidden } : [],
            meetings: all.filter(EntityResolver.wasHeld),
            upcoming: EntityResolver.upcoming(of: entity.id, file: file, folders: folders, items: upcoming),
            suggestions: sessions.filter { names.contains($0.name) },
            mergeSuggestion: EntityResolver.mergeSuggestion(for: entity.id, file: file))
    }

    // MARK: brief plate

    enum BriefState: Equatable {
        /// No past meeting with a transcript or summary: the plate is not shown.
        case hidden
        case none(pastMeetings: Int)
        case making
        case failed(ChatFailure)
        case ready(BriefFile)
        /// A newer meeting exists since the brief was made.
        case stale(BriefFile, newest: HomeSession)
    }

    static func briefState(past: [HomeSession], brief: BriefFile?, making: Bool, failure: ChatFailure?) -> BriefState {
        guard let newest = past.first else { return .hidden }
        if making { return .making }
        if let failure { return .failed(failure) }
        guard let brief else { return .none(pastMeetings: past.count) }
        return brief.isStale(newestSession: newest.name) ? .stale(brief, newest: newest) : .ready(brief)
    }

    /// The sentence under a failed brief: the Ask texts, plus `no_sessions`.
    static func failureText(_ f: ChatFailure) -> String {
        f.kind == "no_sessions" ? L10n.tr("There are no past meetings to sum up yet.") : AskMessages.text(for: f)
    }

    // MARK: text

    /// "Marta" for "Marta Velin"; a company keeps its whole name.
    static func shortName(_ e: MemoryEntity) -> String {
        e.kind == .person ? (e.name.split(separator: " ").first.map(String.init) ?? e.name) : e.name
    }

    /// Up to two initials: "Marta Velin" -> "MV", "Halden" -> "H".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    static func meetingsText(_ n: Int) -> String { n == 1 ? L10n.tr("1 meeting") : L10n.tr("\(n) meetings") }
    static func peopleText(_ n: Int) -> String { n == 1 ? L10n.tr("1 person") : L10n.tr("\(n) people") }

    /// "19 Oct".
    static func date(_ d: Date) -> String { d.formatted(BriefLayout.shortDate) }

    /// "Tomorrow 10:00", "Today 14:30", "Wed 28 Oct 10:00".
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(d) { day = L10n.tr("Today") } else if cal.isDateInTomorrow(d) { day = L10n.tr("Tomorrow") } else {
            day = d.formatted(HomeFormat.dayMonth)
        }
        return "\(day) \(d.formatted(HomeFormat.time))"
    }

    /// The row's second line and whether its last part is an upcoming meeting (shown in secondary ink).
    static func secondLine(_ r: Row, countingMeetings: Bool = true) -> (head: String, tail: String?, upcoming: Bool) {
        var parts: [String] = []
        switch r.kind {
        case .person: if let c = r.companyName { parts.append(c) }
        case .company: if r.people > 0 { parts.append(peopleText(r.people)) }
        }
        if r.meetings > 0, countingMeetings { parts.append(meetingsText(r.meetings)) }
        if let next = r.next { return (parts.joined(separator: " · "), when(next), true) }
        if let last = r.lastMet, r.meetings > 0 { return (parts.joined(separator: " · "), date(last), false) }
        return (parts.joined(separator: " · "), nil, false)
    }
}

/// The preference the page keeps (spec 3.8).
@MainActor
struct PeoplePrefs {
    var defaults = Bundle.main.bundleIdentifier == AppSettings.suiteName ? UserDefaults.standard
        : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard

    var collapsedHidden: Bool {
        get { defaults.object(forKey: "peopleCollapsedHidden") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "peopleCollapsedHidden") }
    }
}

// MARK: - Page

/// People: list | entity page.
struct PeoplePage: View {
    @ObservedObject var store: EntityStore
    @ObservedObject var sessions: HomeSessionsModel
    @ObservedObject var upNext: HomeUpNextModel
    @ObservedObject var memory: MemoryService
    @ObservedObject var router: HomeRouter
    @ObservedObject var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeInk) private var ink
    @State private var query = ""
    @State private var hiddenCollapsed = PeoplePrefs().collapsedHidden
    @State private var toast: SessionToast?
    @State private var toastUndo: (() -> Void)?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var data: PeopleModel.List {
        PeopleModel.list(file: store.file, folders: sessions.folders.file, sessions: sessions.sessions, upcoming: upNext.items,
                         query: query)
    }

    private var everything: PeopleModel.List {
        PeopleModel.list(file: store.file, folders: sessions.folders.file, sessions: sessions.sessions, upcoming: upNext.items)
    }

    var body: some View {
        let data = data
        Group {
            if everything.isEmpty {
                emptyPage
            } else {
                HStack(alignment: .top, spacing: 0) {
                    PeopleListColumn(data: data, query: $query, hiddenCollapsed: $hiddenCollapsed, selectedID: selectedID(in: data),
                                     searchFocused: $searchFocused, notice: store.notice,
                                     onDismissNotice: { store.dismissNotice() }, onSelect: { router.selectedEntity = $0 })
                        .frame(width: 254, alignment: .leading)
                        .focusable().focused($listFocused).focusEffectDisabled()
                        .onKeyPress(.upArrow) { move(-1, in: data) }
                        .onKeyPress(.downArrow) { move(1, in: data) }
                    if let id = selectedID(in: data) {
                        EntityPageView(entityID: id, store: store, sessions: sessions, upNext: upNext, memory: memory, router: router,
                                       settings: settings, onToast: showToast)
                            .id(id)
                            .transition(.opacity)
                    } else {
                        Spacer()
                    }
                }
                .animation(reduceMotion ? AskMotion.crossfade : AskMotion.crossfade, value: selectedID(in: data))
            }
        }
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { toastBar }
        .animation(reduceMotion ? AskMotion.crossfade : .smooth(duration: 0.28), value: toast)
        .onAppear { store.refresh() }
        .onChange(of: hiddenCollapsed) { _, v in PeoplePrefs().collapsedHidden = v }
        .onExitCommand { if !query.isEmpty { query = "" } }
        .accessibilityIdentifier("verse.home.people")
    }

    /// The router's choice (an old id follows `merged`), else the first row of the list.
    private func selectedID(in data: PeopleModel.List) -> String? {
        if let id = router.selectedEntity, let e = store.resolve(id: id) { return e.id }
        return data.order(includingHidden: !hiddenCollapsed).first ?? data.hidden.first?.id
    }

    private func move(_ step: Int, in data: PeopleModel.List) -> KeyPress.Result {
        let order = data.order(includingHidden: !hiddenCollapsed)
        guard !order.isEmpty else { return .ignored }
        let i = selectedID(in: data).flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        router.selectedEntity = order[max(0, min(order.count - 1, i + step))]
        return .handled
    }

    // MARK: empty

    private var emptyPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("People", bundle: .module).font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                Spacer()
            }
            .padding(.leading, 28).padding(.top, 22)
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Text("People appear here from your calendar invites and your session folders.", bundle: .module)
                    .font(VT.Font.body).foregroundStyle(ink.secondary).multilineTextAlignment(.center).lineSpacing(3)
                if !upNext.calendarOn {
                    Text("Turn on “Use my calendar” in Settings to add the people you meet.", bundle: .module)
                        .font(VT.Font.callout).foregroundStyle(ink.tertiary).multilineTextAlignment(.center)
                }
                HomeSecondaryButton("Open Sessions") { router.page = .sessions }
                    .accessibilityIdentifier("verse.home.people.openSessions")
            }
            .frame(maxWidth: 360)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: toast

    @ViewBuilder private var toastBar: some View {
        if let toast {
            SessionToastView(toast: toast, onUndo: {
                toastUndo?()
                dismissToast()
            })
            .padding(.bottom, 20)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ message: String, undo: @escaping () -> Void) {
        let t = SessionToast(message: message, undoable: true)
        toast = t
        toastUndo = undo
        AccessibilityNotification.Announcement(message).post()
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, toast?.id == t.id else { return }
            dismissToast()
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        toast = nil
        toastUndo = nil
    }
}

// MARK: - List column

struct PeopleListColumn: View {
    var data: PeopleModel.List
    @Binding var query: String
    @Binding var hiddenCollapsed: Bool
    var selectedID: String?
    var searchFocused: FocusState<Bool>.Binding
    var notice: String?
    var onDismissNotice: () -> Void
    var onSelect: (String) -> Void
    @Environment(\.homeInk) private var ink
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("People", bundle: .module).font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                .padding(.leading, 10).padding(.bottom, 14)
            searchField.padding(.bottom, 12)
            if let notice {
                HomeNote(verbatim: notice).padding(.horizontal, 10).padding(.bottom, 8).onTapGesture(perform: onDismissNotice)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section(LocalizedStringKey("People"), rows: data.people, first: true)
                    section(LocalizedStringKey("Companies"), rows: data.companies, first: data.people.isEmpty)
                    hiddenSection
                    if data.people.isEmpty, data.companies.isEmpty, data.hidden.isEmpty {
                        Text("No one matches your search.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.tertiary)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 0).padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.tertiary)
            TextField("", text: $query, prompt: Text("Search people and companies", bundle: .module).foregroundStyle(ink.tertiary))
                .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary)
                .focused(searchFocused)
                .onExitCommand { query = ""; searchFocused.wrappedValue = false }
                .accessibilityIdentifier("verse.home.people.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear", bundle: .module))
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
        .overlay {
            if ink.increaseContrast {
                RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
            }
        }
        .frame(width: 236)
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, rows: [PeopleModel.Row], first: Bool) -> some View {
        if !rows.isEmpty {
            header(Text(title, bundle: .module), count: rows.count, collapsed: nil).padding(.top, first ? 0 : 8)
            ForEach(rows) { row($0) }
        }
    }

    @ViewBuilder private var hiddenSection: some View {
        if !data.hidden.isEmpty {
            header(Text("Hidden", bundle: .module), count: data.hidden.count, collapsed: hiddenCollapsed).padding(.top, 8)
            if !hiddenCollapsed { ForEach(data.hidden) { row($0) } }
        }
    }

    private func header(_ title: Text, count: Int, collapsed: Bool?) -> some View {
        let label = HStack(spacing: 6) {
            if let collapsed {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 10)
            }
            title.font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: "\(count)").font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.tertiary)
        }
        .padding(.horizontal, 10).frame(width: 236, height: 28, alignment: .leading)
        return Group {
            if collapsed != nil {
                Button { withAnimation(AskMotion.tint) { hiddenCollapsed.toggle() } } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityValue(hiddenCollapsed ? Text("Collapsed", bundle: .module) : Text("Expanded", bundle: .module))
            } else {
                label
            }
        }
    }

    private func row(_ r: PeopleModel.Row) -> some View {
        let on = r.id == selectedID
        let line = PeopleModel.secondLine(r)
        return Button { onSelect(r.id) } label: {
            HStack(spacing: 10) {
                PeopleMonogram(name: r.name, kind: r.kind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: r.name).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                    secondLine(r)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 236, height: 44, alignment: .leading)
            .background(on ? ink.selection : (hovered == r.id ? ink.fill : .clear),
                        in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(AskMotion.tint) { if inside { hovered = r.id } else if hovered == r.id { hovered = nil } }
        }
        .animation(AskMotion.tint, value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: r.name))
        .accessibilityValue(Text(verbatim: [line.head, line.tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("verse.home.people.row")
    }

    private func secondLine(_ r: PeopleModel.Row) -> some View {
        // The full line, then (for an upcoming meeting, whose time is long) the line without the meetings count: the time stays whole.
        ViewThatFits(in: .horizontal) {
            lineText(PeopleModel.secondLine(r)).fixedSize(horizontal: true, vertical: false)
            lineText(PeopleModel.secondLine(r, countingMeetings: false)).fixedSize(horizontal: true, vertical: false)
            lineText(PeopleModel.secondLine(r, countingMeetings: false))
        }
    }

    private func lineText(_ line: (head: String, tail: String?, upcoming: Bool)) -> some View {
        var text = AttributedString(line.head)
        text.foregroundColor = ink.tertiary
        if let tail = line.tail {
            var dot = AttributedString(line.head.isEmpty ? "" : " · ")
            dot.foregroundColor = ink.tertiary
            var when = AttributedString(tail)
            when.foregroundColor = line.upcoming ? ink.secondary : ink.tertiary
            text += dot + when
        }
        return Text(text).font(VT.Font.caption).lineLimit(1)
    }
}

/// The monogram: initials on a neutral fill, a circle for a person and a 6 pt rounded square for a company. No colour, no photo.
struct PeopleMonogram: View {
    var name: String
    var kind: MemoryEntity.Kind
    var size: CGFloat
    @Environment(\.homeInk) private var ink

    var body: some View {
        let shape = kind == .person ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size >= 40 ? 11 : 6, style: .continuous))
        Text(verbatim: PeopleModel.initials(name))
            .font(.system(size: size >= 40 ? 15 : 10.5, weight: .semibold)).foregroundStyle(ink.secondary)
            .frame(width: size, height: size)
            .background(ink.fill, in: shape)
            .accessibilityHidden(true)
    }
}
