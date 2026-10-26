import AppKit
import SwiftUI
import VerseMeet

// The page of one person or company (memory spec 5.1): header with Ask about and a menu, the next meeting, the brief, the open
// follow-ups, the meetings timeline, "Maybe also" and "Same person as …?". Everything it shows is computed from the files by
// `PeopleModel` and `EntityResolver`; the only writes are `EntityStore` changes and the brief request.

// MARK: - Timeline and follow-up data (read off the main thread)

/// What a timeline row shows besides its title: the first sentence of the summary, and whether a brief was made before it.
struct TimelineExtras: Equatable, Sendable {
    var snippet: String?
    var hadBrief = false
}

/// An unticked `Actions` line of a meeting's summary.
struct FollowItem: Equatable, Identifiable, Sendable {
    var session: String
    var title: String
    var date: Date
    var text: String
    var id: String { "\(session)|\(text)" }
}

struct EntityFiles: Equatable, Sendable {
    var extras: [String: TimelineExtras] = [:]
    var follow: [FollowItem] = []

    /// The first sentence of the Summary section of `summary.md`'s text.
    static func firstSentence(_ summary: String) -> String? {
        let sections = HomeSessionDetail.parseSummary(summary)
        guard let s = sections.first(where: { $0.title == "Summary" }), let first = s.items.first else { return nil }
        let text = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(text[..<r.upperBound]).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : text
    }

    /// The `Actions` items of a summary's text.
    static func actions(_ summary: String) -> [String] {
        HomeSessionDetail.parseSummary(summary).first { $0.title == "Actions" }?.items ?? []
    }

    /// Reads the summaries and brief files of `sessions` (newest first). Follow-ups are taken from the newest `followLimit` meetings.
    static func load(_ sessions: [HomeSession], followLimit: Int = 12) -> EntityFiles {
        var out = EntityFiles()
        for (n, s) in sessions.enumerated() {
            let text = s.summaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            out.extras[s.name] = TimelineExtras(snippet: firstSentence(text),
                                                hadBrief: FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("brief.json").path))
            if n < followLimit {
                for item in actions(text) { out.follow.append(FollowItem(session: s.name, title: s.title, date: s.date, text: item)) }
            }
        }
        return out
    }
}

/// The language a brief is written in: the prepared session's, else the most common among the meetings, else English.
enum BriefLanguage {
    static func pick(upcoming: String?, past: [String]) -> String {
        if let upcoming, !upcoming.isEmpty { return upcoming }
        let counts = Dictionary(past.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "en"
    }

    /// `meta.json languages[0]` of a session folder, or "".
    static func language(of dir: URL) -> String {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let langs = o["languages"] as? [Any], let first = langs.first as? String else { return "" }
        return first
    }
}

// MARK: - Page

struct EntityPageView: View {
    var entityID: String
    @ObservedObject var store: EntityStore
    @ObservedObject var sessions: HomeSessionsModel
    @ObservedObject var upNext: HomeUpNextModel
    @ObservedObject var memory: MemoryService
    @ObservedObject var router: HomeRouter
    @ObservedObject var settings: AppSettings
    /// Shows the "Merged into …" toast with an Undo.
    var onToast: (String, @escaping () -> Void) -> Void

    @Environment(\.homeInk) private var ink
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.peopleBriefRender) private var briefRender
    @State private var files = EntityFiles()
    @State private var brief: BriefFile?
    @State private var briefFailure: ChatFailure?
    @State private var briefAnimated = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var renameError: EntityError?
    @State private var mergePicker = false
    @State private var pendingMerge: (loser: MemoryEntity, survivor: MemoryEntity)?
    @State private var ticked: Set<String> = []
    @State private var gone: Set<String> = []
    @State private var hovered: String?
    @FocusState private var nameFocused: Bool
    private let checklist = HomeChecklistStore()

    private var page: PeopleModel.Page? {
        PeopleModel.page(for: entityID, file: store.file, folders: sessions.folders.file, sessions: sessions.sessions, upcoming: upNext.items)
    }

    var body: some View {
        if let page {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(page)
                    if page.entity.hidden { hiddenNote(page.entity) }
                    if let next = page.upcoming.first { nextRow(next) }
                    briefPlate(page)
                    followPlate
                    meetingsPlate(page)
                    maybeAlso(page)
                    samePerson(page)
                }
                .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26).padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: loadKey(page)) { await load(page) }
            .confirmationDialog(mergeTitle, isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                                titleVisibility: .visible) {
                Button { if let m = pendingMerge { performMerge(m.loser, into: m.survivor) } } label: { Text("Merge", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Its meetings, emails and names move to “\(pendingMerge?.survivor.name ?? "")”. Its brief and chat are kept on disk and no longer shown.", bundle: .module)
            }
        } else {
            Spacer()
        }
    }

    private var mergeTitle: Text {
        Text("Merge “\(pendingMerge?.loser.name ?? "")” into “\(pendingMerge?.survivor.name ?? "")”?", bundle: .module)
    }

    private func loadKey(_ page: PeopleModel.Page) -> String {
        page.entity.id + "|" + page.meetings.map(\.name).joined(separator: ",")
    }

    private func load(_ page: PeopleModel.Page) async {
        let meetings = page.meetings
        let loaded = await Task.detached { EntityFiles.load(meetings) }.value
        guard !Task.isCancelled else { return }
        files = loaded
        ticked = []
        gone = []
        if let forced = briefRender {
            brief = forced.brief
        } else {
            let id = page.entity.id, paths = memory.paths
            brief = await Task.detached { BriefStore.load(entity: id, paths: paths) }.value
        }
    }

    // MARK: header

    private func meta(_ page: PeopleModel.Page) -> String {
        var parts: [String] = []
        switch page.entity.kind {
        case .person:
            parts.append(L10n.tr("Person"))
            if let c = page.company { parts.append(c.name) }
            if let e = page.entity.emails.first { parts.append(e) }
        case .company:
            parts.append(L10n.tr("Company"))
            if let d = page.entity.domains.first { parts.append(d) }
            if !page.people.isEmpty { parts.append(PeopleModel.peopleText(page.people.count)) }
        }
        return parts.joined(separator: " · ")
    }

    private func header(_ page: PeopleModel.Page) -> some View {
        let e = page.entity
        return HStack(alignment: .top, spacing: 14) {
            PeopleMonogram(name: e.name, kind: e.kind, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary)
                        .focused($nameFocused)
                        .onSubmit { commitRename(e) }
                        .onExitCommand { renaming = false; renameError = nil }
                        .accessibilityLabel(Text("Name", bundle: .module))
                        .accessibilityIdentifier("verse.home.people.rename")
                    if let renameError { HomeNote(verbatim: renameError.message, isError: true) }
                } else {
                    Text(verbatim: e.name).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary)
                        .lineLimit(2).accessibilityAddTraits(.isHeader)
                }
                Text(verbatim: meta(page)).font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                HomeSecondaryButton(verbatim: L10n.tr("Ask about \(PeopleModel.shortName(e))"), symbol: "bubble.left.and.text.bubble.right") {
                    if let newest = page.meetings.first { router.selectedSession = newest.name }
                    router.showAsk(.entity(e.id))
                }
                .accessibilityIdentifier("verse.home.people.ask")
                menu(page)
            }
            .fixedSize()
        }
    }

    private func menu(_ page: PeopleModel.Page) -> some View {
        let e = page.entity
        return SessionChromeMenu(symbol: "ellipsis.circle", help: "More") {
            Button { startRename(e) } label: { Text("Rename…", bundle: .module) }
            Button { changeKind(e) } label: {
                e.kind == .person ? Text("Make This a Company", bundle: .module) : Text("Make This a Person", bundle: .module)
            }
            Button { mergePicker = true } label: { Text("Merge Into…", bundle: .module) }
            Button { setHidden(e, !e.hidden) } label: {
                e.hidden ? Text("Show in People", bundle: .module) : Text("Hide from People", bundle: .module)
            }
            if let folderSession = firstSession(inFoldersOf: e) {
                Divider()
                Button { router.showSession(folderSession, reveal: .none) } label: { Text("Show Folder in Sessions", bundle: .module) }
            }
        }
        .popover(isPresented: $mergePicker, arrowEdge: .bottom) {
            MergePicker(candidates: store.file.entities.filter { $0.id != e.id && $0.kind == e.kind }) { survivor in
                mergePicker = false
                pendingMerge = (e, survivor)
            }
        }
        .accessibilityIdentifier("verse.home.people.menu")
    }

    private func firstSession(inFoldersOf e: MemoryEntity) -> String? {
        let folders = sessions.folders.file
        return sessions.sessions.first { s in folders.assign[s.name].map { e.folders.contains($0) } ?? false }?.name
    }

    private func hiddenNote(_ e: MemoryEntity) -> some View {
        HStack(spacing: 10) {
            Text("Hidden from People.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
            HomeSecondaryButton("Show in People") { setHidden(e, false) }
        }
    }

    // MARK: changes

    private func startRename(_ e: MemoryEntity) {
        draft = e.name
        renameError = nil
        renaming = true
        nameFocused = true
    }

    private func commitRename(_ e: MemoryEntity) {
        do {
            try store.apply(L10n.tr("Rename"), undoManager: undoManager) { try $0.rename(e.id, to: draft) }
            renaming = false
            renameError = nil
        } catch {
            renameError = error
        }
    }

    private func changeKind(_ e: MemoryEntity) {
        let to: MemoryEntity.Kind = e.kind == .person ? .company : .person
        do { try store.apply(L10n.tr("Change Kind"), undoManager: undoManager) { try $0.setKind(e.id, to) } } catch {
            renameError = error
            renaming = true
            draft = e.name
        }
    }

    private func setHidden(_ e: MemoryEntity, _ hidden: Bool) {
        _ = try? store.apply(hidden ? L10n.tr("Hide") : L10n.tr("Show"), undoManager: undoManager) { $0.setHidden(e.id, hidden) }
    }

    private func performMerge(_ loser: MemoryEntity, into survivor: MemoryEntity) {
        pendingMerge = nil
        do {
            let before = try store.apply(L10n.tr("Merge"), undoManager: undoManager) { try $0.merge(loser.id, into: survivor.id) }
            router.selectedEntity = survivor.id
            let um = undoManager
            onToast(L10n.tr("Merged into \(survivor.name)")) {
                if let um, um.canUndo, um.undoActionName == L10n.tr("Merge") { um.undo() } else { store.restore(before) }
                router.selectedEntity = loser.id
            }
        } catch {
            renameError = error
        }
    }

    // MARK: next

    private func nextRow(_ item: HomeUpNextItem) -> some View {
        let when = item.event.map { PeopleModel.when($0.start) } ?? ""
        let preparing = upNext.preparing.contains(item.id)
        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("Next", bundle: .module).foregroundStyle(ink.tertiary)
                Text(verbatim: "·").foregroundStyle(ink.tertiary)
                Text(verbatim: item.title).foregroundStyle(ink.primary).lineLimit(1)
                Text(verbatim: "·").foregroundStyle(ink.tertiary)
                Text(verbatim: when).foregroundStyle(ink.secondary).lineLimit(1).fixedSize()
            }
            .font(VT.Font.body)
            Spacer(minLength: 8)
            if item.session != nil {
                Text("Prepared", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
            } else if item.event != nil {
                HomeSecondaryButton(preparing ? "Preparing…" : "Prepare") { upNext.prepare(item) }.disabled(preparing)
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 40)
        .background(ink.group, in: RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous).strokeBorder(ink.groupEdge, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }

    // MARK: brief

    private func briefPlate(_ page: PeopleModel.Page) -> some View {
        let making = memory.briefsInFlight.contains(page.entity.id)
        let state = PeopleModel.briefState(past: page.meetings, brief: brief, making: making, failure: briefFailure)
        return Group {
            if state != .hidden {
                EntityPlate(title: "Brief", caption: briefCaption(state)) {
                    briefBody(state, page: page)
                }
                .accessibilityIdentifier("verse.home.people.briefPlate")
            }
        }
    }

    private func briefCaption(_ state: PeopleModel.BriefState) -> String? {
        let file: BriefFile?
        switch state {
        case .ready(let b), .stale(let b, _): file = b
        default: file = nil
        }
        guard let b = file else { return nil }
        var parts = [L10n.tr("Made \(PeopleModel.date(b.madeAt))"), AskModel.displayName(forModelID: b.model)]
        if b.costUSD > 0 { parts.append(L10n.usd(b.costUSD)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func briefBody(_ state: PeopleModel.BriefState, page: PeopleModel.Page) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .none(let past):
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: noBriefText(past: past, entity: page.entity)).font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    HomePrimaryButton("Make brief") { makeBrief(page) }.accessibilityIdentifier("verse.home.people.makeBrief")
                    Text("About $0.05 on your Anthropic key.", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
                }
            }
        case .making:
            HStack(spacing: 14) {
                BreathingLine(text: "Making the brief…", animated: !reduceMotion)
                Spacer(minLength: 8)
                HomeSecondaryButton("Cancel") { memory.cancelBrief(entity: page.entity.id) }
            }
        case .failed(let f):
            VStack(alignment: .leading, spacing: 10) {
                HomeNote(verbatim: PeopleModel.failureText(f), isError: true)
                HomeSecondaryButton("Retry") { makeBrief(page) }
            }
        case .ready(let b):
            briefView(b)
        case .stale(let b, let newest):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Made before your \(PeopleModel.date(newest.date)) meeting.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary)
                    Spacer(minLength: 8)
                    HomeSecondaryButton("Update") { makeBrief(page) }.accessibilityIdentifier("verse.home.people.updateBrief")
                }
                briefView(b)
            }
        }
    }

    private func briefView(_ b: BriefFile) -> some View {
        var view = BriefView(brief: b, ownerName: settings.ownerName, availableSessions: Set(sessions.sessions.map(\.name))) { cite in
            router.showSession(cite.session, reveal: Self.reveal(for: cite))
        }
        view.animated = briefAnimated
        return view
    }

    static func reveal(for cite: BriefFile.Cite) -> SessionReveal {
        switch cite.kind {
        case "turn": cite.stamp.map { .stamp($0) } ?? .none
        case "summary": .summary
        default: .none
        }
    }

    private func noBriefText(past: Int, entity: MemoryEntity) -> String {
        let who = PeopleModel.shortName(entity)
        return past == 1
            ? L10n.tr("No brief yet. Verse can sum up your past meeting with \(who): what was said, what was promised and what is still open.")
            : L10n.tr("No brief yet. Verse can sum up your \(past) past meetings with \(who): what was said, what was promised and what is still open.")
    }

    private func makeBrief(_ page: PeopleModel.Page) {
        guard !memory.briefsInFlight.contains(page.entity.id) else { return }
        let e = page.entity
        let item = page.upcoming.first
        var upcoming: BriefRequest.Upcoming?
        if let event = item?.event {
            upcoming = BriefRequest.Upcoming(title: event.title, start: event.start, attendees: EntityResolver.guestNames(of: event, file: store.file))
        }
        let past = Array(page.meetings.prefix(8))
        let upcomingLang = item?.session.map { name in BriefLanguage.language(of: sessions.root.appendingPathComponent(name)) }
        let lang = BriefLanguage.pick(upcoming: upcomingLang, past: past.map { BriefLanguage.language(of: $0.dir) })
        let request = BriefRequest(entity: .init(id: e.id, kind: e.kind.rawValue, name: e.name, company: page.company?.name),
                                   sessions: past.map(\.name), upcoming: upcoming, lang: lang, sessionOut: nil)
        briefFailure = nil
        let paths = memory.paths
        Task { @MainActor in
            let result = await memory.makeBrief(request)
            switch result {
            case .success:
                brief = BriefStore.load(entity: e.id, paths: paths)
                briefAnimated = true
                AccessibilityNotification.Announcement(L10n.tr("Brief ready")).post()
            case .failure(let f):
                if f.kind != "cancelled" { briefFailure = f }
            }
        }
    }

    // MARK: follow up

    private var visibleFollow: [FollowItem] {
        files.follow.filter { item in
            !gone.contains(item.id) && (!checklist.done(session: item.session).contains(item.text) || ticked.contains(item.id))
        }
    }

    @ViewBuilder private var followPlate: some View {
        let items = visibleFollow
        if !items.isEmpty {
            EntityPlate(title: "Follow up", caption: nil) {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(items.prefix(10))) { item in
                        followRow(item).transition(.opacity)
                    }
                    if items.count > 10 {
                        Text("and \(items.count - 10) more in the summaries", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
                    }
                }
                .animation(AskMotion.tint, value: items.map(\.id))
            }
            .accessibilityIdentifier("verse.home.people.followUp")
        }
    }

    private func followRow(_ item: FollowItem) -> some View {
        let on = ticked.contains(item.id)
        return Button { tick(item) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? ink.primary : ink.tertiary, lineWidth: 1.3)
                    if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.primary) }
                }
                .frame(width: 15, height: 15).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.text).font(VT.Font.body).foregroundStyle(on ? ink.secondary : ink.primary)
                        .strikethrough(on, color: ink.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(item.title) · \(PeopleModel.date(item.date))").font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Ticks the item (the same key as the session's detail) and lets it leave the list 1.2 s later.
    private func tick(_ item: FollowItem) {
        guard !ticked.contains(item.id) else { return }
        checklist.set(item.text, done: true, session: item.session)
        withAnimation(AskMotion.tint) { _ = ticked.insert(item.id) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(AskMotion.tint) { _ = gone.insert(item.id) }
        }
    }

    // MARK: meetings

    private struct MonthGroup: Identifiable {
        var id: String
        var title: String
        var sessions: [HomeSession]
    }

    private func months(_ list: [HomeSession]) -> [MonthGroup] {
        var out: [MonthGroup] = []
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = L10n.formatLocale
        f.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        for s in list {
            let c = cal.dateComponents([.year, .month], from: s.date)
            let key = "\(c.year ?? 0)-\(c.month ?? 0)"
            if let i = out.firstIndex(where: { $0.id == key }) { out[i].sessions.append(s) } else {
                let t = f.string(from: s.date)
                out.append(MonthGroup(id: key, title: t.prefix(1).uppercased() + t.dropFirst(), sessions: [s]))
            }
        }
        return out
    }

    @ViewBuilder private func meetingsPlate(_ page: PeopleModel.Page) -> some View {
        if !page.meetings.isEmpty || !page.upcoming.isEmpty {
            EntityPlate(title: "Meetings", caption: nil) {
                VStack(alignment: .leading, spacing: 14) {
                    if !page.upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            groupTitle(Text("Upcoming", bundle: .module))
                            ForEach(page.upcoming) { upcomingRow($0) }
                        }
                    }
                    ForEach(months(page.meetings)) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupTitle(Text(verbatim: group.title))
                            ForEach(group.sessions) { meetingRow($0) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("verse.home.people.meetings")
        }
    }

    private func groupTitle(_ t: Text) -> some View {
        t.font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary).padding(.bottom, 4)
    }

    private static let gutter: CGFloat = 52

    private func timelineRow(date: String, title: String, caption: String, snippet: String?, key: String, action: (() -> Void)?) -> some View {
        let content = HStack(alignment: .top, spacing: 0) {
            Text(verbatim: date).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink.tertiary)
                .frame(width: Self.gutter, alignment: .trailing).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                Text(verbatim: caption).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
                if let snippet {
                    Text(verbatim: snippet).font(.system(size: 12)).foregroundStyle(ink.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, 14).padding(.vertical, 7)
            Spacer(minLength: 0)
        }
        .background(alignment: .leading) {
            // The rule at the gutter's edge runs the length of the group: rows touch, so their rules join.
            Rectangle().fill(ink.separator).frame(width: 1).padding(.leading, Self.gutter)
        }
        .background(hovered == key && action != nil ? ink.fill : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        return Group {
            if let action { Button(action: action) { content }.buttonStyle(.plain) } else { content }
        }
        .onHover { inside in
            withAnimation(AskMotion.tint) { if inside { hovered = key } else if hovered == key { hovered = nil } }
        }
    }

    private func meetingRow(_ s: HomeSession) -> some View {
        let extra = files.extras[s.name]
        let caption = extra?.hadBrief == true ? "\(s.kindText) · \(L10n.tr("Brief"))" : s.kindText
        return timelineRow(date: PeopleModel.date(s.date), title: s.title, caption: caption, snippet: extra?.snippet, key: s.name) {
            router.showSession(s.name, reveal: .none)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: s.title))
        .accessibilityValue(Text(verbatim: "\(PeopleModel.date(s.date)), \(caption)"))
        .accessibilityAddTraits(.isButton)
    }

    private func upcomingRow(_ item: HomeUpNextItem) -> some View {
        let start = item.event?.start
        let day = start.map { PeopleModel.date($0) } ?? ""
        var caption = start.map { PeopleModel.when($0) } ?? ""
        if item.session != nil { caption += " · " + L10n.tr("Prepared") }
        let open = item.session.map { name in { router.showSession(name, reveal: .none) } }
        return timelineRow(date: day, title: item.title, caption: caption, snippet: nil, key: "up-" + item.id, action: open)
    }

    // MARK: suggestions

    @ViewBuilder private func maybeAlso(_ page: PeopleModel.Page) -> some View {
        if !page.suggestions.isEmpty {
            EntityPlate(title: "Maybe also", caption: nil) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(page.suggestions.prefix(6)) { s in
                        HStack(spacing: 10) {
                            Text(verbatim: "\(s.title) · \(PeopleModel.date(s.date))").font(VT.Font.body).foregroundStyle(ink.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            PeopleSmallButton(title: "Add") { store.link(s.name, to: page.entity.id) }
                            PeopleSmallButton(title: "Not this") { store.dismiss(s.name, for: page.entity.id) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("verse.home.people.maybeAlso")
        }
    }

    @ViewBuilder private func samePerson(_ page: PeopleModel.Page) -> some View {
        if let other = page.mergeSuggestion {
            HStack(spacing: 10) {
                Text(page.entity.kind == .person ? "Same person as \(other.name)?" : "Same company as \(other.name)?", bundle: .module)
                    .font(VT.Font.callout).foregroundStyle(ink.secondary)
                Spacer(minLength: 8)
                HomeSecondaryButton("Merge") { pendingMerge = (page.entity, other) }
                PeopleSmallButton(title: "Not this") { store.dismiss(other.id, for: page.entity.id) }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("verse.home.people.samePerson")
        }
    }
}

// MARK: - Pieces

/// A reading plate with a title (and a caption beside it) over its content.
struct EntityPlate<Content: View>: View {
    var title: LocalizedStringKey
    var caption: String?
    @ViewBuilder var content: Content
    @Environment(\.homeInk) private var ink

    var body: some View {
        HomeGroup(plate: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title, bundle: .module).font(VT.Font.title).foregroundStyle(ink.primary).accessibilityAddTraits(.isHeader)
                    if let caption { Text(verbatim: caption).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                content
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Making the brief…": one quiet line that breathes like Ask's Thinking line (1.1 s per half cycle); still under Reduce Motion.
private struct BreathingLine: View {
    var text: LocalizedStringKey
    var animated: Bool
    @Environment(\.homeInk) private var ink
    @State private var dim = false

    var body: some View {
        Text(text, bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary)
            .opacity(animated && dim ? 0.45 : 1)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityElement(children: .combine)
    }
}

/// A small neutral button: "Add", "Not this".
struct PeopleSmallButton: View {
    var title: LocalizedStringKey
    var action: () -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        Button(action: action) {
            Text(title, bundle: .module).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.primary).lineLimit(1).fixedSize()
                .padding(.horizontal, 9).frame(height: 24)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
        }
        .buttonStyle(HomePressStyle())
    }
}

/// Merge Into…: a searchable list of the other entities of the same kind.
struct MergePicker: View {
    var candidates: [MemoryEntity]
    var onPick: (MemoryEntity) -> Void
    @Environment(\.homeInk) private var ink
    @State private var query = ""

    private var shown: [MemoryEntity] {
        let q = TextFold.fold(query).trimmingCharacters(in: .whitespaces)
        return candidates.filter { q.isEmpty || ($0.foldedNames + $0.emails + $0.domains).contains { $0.contains(q) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.tertiary)
                TextField("", text: $query, prompt: Text("Search", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { e in
                        Button { onPick(e) } label: {
                            HStack(spacing: 10) {
                                PeopleMonogram(name: e.name, kind: e.kind, size: 24)
                                Text(verbatim: e.name).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.isEmpty {
                        Text("Nothing to merge into.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.tertiary).padding(8)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12).frame(width: 320)
    }
}

// MARK: - Render state

/// Forced by a render (`--render-home DIR people`): the brief the page shows, so no file in `~/Library` is read. nil in the app.
struct PeopleBriefRenderState: Equatable {
    var brief: BriefFile?
}

private struct PeopleBriefRenderKey: EnvironmentKey {
    static let defaultValue: PeopleBriefRenderState? = nil
}

extension EnvironmentValues {
    var peopleBriefRender: PeopleBriefRenderState? {
        get { self[PeopleBriefRenderKey.self] }
        set { self[PeopleBriefRenderKey.self] = newValue }
    }
}
