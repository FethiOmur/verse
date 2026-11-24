import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerseAudio
import VerseTurns

/// The home window's Me page (anytime-calls spec 2.2, "UI"): what Verse knows about him in every call. The sections of
/// `me.md` as grouped rows with inline edit and delete, the sources, how and when it was built, Refresh, and where the
/// profile and the last meeting pack disagreed. Tokens and patterns are the redesign's (grouped rows on the window glass,
/// one primary action, no accent anywhere else).
struct MePage: View {
    @ObservedObject var model: MeModel
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    /// The master persona's row (last update, open contradictions). nil in tests and renders that build the page without one.
    var persona: PersonaService?
    @Environment(\.homeInk) private var ink

    /// Each add-a-note field has its own text: the notes row and the sources row are on screen together.
    @State private var noteDraft = ""
    @State private var sourceNoteDraft = ""
    @State private var sourceNoteOpen = false
    @State private var editing: String?
    @State private var draft = ""
    @State private var pendingDelete: MeLine?
    @State private var editError: String?
    @FocusState private var editFocused: Bool

    var body: some View {
        HomeColumnPage {
            HomePageHeader("Me", subtitle: "What Verse knows about you in every call.") {
                if model.isRunning {
                    HomeSecondaryButton("Cancel") { model.cancel() }
                } else {
                    HomePrimaryButton(model.hasProfile ? "Refresh" : "Build profile") { Task { await model.refresh() } }
                }
            }

            runStatus

            HomeSectionHeader("General prep")
            HomeGroup {
                HomeRow("General prep", verbatimDetail: generalPrepText) { EmptyView() }
            }

            if let persona { PersonaMeSection(persona: persona, controller: controller) }

            if model.showSourcesChanged {
                HomeGroup {
                    HomeRow("Sources changed", verbatimDetail: model.staleSources.joined(separator: ", ")) {
                        HomeSecondaryButton("Refresh") { Task { await model.refresh() } }
                    }
                }
                .padding(.top, 16)
            }

            if model.hasProfile {
                HomeSectionHeader("Profile")
                profileGroup
                if !controller.meConflicts.isEmpty {
                    HomeSectionHeader("Conflicts")
                    conflictsGroup
                }
                // A line being edited shows its own error under its field (it may be far down the page).
                if let editError, editing == nil { HomeNote(verbatim: editError, isError: true).padding(.top, 8) }
                ForEach(MeSection.allCases, id: \.self) { section in
                    let lines = model.lines(section)
                    if !lines.isEmpty || section == .notes {
                        HomeSectionHeader(verbatim: section.title)
                        sectionGroup(section, lines)
                    }
                }
                HomeSectionHeader("Sources")
                sourcesGroup
            } else {
                emptyState
            }
        }
        .onAppear {
            model.reload()
            Task { await model.checkSources() }
        }
        .confirmationDialog(Text("Delete this line?", bundle: .module), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { line in
            Button(role: .destructive) { apply(model.delete(id: line.id)) } label: { Text("Delete", bundle: .module) }
        } message: { line in
            Text("“\(line.text)” is removed from your profile. Refresh will not bring it back.", bundle: .module)
        }
        .accessibilityIdentifier("verse.home.me")
    }

    /// What unprepared calls start with now: the compiled persona once it exists, else the general prep (owner decision 4).
    private var generalPrepText: String {
        guard let current = GeneralPrep.status(root: controller.sessionsRoot, personaOn: OwnerProfile.current.personaURL != nil) else {
            return L10n.tr("Not built yet")
        }
        let from = current.source == .persona ? L10n.tr("From your persona") : L10n.tr("From the general prep")
        return from + " · " + current.status.text()
    }

    // MARK: status

    @ViewBuilder private var runStatus: some View {
        switch model.phase {
        case .running(let action):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: model.progress ?? (action == .build ? L10n.tr("Building your profile…") : L10n.tr("Refreshing your profile…")))
                    .font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
            }
            .padding(.top, 14)
        case .failed(let m):
            HomeNote(verbatim: m, isError: true).padding(.top, 14)
        case .idle:
            if let m = model.message { HomeNote(verbatim: m).padding(.top, 14) }
        }
    }

    // MARK: profile

    private var profileGroup: some View {
        HomeGroup {
            HomeRow(label: HomeText(verbatim: model.meta?.summary ?? L10n.tr("Built")),
                    detail: HomeText("Calls read it when they start, so an edit applies from the next session. The cap is 3,500 tokens.")) { EmptyView() }
            HomeRowDivider()
            HomeRow(controller.running ? "In this session" : "In the last session") {
                Text(sessionLayerText).font(VT.Font.body).foregroundStyle(ink.secondary)
            }
            if !settings.useMeProfile {
                HomeRowDivider()
                HomeRow("Off in Settings", detail: "Settings › Meetings › Use my profile in every session") { EmptyView() }
            }
        }
    }

    /// `ready.me` of the brain's status: how big the layer was in the running (or last) session.
    private var sessionLayerText: String {
        if let info = controller.meLayer {
            var s = L10n.tr("\(MeMeta.tokenText(info.tokens)) tokens")
            if let d = Self.builtDate(info.builtAt) { s += " · " + L10n.tr("built \(d.formatted(Date.FormatStyle().locale(HomeFormat.locale).day().month(.abbreviated)))") }
            return s
        }
        if controller.meLayerMissing { return L10n.tr("Not found") }
        return controller.running ? L10n.tr("Not used") : L10n.tr("No session yet")
    }

    /// "Your profile says “…” (L12); the meeting pack (F3) gives a different number. The pack wins in the call."
    private func conflictDetail(_ c: MeConflict) -> String {
        if let line = model.line(id: c.me) {
            return L10n.tr("Your profile says “\(line.text)” (\(c.me)); the meeting pack (\(c.pack)) gives a different number. The pack wins in the call.")
        }
        return L10n.tr("Your profile (\(c.me)); the meeting pack (\(c.pack)) gives a different number. The pack wins in the call.")
    }

    static func builtDate(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    private var conflictsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeGroup {
                ForEach(Array(controller.meConflicts.enumerated()), id: \.offset) { i, c in
                    if i > 0 { HomeRowDivider() }
                    HomeRow(verbatim: c.topic.isEmpty ? L10n.tr("A number differs") : c.topic,
                            detail: conflictDetail(c)) {
                        EmptyView()
                    }
                }
            }
            HomeFootnote("From the last session. Nothing is rewritten on its own: fix the line here if the pack is the one that is wrong.")
        }
    }

    // MARK: sections

    private func sectionGroup(_ section: MeSection, _ lines: [MeLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeGroup {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    if i > 0 { HomeRowDivider() }
                    lineRow(line)
                }
                if section == .notes {
                    if !lines.isEmpty { HomeRowDivider() }
                    HomeRow("Add a note") {
                        HomeValueField("Something Verse should know about you", text: $noteDraft, onSubmit: addNote)
                        HomeSecondaryButton("Add", action: addNote)
                            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                    }
                }
            }
            if section == .notes, lines.isEmpty {
                HomeFootnote("Notes are yours: a refresh never rewrites them.")
            }
        }
    }

    private func lineRow(_ line: MeLine) -> some View {
        let isEditing = editing == line.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary).lineLimit(1...8)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                        .onSubmit { commitEdit(line) }
                        .focused($editFocused)
                        .onAppear { DispatchQueue.main.async { editFocused = true } }
                        .accessibilityLabel(Text("Edit line \(line.id)", bundle: .module))
                    if line.section.fieldCount > 1 {
                        Text("\(line.section.fieldCount) parts, separated by “|”", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
                    }
                    if let editError { HomeNote(verbatim: editError, isError: true) }
                } else {
                    Text(line.text).font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption(line)).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isEditing {
                HomeSecondaryButton("Cancel") { editing = nil; editError = nil }
                HomeSecondaryButton("Save") { commitEdit(line) }
            } else if model.canEdit {
                iconButton("pencil", label: "Edit line \(line.id)") { beginEdit(line) }
                iconButton("trash", label: "Delete line \(line.id)") { pendingDelete = line }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 40)
        .accessibilityElement(children: isEditing ? .contain : .combine)
    }

    private func caption(_ line: MeLine) -> String {
        [line.hasID ? line.id : nil, line.source.isEmpty ? nil : line.source].compactMap { $0 }.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.tertiary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(Text(label, bundle: .module))
        .help(Text(label, bundle: .module))
    }

    /// Saves the draft of `line`. False when the save failed: the draft stays and the error shows under its field.
    @discardableResult
    private func commitEdit(_ line: MeLine) -> Bool {
        switch model.edit(id: line.id, to: draft) {
        case .success: editing = nil; editError = nil; return true
        case .failure(let e): editError = e.description; return false
        }
    }

    /// Starts editing `line`. A draft already open on another line is saved first (as Save would); when that fails the
    /// draft stays where it is, with the error under its field, and the other line does not open.
    private func beginEdit(_ line: MeLine) {
        if let open = editing, open != line.id, let current = model.line(id: open), draft != current.editable {
            guard commitEdit(current) else { return }
        }
        draft = line.editable
        editing = line.id
        editError = nil
    }

    private func apply(_ result: Result<Void, MeModel.EditError>) {
        if case .failure(let e) = result { editError = e.description } else { editError = nil }
    }

    private func addNote() {
        if submitNote(noteDraft) { noteDraft = "" }
    }

    /// Adds `text` as a note; false (with the error shown) when it was refused.
    private func submitNote(_ text: String) -> Bool {
        switch model.addNote(text) {
        case .success: editError = nil; return true
        case .failure(let e): editError = e.description; return false
        }
    }

    // MARK: sources

    private var sourcesGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeGroup {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { i, source in
                    if i > 0 { HomeRowDivider() }
                    HomeRow(verbatim: source.label, detail: sourceDetail(source)) {
                        HomeSwitch(isOn: Binding(get: { source.enabled }, set: { apply(model.setSource(source.id, enabled: $0)) }))
                            .disabled(model.isRunning)
                    }
                    .contextMenu {
                        if source.kind == "file" { Button(role: .destructive) { apply(model.removeSource(source.id)) } label: { Text("Remove source", bundle: .module) } }
                    }
                }
                if !model.sources.isEmpty { HomeRowDivider() }
                HomeRow("Add to your profile") {
                    HomeSecondaryButton("Add file…", action: addFile).disabled(!model.hasSourcesFile || model.isRunning)
                    HomeSecondaryButton("Add note…") { sourceNoteOpen.toggle() }.disabled(!model.canEdit)
                }
                if sourceNoteOpen {
                    HomeRowDivider()
                    HomeRow("Note") {
                        HomeValueField("Something Verse should know about you", text: $sourceNoteDraft, onSubmit: addSourceNote)
                        HomeSecondaryButton("Add", action: addSourceNote)
                            .disabled(sourceNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                    }
                }
            }
            HomeFootnote(model.hasSourcesFile
                         ? "Refresh reads the sources that are on and keeps every line you edited, added or deleted. .md, .txt and .pdf files work."
                         : "The default sources are chosen at the first build; then you can switch them or add your own.")
        }
    }

    private func sourceDetail(_ s: MeSource) -> String {
        var parts = [s.kindText]
        if s.kind != "sessions" { parts.append((s.path as NSString).abbreviatingWithTildeInPath) }
        if s.changed { parts.append(L10n.tr("changed since the build")) }
        return parts.joined(separator: " · ")
    }

    private func addSourceNote() {
        if submitNote(sourceNoteDraft) {
            sourceNoteDraft = ""
            sourceNoteOpen = false
        }
    }

    private func addFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]
        p.allowsMultipleSelection = false
        p.prompt = L10n.tr("Add")
        if p.runModal() == .OK, let u = p.url { apply(model.addSource(file: u)) }
    }

    // MARK: empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader("Profile")
            HomeGroup {
                HomeRow("No profile yet",
                        detail: "Verse reads your CV, project notes and earlier meeting facts once and keeps a short profile of you: about 3,500 tokens, roughly $0.07. Calls use it even when nothing is prepared.") {
                    EmptyView()
                }
            }
            HomeFootnote("Build reads the sources it finds on this Mac (your profile file, project notes, earlier meeting facts) and shows you what it kept. Nothing is read from the rest of the vault.")
        }
    }
}

// MARK: - Persona

/// The Me page's persona rows: the last update after a call, and the contradictions between things he said, each with both
/// quotes and a way to keep one. The other claim stays in the note as history; nothing is deleted.
struct PersonaMeSection: View {
    @ObservedObject var persona: PersonaService
    @ObservedObject var controller: VerseController

    private var folder: URL? { OwnerProfile.current.personaURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader("Persona")
            HomeGroup {
                HomeRow("Learned from your calls", verbatimDetail: lastText) {
                    if persona.active != nil || persona.resolving != nil { ProgressView().controlSize(.small) }
                    if let folder {
                        HomeSecondaryButton("Open folder") { NSWorkspace.shared.open(folder) }
                            .disabled(!FileManager.default.fileExists(atPath: folder.path))
                    }
                }
                ForEach(persona.open) { c in
                    HomeRowDivider()
                    HomeRow(verbatim: c.topic.isEmpty ? L10n.tr("Two different answers") : c.topic, detail: detail(c)) {
                        HomeSecondaryButton("Keep first") { persona.resolve(c.id, keep: 1) }
                        HomeSecondaryButton("Keep second") { persona.resolve(c.id, keep: 2) }
                    }
                    .disabled(persona.resolving != nil || persona.active != nil || controller.running || controller.stopping)
                }
            }
            if let kind = persona.resolveError {
                HomeNote(verbatim: L10n.tr("Could not settle it: \(PersonaRunRecord.reason(kind))"), isError: true).padding(.top, 8)
            }
            HomeFootnote(persona.open.isEmpty
                         ? "After each call Verse keeps what you said in your own words, with the quote and the minute. Edit or delete any line in the note; Verse keeps your changes."
                         : "Until you keep one, neither answer reaches a call. The other stays in the note as history.")
        }
        .onAppear { persona.refreshStatus() }
    }

    private var lastText: String {
        if folder == nil { return L10n.tr("Off until a persona folder is set in the owner profile.") }
        if let name = persona.active { return L10n.tr("Learning from \(title(name))…") }
        if let last = persona.last { return last.text(title: title(last.session)) }
        return L10n.tr("Nothing learned yet")
    }

    private func title(_ session: String) -> String { HomeSession.load(name: session, root: controller.sessionsRoot).title }

    /// "1 · “quote” (date, ref)" and "2 · …" on two lines.
    private func detail(_ c: PersonaContradiction) -> String {
        func line(_ n: Int, _ s: PersonaSide) -> String {
            let place = [s.date, s.ref].filter { !$0.isEmpty }.joined(separator: ", ")
            return "\(n) · “\(s.quote.isEmpty ? s.text : s.quote)”" + (place.isEmpty ? "" : " (\(place))")
        }
        return line(1, c.first) + "\n" + line(2, c.second)
    }
}
