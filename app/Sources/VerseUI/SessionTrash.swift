import AppKit
import Foundation
import SwiftUI

// Move to Trash for the Sessions page, the way Mail does it: no confirmation, the Trash is the safety net, and Undo (⌘Z, Edit,
// the toast) brings the session back with its place in a folder, its calendar mapping and its Start choice. A session folder is
// only ever moved with `FileManager.trashItem`; nothing here removes a file.

// MARK: - Types

/// Why a session cannot be moved to the Trash right now.
public enum SessionTrashBlock: Equatable, Sendable {
    /// The call that is being recorded (also while it stops).
    case recording
    /// A practice run that is preparing or running from, or in, this session.
    case practiceRunning
    /// The standing general prep: never a row, never deleted from here.
    case general

    var help: String {
        switch self {
        case .recording: L10n.tr("A session that is being recorded can't be moved to the Trash.")
        case .practiceRunning: L10n.tr("A practice run in progress is using this session.")
        case .general: L10n.tr("This session can't be moved to the Trash.")
        }
    }
}

/// One session that went to the Trash, with what the app kept about it elsewhere (the index, the calendar map).
struct TrashedSession: Equatable, Sendable {
    var name: String
    var original: URL
    /// Where `trashItem` put it; nil when the system did not say (the undo then reports it cannot find it).
    var trashed: URL?
    var folderID: String?
    var dismissed: [String]
    var eventIDs: [String]
}

struct TrashBatch: Equatable, Sendable {
    var items: [TrashedSession]
    /// The session that was the Start choice when it went to the Trash, if any of these was.
    var startWas: String?
    /// What Start fell back to (`refreshSessions`): the undo gives the choice back only if it is still that.
    var startFallback: String?

    var names: [String] { items.map(\.name) }
}

/// The file operations, injected so a test never touches the real Trash.
struct SessionTrashOps: Sendable {
    /// Moves the folder to the Trash and returns where it landed.
    var trash: @Sendable (URL) throws -> URL?
    /// Moves it back (`from` is the Trash location, `to` the original folder).
    var restore: @Sendable (_ from: URL, _ to: URL) throws -> Void

    static let live = SessionTrashOps(
        trash: { url in
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return landed as URL?
        },
        restore: { from, to in try FileManager.default.moveItem(at: from, to: to) })
}

/// What the window supplies: what is running, the Start choice, the selection, a refresh of the other lists.
struct SessionTrashHooks {
    var block: (String) -> SessionTrashBlock? = { _ in nil }
    var startSession: () -> String = { "" }
    var setStartSession: (String) -> Void = { _ in }
    /// Called after sessions left or came back: the menu's list and the Practice meetings read the folder again.
    var sessionsChanged: () -> Void = {}
    var selected: () -> String? = { nil }
    var select: (String?) -> Void = { _ in }
}

extension SessionTrashHooks {
    /// The home window's hooks: the recording call and the practice run block their session, the Start choice is
    /// `settings.sessionName`, the selection is the router's, and a change refreshes the menu's list and Practice's meetings and
    /// syncs Verse's memory (a trashed session leaves the index, an undone one comes back).
    @MainActor
    static func window(controller: VerseController, sim: SimController?, settings: AppSettings, router: HomeRouter,
                       memory: MemoryService? = nil) -> SessionTrashHooks {
        SessionTrashHooks(
            block: { [weak controller, weak sim] name in
                if controller?.recordingSessionName == name { return .recording }
                if let sim, sim.phase == .running || sim.phase == .preparing,
                   sim.sessionDir?.lastPathComponent == name || sim.meetingName == name { return .practiceRunning }
                return nil
            },
            startSession: { settings.sessionName },
            setStartSession: { settings.sessionName = $0 },
            sessionsChanged: { [weak controller, weak sim, weak memory] in
                controller?.refreshSessions()
                sim?.refreshMeetings()
                memory?.requestSync(.sessionsChanged)
            },
            selected: { router.selectedSession },
            select: { router.selectedSession = $0 })
    }
}

struct SessionToast: Equatable, Identifiable {
    var id = UUID()
    var message: String
    /// "Moved to Trash" carries Undo; an error does not.
    var undoable: Bool
    var isError = false
}

/// The outcome of one Move to Trash.
struct TrashOutcome: Equatable {
    var batch: TrashBatch?
    var failed: [String] = []
    var blocked: [String: SessionTrashBlock] = [:]
}

// MARK: - Pure parts

enum SessionTrashRules {
    /// The row to show after `removed` left the list: the next one below, else the one above; `current` itself when it stayed.
    static func nextSelection(order: [String], removed: Set<String>, current: String?) -> String? {
        if let current, !removed.contains(current) { return current }
        let remaining = order.filter { !removed.contains($0) }
        guard let current, let i = order.firstIndex(of: current) else { return remaining.first }
        if let after = order[(i + 1)...].first(where: { !removed.contains($0) }) { return after }
        return order[..<i].last(where: { !removed.contains($0) })
    }

    /// ⌫ and ⌘⌫ (and forward delete) move the selection to the Trash; any other modifier is somebody else's shortcut.
    static func isTrashKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard key == .delete || key == .deleteForward else { return false }
        return modifiers.subtracting([.command, .numericPad]).isEmpty
    }

    /// Keys never act while a text field is being edited (a folder name, search, Ask).
    static func keyActs(on key: KeyEquivalent, modifiers: EventModifiers, editingText: Bool) -> Bool {
        !editingText && isTrashKey(key, modifiers: modifiers)
    }

    enum Swipe: Equatable { case close, reveal, full }

    /// A trailing swipe (`offset` is how far the row moved to the left, as a positive number): past 55 % of the row's width it is
    /// a full swipe and trashes; past 36 pt it stays open on the action; less than that it closes again.
    static func resolveSwipe(offset: CGFloat, rowWidth: CGFloat) -> Swipe {
        if offset >= rowWidth * fullSwipeFraction { return .full }
        if offset >= revealThreshold { return .reveal }
        return .close
    }

    static let actionWidth: CGFloat = 72
    static let revealThreshold: CGFloat = 36
    static let fullSwipeFraction: CGFloat = 0.55
}

// MARK: - The model

extension HomeSessionsModel {
    /// The rows in the order the list shows them (folders mode: section by section, collapsed sections left out).
    var displayOrder: [String] {
        mode == .folders
            ? sections.filter { !isCollapsed($0.id) }.flatMap { $0.sessions.map(\.name) }
            : sessions.map(\.name)
    }

    func blockReason(for name: String) -> SessionTrashBlock? {
        if GeneralPrep.isGeneral(name) { return .general }
        return hooks.block(name)
    }

    /// The sessions a Move to Trash from the toolbar, the keyboard or the Edit menu acts on: the ⌘-click set when it holds
    /// more than one, else the shown session. `clicked` is a context-menu or swipe row: it acts alone unless it is in the set.
    func trashTargets(shown: String?, clicked: String? = nil) -> [String] {
        let picked = sessions.map(\.name).filter(marked.contains)
        if let clicked { return picked.count > 1 && marked.contains(clicked) ? picked : [clicked] }
        if picked.count > 1 { return picked }
        return shown.map { [$0] } ?? []
    }

    /// The part of `names` that exists and is not blocked.
    func deletable(_ names: [String]) -> [String] {
        names.filter { session(named: $0) != nil && blockReason(for: $0) == nil }
    }

    // MARK: trash

    /// Moves the sessions to the Trash. Blocked and unknown names are skipped; a failure leaves that session exactly where it was.
    /// With `undoManager` the matching restore is registered, so ⌘Z and Edit → Undo Move to Trash bring them back.
    @discardableResult
    func trash(_ names: [String], undoManager: UndoManager? = nil) -> TrashOutcome {
        var outcome = TrashOutcome()
        var items: [TrashedSession] = []
        let startBefore = hooks.startSession()
        let shown = session(named: hooks.selected())?.name ?? sessions.first?.name
        let order = displayOrder.contains(where: { $0 == shown }) ? displayOrder : sessions.map(\.name)
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            guard let s = session(named: name) else { continue }
            if let why = blockReason(for: name) { outcome.blocked[name] = why; continue }
            let snapshot = (folder: folders.folder(of: name)?.id, dismissed: folders.file.dismissed[name] ?? [])
            do {
                let landed = try trashOps.trash(s.dir)
                items.append(TrashedSession(name: name, original: s.dir, trashed: landed, folderID: snapshot.folder,
                                            dismissed: snapshot.dismissed, eventIDs: []))
            } catch {
                FileLog.shared.write("sessions: could not move \(name) to the Trash: \(error.localizedDescription)")
                outcome.failed.append(name)
            }
        }
        guard !items.isEmpty else {
            if !outcome.failed.isEmpty { showFailure(trashFailureText(outcome.failed)) }
            return outcome
        }
        for i in items.indices { items[i].eventIDs = eventMap.forget(session: items[i].name) }
        try? folders.forget(items.map(\.name))
        marked.subtract(items.map(\.name))
        let removed = Set(items.map(\.name))
        reload()
        // The Start choice falls back the way a refresh does when its session is gone.
        hooks.sessionsChanged()
        let wasStart = removed.contains(startBefore)
        let batch = TrashBatch(items: items, startWas: wasStart ? startBefore : nil, startFallback: wasStart ? hooks.startSession() : nil)
        outcome.batch = batch
        if let shown, removed.contains(shown) {
            hooks.select(SessionTrashRules.nextSelection(order: order, removed: removed, current: shown))
        }
        if let undoManager { registerRestore(batch, undoManager) }
        if outcome.failed.isEmpty {
            showToast(SessionToast(message: L10n.tr("Moved to Trash"), undoable: true), batch: batch, undoManager: undoManager)
        } else {
            showFailure(trashFailureText(outcome.failed))
        }
        return outcome
    }

    private func trashFailureText(_ failed: [String]) -> String {
        if failed.count == 1 {
            let title = HomeSession.title(forFolder: failed[0])
            return L10n.tr("Verse could not move “\(title)” to the Trash.")
        }
        return L10n.tr("Verse could not move \(failed.count) sessions to the Trash.")
    }

    // MARK: restore

    /// Puts a batch back from the Trash. A session that is no longer in the Trash, or whose name is taken again, is skipped and the
    /// toast says so; nothing crashes. Returns the names that are back.
    @discardableResult
    func restore(_ batch: TrashBatch, undoManager: UndoManager? = nil) -> [String] {
        let fm = FileManager.default
        var back: [String] = []
        var problem: String?
        for item in batch.items {
            let title = HomeSession.title(forFolder: item.name)
            let inTrash = item.trashed.map { fm.fileExists(atPath: $0.path) } ?? false
            if fm.fileExists(atPath: item.original.path) {
                // Already back (a second undo of the same move): nothing to do. A different folder under that name: leave it.
                if inTrash {
                    problem = problem ?? L10n.tr("A session named “\(title)” already exists, so it was not restored.")
                } else {
                    back.append(item.name)
                }
                continue
            }
            guard inTrash, let from = item.trashed else {
                problem = problem ?? L10n.tr("“\(title)” is no longer in the Trash, so it could not be restored.")
                continue
            }
            do {
                try trashOps.restore(from, item.original)
                back.append(item.name)
            } catch {
                FileLog.shared.write("sessions: could not restore \(item.name): \(error.localizedDescription)")
                problem = problem ?? L10n.tr("Verse could not restore “\(title)”.")
            }
        }
        for item in batch.items where back.contains(item.name) {
            try? folders.restoreEntry(item.name, folderID: item.folderID, dismissed: item.dismissed)
            for id in item.eventIDs { eventMap.restore(eventID: id, session: item.name) }
        }
        reload()
        hooks.sessionsChanged()
        if let was = batch.startWas, back.contains(was), hooks.startSession() == (batch.startFallback ?? ""), hooks.startSession() != was {
            hooks.setStartSession(was)
        }
        if let first = back.first { hooks.select(first) }
        if let undoManager, !back.isEmpty {
            // The inverse of an undo is the redo: Move to Trash again.
            registerTrash(back, undoManager)
        }
        if let problem {
            showFailure(problem)
        } else {
            dismissToast()
        }
        return back
    }

    // MARK: undo registration

    private func registerRestore(_ batch: TrashBatch, _ um: UndoManager) {
        withUndoGroup(um) {
            um.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.restore(batch, undoManager: um) }
            }
            um.setActionName(L10n.tr("Move to Trash"))
        }
    }

    private func registerTrash(_ names: [String], _ um: UndoManager) {
        withUndoGroup(um) {
            um.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.trash(names, undoManager: um) }
            }
            um.setActionName(L10n.tr("Move to Trash"))
        }
    }

    /// Registering needs an open group; the app's run loop opens one per event, a bare manager (a test) does not.
    private func withUndoGroup(_ um: UndoManager, _ body: () -> Void) {
        let open = um.groupingLevel == 0
        if open { um.beginUndoGrouping() }
        body()
        if open { um.endUndoGrouping() }
    }

    // MARK: toast

    func showToast(_ t: SessionToast, batch: TrashBatch?, undoManager: UndoManager?) {
        toast = t
        toastBatch = batch
        toastUndoManager = undoManager
        scheduleToastDismissal(t.id)
    }

    func showFailure(_ message: String) {
        showToast(SessionToast(message: message, undoable: false, isError: true), batch: nil, undoManager: nil)
    }

    private func scheduleToastDismissal(_ id: UUID) {
        toastTask?.cancel()
        let wait = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.dismissToast(ifShowing: id)
        }
    }

    func dismissToast(ifShowing id: UUID? = nil) {
        if let id, toast?.id != id { return }
        toastTask?.cancel()
        toastTask = nil
        toast = nil
        toastBatch = nil
        toastUndoManager = nil
    }

    /// The toast's Undo is ⌘Z: it asks the window's undo manager when that manager's next undo is this Move to Trash, and restores
    /// directly otherwise.
    func undoFromToast() {
        guard let batch = toastBatch else { return }
        if let um = toastUndoManager, um.canUndo, um.undoActionName == L10n.tr("Move to Trash") {
            um.undo()
        } else {
            toastUndoManager?.removeAllActions(withTarget: self)
            restore(batch)
        }
    }
}

// MARK: - Controls

/// The Trash button of the detail header and the More menu item: whether it works, why not, and what it does.
struct SessionTrashControl {
    var enabled = false
    /// The tooltip: "Move to Trash", or the reason it is off.
    var help: String = L10n.tr("Move to Trash")
    var action: () -> Void = {}
}

/// A neutral 28 pt icon button like the More menu next to it (the window's one icon-button chrome).
struct SessionTrashButton: View {
    var control: SessionTrashControl
    @Environment(\.homeInk) private var ink

    var body: some View {
        Button(action: control.action) {
            Image(systemName: "trash").font(.system(size: 14, weight: .regular)).foregroundStyle(ink.primary)
                .frame(width: 28, height: 28)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
                .opacity(control.enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .disabled(!control.enabled)
        .help(Text(verbatim: control.help))
        .accessibilityLabel(Text("Move to Trash", bundle: .module))
        .accessibilityIdentifier("verse.home.sessions.trash")
    }
}

/// The bar at the bottom of the Sessions page: "Moved to Trash · Undo", or a short error.
struct SessionToastView: View {
    var toast: SessionToast
    var onUndo: () -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous)
        HStack(spacing: 10) {
            Text(verbatim: toast.message).font(VT.Font.callout).foregroundStyle(toast.isError ? VT.coral : ink.primary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if toast.undoable {
                Text(verbatim: "·").font(VT.Font.callout).foregroundStyle(ink.tertiary).accessibilityHidden(true)
                Button(action: onUndo) {
                    Text("Undo", bundle: .module).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.mintText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HomePressStyle())
                .accessibilityIdentifier("verse.home.sessions.undoTrash")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(ink.separator))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.home.sessions.toast")
    }
}

// MARK: - Render state

/// Forced by a render (`--render-home`): a row with its Trash action revealed, and the toast. nil in the app.
struct SessionsTrashRenderState: Equatable, Sendable {
    var swiped: String?
    var toast = false
}

struct SessionsTrashRenderKey: EnvironmentKey {
    static var defaultValue: SessionsTrashRenderState? { nil }
}

extension EnvironmentValues {
    var sessionsTrashRender: SessionsTrashRenderState? {
        get { self[SessionsTrashRenderKey.self] }
        set { self[SessionsTrashRenderKey.self] = newValue }
    }
}
