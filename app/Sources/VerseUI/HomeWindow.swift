import AppKit
import SwiftUI

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
    public let router: HomeRouter

    public init(settings: AppSettings, controller: VerseController, simSettings: SimSettings, sim: SimController,
                conversation: ConversationController, sessions: HomeSessionsModel? = nil, upNext: HomeUpNextModel? = nil,
                router: HomeRouter = .shared) {
        self.settings = settings
        self.controller = controller
        self.simSettings = simSettings
        self.sim = sim
        self.conversation = conversation
        let sessionsModel = sessions ?? HomeSessionsModel()
        self.sessions = sessionsModel
        self.upNext = upNext ?? HomeUpNextModel(
            settings: settings, meeting: controller.meeting.settings, sessions: { controller.sessions },
            onPrepared: { [weak controller] name in
                controller?.refreshSessions()
                sessionsModel.reload()
                if controller?.running == false { settings.sessionName = name }
            })
        self.router = router
    }
}

/// The home window: one glass sheet with a sidebar (Prepare, Sessions, Practice, Scripts, Settings) and the page.
public struct HomeRoot: View {
    let context: HomeContext
    var a11yOverride: HomeA11yOverride?
    /// Render only: draws SwiftUI glass behind the veil, standing in for the behind-window sheet.
    var inWindowGlass = false
    @ObservedObject private var router: HomeRouter
    @ObservedObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(context: HomeContext) {
        self.init(context: context, a11yOverride: nil, inWindowGlass: false)
    }

    init(context: HomeContext, a11yOverride: HomeA11yOverride?, inWindowGlass: Bool) {
        self.context = context
        self.a11yOverride = a11yOverride
        self.inWindowGlass = inWindowGlass
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
    }

    @ViewBuilder private var page: some View {
        switch router.page {
        case .prepare:
            ConversationSetupView(model: context.conversation, upNext: context.upNext, meeting: context.controller, settings: settings)
        case .sessions:
            HomeSessionsPage(model: context.sessions, router: router, controller: context.controller, settings: settings)
        case .practice:
            SimSetupView(sim: context.sim, meeting: context.controller)
        case .scripts:
            ScriptEditorView(controller: context.controller)
        case .settings:
            SettingsView(settings: settings, controller: context.controller, simSettings: context.simSettings)
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
                Text("Recent").font(VT.Font.caption).foregroundStyle(ink.tertiary)
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
                    Text("\(sessions.sessions.count)").font(VT.Font.caption).foregroundStyle(ink.tertiary).monospacedDigit()
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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(label).font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
            }
            Text(detail).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLines: (String, Color, String) {
        if controller.stopping { return ("Stopping", VT.amber, controller.settings.sessionName) }
        if controller.running { return ("Listening", VT.mint, controller.settings.sessionName) }
        if sim.running { return ("Practice running", VT.mint, "Answer under the notch") }
        if controller.sessions.isEmpty { return ("No session", VT.amber, "Prepare one to start") }
        return ("Ready", VT.mint, controller.settings.sessionName)
    }
}
