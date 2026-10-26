import AppKit
import Combine
import SwiftUI
import VerseMeet

/// The objects the home window's pages work with. The app builds one at launch; renders and tests build their own.
@MainActor
public struct HomeContext {
    public let settings: AppSettings
    public let controller: VerseController
    public let simSettings: SimSettings
    public let sim: SimController
    public let conversation: ConversationController
    public let sessions: HomeSessionsModel
    public let upNext: HomeUpNextModel
    /// The Me page's profile (anytime calls).
    public let me: MeModel
    public let router: HomeRouter
    /// Verse's memory: the index of past sessions and the brief runner. It starts nothing in tests and renders (see `init`).
    let memory: MemoryService
    /// The people and companies of the owner's meetings (`memory/people.json`). A test or render process gets an empty store in a
    /// scratch folder; it never reads the owner's own file.
    let people: EntityStore
    private var peopleSubscriptions: [AnyCancellable] = []

    public init(settings: AppSettings, controller: VerseController, simSettings: SimSettings, sim: SimController,
                conversation: ConversationController, sessions: HomeSessionsModel? = nil, upNext: HomeUpNextModel? = nil,
                me: MeModel? = nil, router: HomeRouter = .shared) {
        self.init(settings: settings, controller: controller, simSettings: simSettings, sim: sim, conversation: conversation,
                  sessions: sessions, upNext: upNext, me: me, router: router, memory: nil)
    }

    /// `memory` nil builds the app's own service (live paths, the real brain), enabled only inside the app.
    init(settings: AppSettings, controller: VerseController, simSettings: SimSettings, sim: SimController,
         conversation: ConversationController, sessions: HomeSessionsModel?, upNext: HomeUpNextModel?,
         me: MeModel?, router: HomeRouter, memory: MemoryService?, people: EntityStore? = nil) {
        self.settings = settings
        self.controller = controller
        self.simSettings = simSettings
        self.sim = sim
        self.conversation = conversation
        let sessionsModel = sessions ?? HomeSessionsModel()
        self.sessions = sessionsModel
        // Only the app itself indexes: a test or render process builds a context too and must not start the brain.
        let isApp = Bundle.main.bundleIdentifier == AppSettings.suiteName
        let memoryService = memory ?? MemoryService(
            ownerName: { settings.ownerName },
            makeBrain: { [weak controller] in try MemoryService.makeBrainProcess(fake: controller?.fakeBrain ?? false) },
            makeIndexBrain: { [weak controller] in try MemoryService.makeBrainProcess(fake: controller?.fakeBrain ?? false, indexOnly: true) },
            enabled: isApp)
        self.memory = memoryService
        let peopleStore = people ?? EntityStore(
            paths: isApp ? memoryService.paths : MemoryPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("verse-people-\(UUID().uuidString)", isDirectory: true)),
            sessionsRoot: sessionsModel.root)
        self.people = peopleStore
        peopleStore.context = { [weak sessionsModel] in (sessionsModel?.folders.file ?? FoldersFile(), sessionsModel?.sessions ?? []) }
        // The memory index shows each session's people and companies; a change of an entity relabels it.
        memoryService.labels = { [weak peopleStore, weak sessionsModel] name in
            guard let peopleStore, let folders = sessionsModel?.folders.file else { return [] }
            return peopleStore.entities(of: name, folders: folders).map(\.name)
        }
        peopleStore.onChange = { [weak memoryService] in memoryService?.requestSync(.labelsChanged) }
        memoryService.recordingSession = { [weak controller] in controller?.recordingSessionName }
        memoryService.attach(controller: controller)
        // Move to Trash asks the window what is running, which session Start uses and which row is shown.
        sessionsModel.hooks = .window(controller: controller, sim: sim, settings: settings, router: router, memory: memoryService)
        self.upNext = upNext ?? HomeUpNextModel(
            settings: settings, meeting: controller.meeting.settings, sessions: { controller.sessions },
            onPrepared: { [weak controller] name in
                controller?.refreshSessions()
                sessionsModel.reload()
                if controller?.running == false { settings.sessionName = name }
            },
            // Who is in the meeting, for People (Up next and Practice's Upcoming both come through here).
            afterPrepare: { [weak peopleStore] event, session in
                peopleStore?.recordAttendees(event.attendees, owner: event.currentUser, session: session)
            })
        self.me = me ?? MeModel(fake: { [weak controller] in controller?.fakeBrain ?? false })
        self.router = router
        if isApp { startPeople(controller: controller, sessions: sessionsModel) }
    }

    /// The app only: People follows the folders and sessions, the Start-from-invite path records attendees, and once per launch the
    /// events the app mapped to sessions are asked of the calendar (it never asks for access: it reads only what is granted).
    private mutating func startPeople(controller: VerseController, sessions: HomeSessionsModel) {
        let store = people
        controller.meeting.onPreparedFromEvent = { [weak store] event, session in
            store?.recordAttendees(event.attendees, owner: event.currentUser, session: session)
        }
        store.refresh()
        peopleSubscriptions.append(sessions.$sessions.combineLatest(sessions.folders.$file)
            .receive(on: DispatchQueue.main)
            .sink { [weak store] _, _ in store?.refresh() })
        let calendar = CalendarSource()
        let eventMap = controller.eventSessions
        let useCalendar = { controller.meeting.settings.useCalendar }
        Task { @MainActor [weak store] in
            try? await Task.sleep(for: .seconds(8))
            guard useCalendar(), calendar.authorization() == .fullAccess else { return }
            await store?.backfill(eventSessions: eventMap.load(), lookup: { id in try? await calendar.event(id: id) })
        }
    }
}

/// The home window: one glass sheet with a sidebar (Prepare, Me, Sessions, People, Practice, Scripts, Settings) and the page.
public struct HomeRoot: View {
    let context: HomeContext
    var a11yOverride: HomeA11yOverride?
    /// Render only: draws SwiftUI glass behind the veil, standing in for the behind-window sheet.
    var inWindowGlass = false
    /// Render only: the Settings page as its header and the Meetings group.
    var meetingsOnly = false
    @ObservedObject private var router: HomeRouter
    @ObservedObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(context: HomeContext) {
        self.init(context: context, a11yOverride: nil, inWindowGlass: false)
    }

    init(context: HomeContext, a11yOverride: HomeA11yOverride?, inWindowGlass: Bool, meetingsOnly: Bool = false) {
        self.context = context
        self.a11yOverride = a11yOverride
        self.inWindowGlass = inWindowGlass
        self.meetingsOnly = meetingsOnly
        router = context.router
        settings = context.settings
    }

    private var ink: VT.Window {
        VT.Window(dark: scheme == .dark,
                  increaseContrast: a11yOverride?.increaseContrast ?? (contrast == .increased),
                  reduceTransparency: a11yOverride?.reduceTransparency ?? reduceTransparency)
    }

    public var body: some View {
        let ink = ink
        let shape = RoundedRectangle(cornerRadius: VT.Radius.window, style: .continuous)
        ZStack(alignment: .topLeading) {
            HomeWindowVeil(ink: ink, opacity: settings.windowOpacity, inWindowGlass: inWindowGlass)
            HStack(spacing: 0) {
                HomeSidebar(context: context).frame(width: 220)
                if ink.increaseContrast {
                    Rectangle().fill(ink.separator).frame(width: 1).padding(.vertical, 16)
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if inWindowGlass {
                // Render only: the offscreen window has no real traffic lights.
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.373, blue: 0.341))
                    Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.18))
                    Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251))
                }
                .frame(width: 52, height: 12).padding(.leading, 20).padding(.top, 20)
            }
            shape.strokeBorder(ink.windowEdge, lineWidth: 1).allowsHitTesting(false)
        }
        .clipShape(shape)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 600)
        .background { if !inWindowGlass { HomeWindowConfigurator(reduceTransparency: ink.reduceTransparency) } }
        .environment(\.homeInk, ink)
        .tint(VT.mint)
        .interfaceLocale()
    }

    @ViewBuilder private var page: some View {
        switch router.page {
        case .prepare:
            ConversationSetupView(model: context.conversation, upNext: context.upNext, meeting: context.controller, settings: settings)
        case .me:
            MePage(model: context.me, controller: context.controller, settings: settings)
        case .sessions:
            HomeSessionsPage(model: context.sessions, router: router, controller: context.controller, settings: settings)
        case .people:
            PeoplePage(store: context.people, sessions: context.sessions, upNext: context.upNext, memory: context.memory,
                       router: router, settings: settings)
        case .practice:
            SimSetupView(sim: context.sim, meeting: context.controller, upNext: context.upNext, router: context.router)
        case .scripts:
            ScriptEditorView(controller: context.controller)
        case .settings:
            SettingsView(settings: settings, controller: context.controller, simSettings: context.simSettings, meetingsOnly: meetingsOnly)
        }
    }
}

// MARK: - Sidebar

/// No background of its own: it sits on the window glass.
private struct HomeSidebar: View {
    let context: HomeContext
    @ObservedObject private var router: HomeRouter
    @ObservedObject private var sessions: HomeSessionsModel
    @ObservedObject private var controller: VerseController
    @ObservedObject private var sim: SimController
    @Environment(\.homeInk) private var ink

    init(context: HomeContext) {
        self.context = context
        router = context.router
        sessions = context.sessions
        controller = context.controller
        sim = context.sim
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The traffic lights sit in the top-left corner (the window moves them there).
            Color.clear.frame(height: 60)
            ForEach(Array(HomePage.allCases.enumerated()), id: \.element) { i, p in
                row(p, index: i)
            }
            .padding(.horizontal, 10)

            if !sessions.sessions.isEmpty {
                Text("Recent", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary)
                    .padding(.leading, 20).padding(.top, 22).padding(.bottom, 4)
                ForEach(sessions.sessions.prefix(3)) { s in
                    Button {
                        router.selectedSession = s.name
                        router.page = .sessions
                    } label: {
                        Text(s.title).font(VT.Font.body).foregroundStyle(ink.secondary).lineLimit(1)
                            .padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
            status.padding(.leading, 20).padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ p: HomePage, index: Int) -> some View {
        let on = p == router.page
        return Button { router.page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                    .foregroundStyle(on ? ink.primary : ink.secondary)
                Text(p.title).font(VT.Font.sidebar).foregroundStyle(ink.primary)
                Spacer()
                if p == .sessions, !sessions.sessions.isEmpty {
                    Text(verbatim: "\(sessions.sessions.count)").font(VT.Font.caption).foregroundStyle(ink.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(on ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var status: some View {
        let (label, dot, detail) = statusLines
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(label).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                }
                Text(detail).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if controller.running {
                SidebarStopButton(stopping: controller.stopping) { Task { await controller.stop() } }
            }
        }
    }

    private var statusLines: (String, Color, String) {
        if controller.stopping { return (L10n.tr("Stopping"), VT.amber, controller.settings.sessionName) }
        if controller.running { return (L10n.tr("Listening · \(controller.settings.sessionName)"), VT.mint, L10n.tr("Also stops with ⌥⌘V twice")) }
        if sim.running { return (L10n.tr("Practice running"), VT.mint, L10n.tr("Answer under the notch")) }
        if controller.sessions.isEmpty { return (L10n.tr("No session"), VT.amber, L10n.tr("Prepare one to start")) }
        return (L10n.tr("Ready"), VT.mint, controller.settings.sessionName)
    }
}

/// The sidebar's Stop: a small neutral button under the status line while a session runs.
private struct SidebarStopButton: View {
    var stopping: Bool
    var action: () -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                Text(SessionStop.title(stopping: stopping)).font(VT.Font.bodyEmph)
            }
            .foregroundStyle(ink.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(ink.selection, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!SessionStop.canStop(running: true, stopping: stopping))
        .opacity(stopping ? 0.6 : 1)
        .accessibilityLabel(SessionStop.accessibilityLabel(stopping: stopping))
        .accessibilityIdentifier("verse.home.stop")
    }
}
