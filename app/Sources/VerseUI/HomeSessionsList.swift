import AppKit
import SwiftUI

/// The Sessions page's list column (236 pt). Sessions group by folder (company or person) or sit in one flat list, newest
/// first. A folder is an index (`SessionFolders.swift`): moving a row here never moves a session on disk.
struct HomeSessionsList: View {
    @ObservedObject var model: HomeSessionsModel
    @ObservedObject var router: HomeRouter
    /// The session shown in the detail (the router's choice, or the first one).
    var selectedName: String?
    @Environment(\.homeInk) private var ink

    /// The text field of a new folder (and the session it will hold) or of a rename.
    private struct Draft: Equatable {
        var text = ""
        var error: String?
        var session: String?
    }

    private enum Field: Hashable { case create, rename }

    @State private var hovered: String?
    @State private var creating: Draft?
    @State private var renamingID: String?
    @State private var renameDraft = Draft()
    @State private var pendingDelete: SessionFolder?
    @State private var dropTarget: String?
    @FocusState private var focus: Field?

    private static let indent: CGFloat = 8
    private static let modeItems: [(label: LocalizedStringKey, value: SessionsListMode)] = [("Folders", .folders), ("Recent", .recent)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .padding(.bottom, showsModePicker ? 8 : 14)
            if showsModePicker {
                HomeSegmented(Self.modeItems,
                              selection: Binding(get: { model.mode }, set: { model.setMode($0) }))
                    .padding(.bottom, 12)
            }
            if let notice = model.folders.notice {
                HomeNote(verbatim: notice).padding(.horizontal, 10).padding(.bottom, 8)
                    .onTapGesture { model.folders.dismissNotice() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if creating != nil { newFolderRow }
                    content
                    if model.sessions.isEmpty {
                        Text("No sessions yet. Prepare one for your next meeting.", bundle: .module)
                            .font(VT.Font.callout).foregroundStyle(ink.tertiary)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: 236).padding(.leading, 18).padding(.top, 22)
        .onChange(of: focus) { old, new in
            // Clicking away from an empty field cancels it, like Esc.
            if old == .create, new != .create, creating?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { creating = nil }
            if old == .rename, new != .rename { renamingID = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { f in
            Button(role: .destructive) { model.deleteFolder(f.id) } label: { Text("Delete Folder", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: { f in
            deleteMessage(count: model.sessionCount(in: f.id))
        }
    }

    private var showsModePicker: Bool { !model.folders.folders.isEmpty }

    // MARK: title

    private var titleRow: some View {
        HStack(spacing: 0) {
            Text("Sessions", bundle: .module).font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                .padding(.leading, 10)
            Spacer(minLength: 8)
            Button { startNewFolder(session: nil, text: "") } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 12.5, weight: .medium)).foregroundStyle(ink.secondary)
                    .frame(width: 24, height: 24)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HomePressStyle())
            .help(Text("New folder", bundle: .module))
            .accessibilityLabel(Text("New folder", bundle: .module))
            .accessibilityIdentifier("verse.home.sessions.newFolder")
        }
    }

    private var deleteTitle: Text {
        Text("Delete the folder “\(pendingDelete?.name ?? "")”?", bundle: .module)
    }

    private func deleteMessage(count: Int) -> Text {
        switch count {
        case 0: Text("It has no sessions. No session is deleted.", bundle: .module)
        case 1: Text("Its session stays in Sessions, under No folder. No session is deleted.", bundle: .module)
        default: Text("Its \(count) sessions stay in Sessions, under No folder. No session is deleted.", bundle: .module)
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if model.mode == .folders {
            ForEach(model.sections) { section in sectionView(section, first: section.id == model.sections.first?.id) }
        } else {
            ForEach(model.sessions) { s in row(s, indent: 0, showsFolder: true) }
        }
    }

    @ViewBuilder private func sectionView(_ section: HomeSessionSection, first: Bool) -> some View {
        header(section).padding(.top, first ? 0 : 6)
        if !model.isCollapsed(section.id) {
            ForEach(section.sessions) { s in row(s, indent: Self.indent, showsFolder: false) }
            if section.sessions.isEmpty, section.folder != nil {
                Text("Drop a session here.", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.tertiary)
                    .padding(.leading, 10 + Self.indent).frame(height: 28, alignment: .leading)
            }
        }
    }

    // MARK: section header

    @ViewBuilder private func header(_ section: HomeSessionSection) -> some View {
        if let folder = section.folder, renamingID == folder.id {
            renameField(folder)
        } else {
            let closed = model.isCollapsed(section.id)
            Button { withAnimation(.easeOut(duration: 0.14)) { model.toggleCollapsed(section.id) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.tertiary)
                        .rotationEffect(.degrees(closed ? 0 : 90)).frame(width: 10)
                    if let folder = section.folder {
                        Text(verbatim: folder.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary).lineLimit(1)
                    } else {
                        Text("No folder", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: "\(section.sessions.count)").font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.tertiary)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(dropTarget == section.id ? ink.selection : .clear,
                            in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(closed ? Text("Collapsed", bundle: .module) : Text("Expanded", bundle: .module))
            .contextMenu {
                if let folder = section.folder {
                    Button { startRename(folder) } label: { Text("Rename…", bundle: .module) }
                    Button { pendingDelete = folder } label: { Text("Delete folder…", bundle: .module) }
                }
            }
            .dropDestination(for: String.self) { names, _ in
                guard let name = names.first, model.session(named: name) != nil else { return false }
                model.move(name, to: section.folder?.id)
                return true
            } isTargeted: { on in
                if on { dropTarget = section.id } else if dropTarget == section.id { dropTarget = nil }
            }
        }
    }

    // MARK: rows

    private func row(_ s: HomeSession, indent: CGFloat, showsFolder: Bool) -> some View {
        let folder = model.folder(of: s)
        let suggestion = model.suggestion(for: s)
        let chipShown = suggestion != nil && (hovered == s.name || s.name == selectedName)
        return ZStack(alignment: .bottomTrailing) {
            Button { router.selectedSession = s.name } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: s.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(HomeFormat.day(s.date)) · \(s.kindText)").font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(1)
                        if showsFolder, let folder {
                            Text(verbatim: "· \(folder.name)").font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
                        }
                        if s.unprepared { UnpreparedTag() }
                    }
                    .padding(.trailing, chipShown ? 90 : 0)
                }
                .padding(.leading, 10 + indent).padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(s.name == selectedName ? ink.selection : .clear,
                            in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .draggable(s.name)
            if chipShown, let suggestion {
                chip(suggestion, session: s.name, selected: s.name == selectedName).padding(.trailing, 8).padding(.bottom, 6)
            }
        }
        .onHover { inside in
            if inside { hovered = s.name } else if hovered == s.name { hovered = nil }
        }
        .contextMenu { rowMenu(s, folder: folder, suggestion: suggestion) }
    }

    /// "→ Acme" files the session in a folder that exists, "+ Acme" makes the folder first.
    private func chip(_ suggestion: FolderSuggestion, session: String, selected: Bool) -> some View {
        let mark = if case .new = suggestion { "+" } else { "→" }
        return Button { model.accept(suggestion, for: session) } label: {
            Text(verbatim: "\(mark) \(suggestion.name)").font(VT.Font.caption).foregroundStyle(ink.secondary).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 18)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                // On the selected row the 7.5 % selection fill sits under the chip: lift it by one more fill.
                .background(selected ? ink.fill : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                .frame(maxWidth: 84, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .help(Text(verbatim: suggestion.name))
        .accessibilityIdentifier("verse.home.sessions.suggestion")
    }

    @ViewBuilder private func rowMenu(_ s: HomeSession, folder: SessionFolder?, suggestion: FolderSuggestion?) -> some View {
        let all = model.folders.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !all.isEmpty {
            Menu {
                ForEach(all) { f in
                    Toggle(isOn: Binding(get: { folder?.id == f.id }, set: { _ in model.move(s.name, to: f.id) })) { Text(verbatim: f.name) }
                }
            } label: { Text("Move to", bundle: .module) }
        }
        Button {
            var prefill = ""
            if case .new(let n)? = suggestion { prefill = n } else if let c = FolderSuggester.cleanCompany(s.folderSignals.conversationCompany ?? s.folderSignals.simCompany) { prefill = c }
            startNewFolder(session: s.name, text: prefill)
        } label: { Text("New Folder from This Session…", bundle: .module) }
        if folder != nil {
            Button { model.move(s.name, to: nil) } label: { Text("Remove from Folder", bundle: .module) }
        }
        if let suggestion {
            Divider()
            Button { model.dismiss(suggestion, for: s.name) } label: { Text("Not this folder", bundle: .module) }
        }
    }

    // MARK: inline fields

    private var newFolderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(ink.tertiary)
                TextField("", text: Binding(get: { creating?.text ?? "" }, set: { creating?.text = $0; creating?.error = nil }),
                          prompt: Text("Folder name", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary)
                    .focused($focus, equals: .create)
                    .onSubmit { commitCreate() }
                    .onExitCommand { creating = nil }
                    .accessibilityIdentifier("verse.home.sessions.newFolderField")
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            if let error = creating?.error { HomeNote(verbatim: error, isError: true).padding(.horizontal, 10) }
        }
        .padding(.bottom, 6)
        .onAppear { DispatchQueue.main.async { focus = .create } }
    }

    private func renameField(_ folder: SessionFolder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.tertiary)
                    .rotationEffect(.degrees(model.isCollapsed(folder.id) ? 0 : 90)).frame(width: 10)
                TextField("", text: Binding(get: { renameDraft.text }, set: { renameDraft.text = $0; renameDraft.error = nil }),
                          prompt: Text("Folder name", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.primary)
                    .focused($focus, equals: .rename)
                    .onSubmit { commitRename(folder) }
                    .onExitCommand { renamingID = nil }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            if let error = renameDraft.error { HomeNote(verbatim: error, isError: true).padding(.horizontal, 10) }
        }
        .onAppear { DispatchQueue.main.async { focus = .rename } }
    }

    private func startNewFolder(session: String?, text: String) {
        renamingID = nil
        creating = Draft(text: text, session: session)
        focus = .create
    }

    private func startRename(_ folder: SessionFolder) {
        creating = nil
        renameDraft = Draft(text: folder.name)
        renamingID = folder.id
    }

    /// ⏎: creates, or cancels when the field is empty.
    private func commitCreate() {
        guard let draft = creating else { return }
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { creating = nil; return }
        if let error = model.createFolder(named: draft.text, filing: draft.session) {
            creating?.error = error.message
        } else {
            creating = nil
        }
    }

    private func commitRename(_ folder: SessionFolder) {
        if renameDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { renamingID = nil; return }
        if let error = model.renameFolder(folder.id, to: renameDraft.text) {
            renameDraft.error = error.message
        } else {
            renamingID = nil
        }
    }
}

/// "Unprepared": a call that started without a prepared session. A neutral fill, like every tag on the window glass.
struct UnpreparedTag: View {
    @Environment(\.homeInk) private var ink
    var body: some View {
        Text("Unprepared", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.secondary)
            .padding(.horizontal, 6).frame(height: 16)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            .fixedSize()
    }
}
