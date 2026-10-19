import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerseTurns

/// The home window's Me page (anytime-calls spec 2.2, "UI"): what Verse knows about him in every call. The sections of
/// `me.md` as grouped rows with inline edit and delete, the sources, how and when it was built, Refresh, and where the
/// profile and the last meeting pack disagreed. Tokens and patterns are the redesign's (grouped rows on the window glass,
/// one primary action, no accent anywhere else).
struct MePage: View {
    @ObservedObject var model: MeModel
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    @Environment(\.homeInk) private var ink

    @State private var noteDraft = ""
    @State private var sourceNoteOpen = false
    @State private var editing: String?
    @State private var draft = ""
    @State private var pendingDelete: MeLine?
    @State private var editError: String?

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
                HomeRow("General prep", verbatimDetail: GeneralPrep.status(root: controller.sessionsRoot)?.text() ?? "Not built yet") { EmptyView() }
            }

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
                if let editError { HomeNote(verbatim: editError, isError: true).padding(.top, 8) }
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
        .confirmationDialog("Delete this line?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { line in
            Button("Delete", role: .destructive) { apply(model.delete(id: line.id)) }
        } message: { line in
            Text("“\(line.text)” is removed from your profile. Refresh will not bring it back.")
        }
        .accessibilityIdentifier("verse.home.me")
    }

    // MARK: status

    @ViewBuilder private var runStatus: some View {
        switch model.phase {
        case .running(let action):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.progress ?? (action == .build ? "Building your profile…" : "Refreshing your profile…"))
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
            HomeRow(label: HomeText(verbatim: model.meta?.summary ?? "Built"),
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
            var s = MeMeta.tokenText(info.tokens) + " tokens"
            if let d = Self.builtDate(info.builtAt) { s += " · built " + d.formatted(Date.FormatStyle().locale(HomeFormat.locale).day().month(.abbreviated)) }
            return s
        }
        if controller.meLayerMissing { return "Not found" }
        return controller.running ? "Not used" : "No session yet"
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
                    HomeRow(verbatim: c.topic.isEmpty ? "A number differs" : c.topic,
                            detail: "Your profile\(model.line(id: c.me).map { " says “" + $0.text + "”" } ?? "") (\(c.me)); the meeting pack (\(c.pack)) gives a different number. The pack wins in the call.") {
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
                        .accessibilityLabel("Edit line \(line.id)")
                    if line.section.fieldCount > 1 {
                        Text("\(line.section.fieldCount) parts, separated by “|”").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                    }
                } else {
                    Text(line.text).font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption(line)).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isEditing {
                HomeSecondaryButton("Cancel") { editing = nil }
                HomeSecondaryButton("Save") { commitEdit(line) }
            } else if model.canEdit {
                iconButton("pencil", label: "Edit line \(line.id)") {
                    draft = line.editable
                    editing = line.id
                    editError = nil
                }
                iconButton("trash", label: "Delete line \(line.id)") { pendingDelete = line }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 40)
        .accessibilityElement(children: isEditing ? .contain : .combine)
    }

    private func caption(_ line: MeLine) -> String {
        [line.hasID ? line.id : nil, line.source.isEmpty ? nil : line.source].compactMap { $0 }.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.tertiary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private func commitEdit(_ line: MeLine) {
        switch model.edit(id: line.id, to: draft) {
        case .success: editing = nil; editError = nil
        case .failure(let e): editError = e.description
        }
    }

    private func apply(_ result: Result<Void, MeModel.EditError>) {
        if case .failure(let e) = result { editError = e.description } else { editError = nil }
    }

    private func addNote() {
        switch model.addNote(noteDraft) {
        case .success: noteDraft = ""; editError = nil
        case .failure(let e): editError = e.description
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
                        if source.kind == "file" { Button("Remove source", role: .destructive) { apply(model.removeSource(source.id)) } }
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
                        HomeValueField("Something Verse should know about you", text: $noteDraft, onSubmit: addSourceNote)
                        HomeSecondaryButton("Add", action: addSourceNote)
                            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        if s.changed { parts.append("changed since the build") }
        return parts.joined(separator: " · ")
    }

    private func addSourceNote() {
        addNote()
        if editError == nil { sourceNoteOpen = false }
    }

    private func addFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]
        p.allowsMultipleSelection = false
        p.prompt = "Add"
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
