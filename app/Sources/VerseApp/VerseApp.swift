import AppKit
import SwiftUI
import VerseSpeech
import VerseTurns
import VerseUI

/// Verse: a menu-bar app (no Dock icon) that listens to a meeting and shows suggestions under the notch.
@main
struct VerseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            VerseMenu(controller: delegate.controller, settings: delegate.settings, sim: delegate.sim, rehearsal: delegate.rehearsal)
                .interfaceLocale()
        } label: {
            MenuBarLabel(controller: delegate.controller, dictation: delegate.controller.dictation)
        }
        .menuBarExtraStyle(.menu)

        // One home window replaces the settings, script editor, conversation, practice and report windows.
        Window("Verse", id: HomeRouter.windowID) {
            HomeRoot(context: delegate.home)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 680)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: VerseController
    /// Dictation shows in the menu-bar icon: a microphone while it records (never together with a meeting).
    @ObservedObject var dictation: DictationController
    @Environment(\.openWindow) private var openWindow

    private var symbol: String {
        switch dictation.phase {
        case .recording: return "mic.circle.fill"
        case .finalising, .inserting: return "mic.circle"
        case .idle: return controller.running ? "waveform.circle.fill" : "waveform.circle"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text("Verse", bundle: L10n.bundle))
            // The label is always alive: it hands the scene's openWindow to the router, so code outside a view (the
            // practice report, the launch options) can open the home window.
            .onAppear { HomeRouter.shared.register(openWindow: openWindow) }
    }
}

/// The menu-bar menu (owner decisions, 24 Nov 2026): three states. Idle with a next meeting: the meeting and its session state,
/// Start (a preview of ⌥⌘V), Start unprepared (⌥⇧⌘V), Prepare, the Session and Audio source submenus. Idle with no meeting: the
/// same without the info rows. Running: Listening, Stop, Previous answer, Answer the last question, New answer to this question,
/// Mark the answer bad, Audio source, and the
/// teleprompter's controls while it is open. The call language never appears: every start runs in Settings' call language
/// (Auto). Dictation's own language does (gap G12): the "Dictation language" submenu while dictation is on and idle of runs.
/// Native menu rows are plain text: no colours, no badges.
struct VerseMenu: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    @ObservedObject var sim: SimController
    let rehearsal: RehearsalDesk
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if controller.running || controller.stopping {
            RunningMenuSection(controller: controller, prompter: controller.prompter, rehearsal: rehearsal)
        } else {
            IdleMenuSection(controller: controller, selector: controller.selector, autoPrep: controller.autoPrep,
                            watcher: controller.calendarWatcher, meetingSettings: controller.meeting.settings, sim: sim,
                            rehearsal: rehearsal)
        }
        Divider()
        // The last dictation, while dictation is on and one is kept (rows and their divider, or nothing).
        DictationMenuItems(dictation: controller.dictation)
        // Dictation's language and the per-app choice for the app in front (submenu and its divider, or nothing).
        DictationLanguageMenu(dictation: controller.dictation)
        Button { HomeRouter.shared.show(HomeRouter.shared.page, openWindow: openWindow) } label: { Text("Open Verse", bundle: L10n.bundle) }
        Button {
            HomeRouter.shared.show(.settings, openWindow: openWindow)
        } label: { Text("Settings…", bundle: L10n.bundle) }
        .keyboardShortcut(",")
        Button { NSApp.terminate(nil) } label: { Text("Quit Verse", bundle: L10n.bundle) }
            .keyboardShortcut("q")
    }
}

/// Idle: what Start will do, and the session and audio choices behind it.
struct IdleMenuSection: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var selector: SessionSelector
    @ObservedObject var autoPrep: MeetingAutoPrep
    @ObservedObject var watcher: CalendarWatcher
    @ObservedObject var meetingSettings: MeetingSettings
    @ObservedObject var sim: SimController
    let rehearsal: RehearsalDesk
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let picker = controller.pickerModel()
        let next = NextMeetingRows.make(target: selector.target, picker: picker, now: controller.clock(), calendar: controller.calendar)
        let preview = controller.startPreview()
        if let next {
            Text(verbatim: next.meeting)
            Text(verbatim: next.stateText)
            Divider()
        }
        // The label is what ⌥⌘V does right now (the same decision `startNow` makes).
        Button { controller.startNow() } label: { Text(verbatim: preview.title) }
            .keyboardShortcut("v", modifiers: [.option, .command])
            .disabled(sim.running || controller.stopping)
        if preview.showsUnpreparedRow {
            // A sudden call while a meeting's session is up next (owner decision 5): the selection and the manual pick stay.
            Button { controller.startUnprepared() } label: { Text("Start unprepared", bundle: L10n.bundle) }
                .keyboardShortcut("v", modifiers: [.option, .shift, .command])
                .disabled(sim.running || controller.stopping)
        }
        if next?.offersPrepare == true {
            Button { controller.prepareNextMeeting() } label: { Text("Prepare for this meeting", bundle: L10n.bundle) }
                .disabled(sim.running)
        }
        // A typed line through the real session, shown in the island (no audio, nothing saved to the session).
        Button { rehearsal.showPanel() } label: { Text("Rehearse a line…", bundle: L10n.bundle) }
            .disabled(sim.running || controller.stopping)
        Divider()
        SessionSubmenu(controller: controller, selector: selector, picker: picker.capped(selected: controller.settings.sessionName))
        AudioSourceSubmenu(controller: controller)
        switch controller.calendarNudge {
        case .turnOn?:
            Button { controller.turnOnCalendar() } label: { Text("Connect calendar…", bundle: L10n.bundle) }
        case .permissionMissing?:
            Button { SystemSettingsLink.open(permission: "calendar") } label: {
                Text("Calendar permission missing · Open System Settings", bundle: L10n.bundle)
            }
        case nil:
            EmptyView()
        }
    }
}

/// The Session submenu (G5): the newest `SessionPickerModel.menuLimit` rows, Next meetings first, then "All sessions…".
struct SessionSubmenu: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var selector: SessionSelector
    let picker: SessionPickerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Picker(selection: selector.manualBinding) {
                if !picker.nextMeetings.isEmpty {
                    Section {
                        ForEach(picker.nextMeetings) { Text(verbatim: $0.display).tag($0.session) }
                    } header: { Text("Next meetings", bundle: L10n.bundle) }
                    if !picker.others.isEmpty {
                        Section {
                            ForEach(picker.others) { Text(verbatim: $0.display).tag($0.session) }
                        } header: { Text("Other sessions", bundle: L10n.bundle) }
                    }
                } else {
                    ForEach(picker.others) { Text(verbatim: $0.display).tag($0.session) }
                }
            } label: { Text("Session", bundle: L10n.bundle) }
            .pickerStyle(.inline)
            Divider()
            Button { HomeRouter.shared.show(.sessions, openWindow: openWindow) } label: { Text("All sessions…", bundle: L10n.bundle) }
        } label: { Text("Session", bundle: L10n.bundle) }
    }
}

/// Where Verse listens: before a Start the choice for it (Automatic included); during a call it switches the call.
struct AudioSourceSubmenu: View {
    @ObservedObject var controller: VerseController

    var body: some View {
        Menu {
            Picker(selection: Binding<AudioRoute?>(
                get: { controller.running ? controller.route : controller.routeChoice },
                set: { controller.chooseRoute($0) })) {
                if !controller.running { Text("Automatic", bundle: L10n.bundle).tag(AudioRoute?.none) }
                Text("Meeting app", bundle: L10n.bundle).tag(AudioRoute?.some(.meeting))
                Text("Room (microphone only)", bundle: L10n.bundle).tag(AudioRoute?.some(.room))
            } label: { Text("Route", bundle: L10n.bundle) }
            .pickerStyle(.inline)
        } label: { Text("Route", bundle: L10n.bundle) }
        .disabled(controller.stopping)
    }
}

/// Running: the call and what can be done to it. The answer keys are written in the labels (they are global hot keys, not
/// menu shortcuts: a menu shortcut would only work while the menu is open).
struct RunningMenuSection: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var prompter: PrompterModel
    let rehearsal: RehearsalDesk

    var body: some View {
        Text(controller.statusLine)
        Divider()
        if controller.rehearsal != nil {
            Button { rehearsal.showPanel() } label: { Text("Rehearse a line…", bundle: L10n.bundle) }
        }
        Button { Task { await controller.stop() } } label: { Text("Stop", bundle: L10n.bundle) }
            .disabled(controller.stopping)
        Button { controller.showEarlierAnswer() } label: { Text("Previous answer \("⌥⌘←")", bundle: L10n.bundle) }
            .disabled(controller.stopping)
        Button { controller.cardNow() } label: { Text("Answer the last question \("⌥⌘↩")", bundle: L10n.bundle) }
            .disabled(controller.stopping)
        Button { controller.regenerate() } label: { Text("New answer to this question \("⌥⌘R")", bundle: L10n.bundle) }
            .disabled(controller.stopping)
        Button { controller.markAnswer(.bad) } label: { Text("Mark the answer bad \("⌥⌘↓")", bundle: L10n.bundle) }
            .disabled(controller.stopping)
        Divider()
        AudioSourceSubmenu(controller: controller)
        if prompter.isOpen {
            Button { prompter.send(.toggle) } label: {
                if prompter.state.isPaused { Text("Start prompter", bundle: L10n.bundle) } else { Text("Pause prompter", bundle: L10n.bundle) }
            }
            Button { prompter.send(.close) } label: { Text("Close prompter", bundle: L10n.bundle) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let simSettings = SimSettings()
    lazy var controller = VerseController(settings: settings)
    lazy var sim = SimController(settings: settings, simSettings: simSettings, meeting: controller)
    lazy var conversation = ConversationController(settings: settings, meeting: controller)
    lazy var home = HomeContext(settings: settings, controller: controller, simSettings: simSettings, sim: sim, conversation: conversation)
    /// "Rehearse a line…": the menu's panel and the `verse-rehearse://` URL scheme for scripts.
    lazy var rehearsal = RehearsalDesk(controller: controller)
    private var quitGate = QuitGate()
    private var testWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []

    /// The `verse-rehearse://` URLs (Info.plist `CFBundleURLTypes`) come in as Apple events. Handled here, before SwiftUI's
    /// default handling, so a URL never opens a window of its own.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if !rehearsal.handle(url: url) { FileLog.shared.write("ignored URL with scheme \(url.scheme ?? "-")") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A write to a child that already exited (the brain, prep, git) must fail with EPIPE, not kill the app (review H3).
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        // A practice interview owns the microphone: no meeting starts on top of it (⌥⌘V included), and ⌥⌘V twice ends it.
        controller.bindPractice(sim)
        // Once, off the main thread, before any model load: removes compile bundles that killed runs left in the Core ML cache.
        E5BundleCacheCleaner.startOnce { FileLog.shared.write($0) }
        // SIGTERM / SIGINT (e.g. `kill`, Ctrl-C on a dev run): quit the normal way, which shuts the brain down.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Self.terminateSoon() }
            src.resume()
            signalSources.append(src)
        }
        let launch = controller.launch
        // `--render-home DIR`: renders every home page (light and dark, plus the accessibility variants) and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-home"), i + 1 < args.count {
            let dir = args[i + 1]
            // Optional page names after the folder limit the render (`--render-home DIR practice settings`).
            let only = args.dropFirst(i + 2).prefix { !$0.hasPrefix("--") }.compactMap(HomePage.init(rawValue:))
            Task { @MainActor in
                do {
                    let paths = try await HomeRender.renderAll(to: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath),
                                                               pages: only.isEmpty ? nil : Array(only))
                    for p in paths { print(p.path) }
                } catch {
                    FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                }
                Self.terminateSoon()
            }
            return
        }
        // `--open-home [page]`: opens the home window at launch (testing).
        if let i = args.firstIndex(of: "--open-home") {
            let page = (i + 1 < args.count ? HomePage(rawValue: args[i + 1]) : nil) ?? .prepare
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if ProcessInfo.processInfo.environment["VERSE_HOME_NOACTIVATE"] != nil {
                    // Testing without taking the keyboard focus: the same HomeRoot in a plain window, ordered front only.
                    HomeRouter.shared.page = page
                    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
                    w.title = "Verse"
                    w.isReleasedWhenClosed = false
                    w.contentView = NSHostingView(rootView: HomeRoot(context: home))
                    w.setFrameOrigin(NSPoint(x: 206, y: 120))
                    w.orderFrontRegardless()
                    testWindow = w
                } else {
                    HomeRouter.shared.show(page)
                }
            }
        }
        if let dir = launch.renderScreensDir {
            Task { @MainActor in
                do {
                    let paths = try await ScreenRenderer.renderAll(to: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath),
                                                                   scales: ProcessInfo.processInfo.environment["VERSE_RENDER_SCALES"] == "all" ? TextScale.allCases : [.medium])
                    for p in paths { print(p.path) }
                } catch {
                    FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                }
                Self.terminateSoon()
            }
            return
        }
        if let names = launch.previewOverlay {
            let seconds = Double(ProcessInfo.processInfo.environment["VERSE_PREVIEW_SECONDS"] ?? "") ?? 2
            Task { @MainActor in
                await ScreenRenderer.preview(names: names, seconds: min(max(seconds, 0.5), 10), settings: settings)
                Self.terminateSoon()
            }
            return
        }
        if let n = launch.cycles {
            Task { @MainActor in
                let r = await controller.runCycles(n)
                let line = "cycles: \(r.filter { $0 }.count)/\(r.count) reached Ready"
                controller.log(line)
                print(line)
                Self.terminateSoon()
            }
            return
        }
        // The next meeting's session is picked before detection starts, then on every calendar change (G1, G11).
        controller.beginSessionSelection()
        if launch.autostart { controller.start() }
        controller.meeting.begin()
        // Dictation (⌃⌥⌘D): off by default; while it is off no hot key is registered.
        controller.installDictation(practice: sim)
    }

    /// `terminate` runs a nested event loop while the reply is pending. Called from inside a main-queue job (a Task,
    /// a dispatch source) that loop could never run the reply, so it is started from the run loop instead.
    static func terminateSoon() {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// Quit during a call stops it the way Stop does, with the same grace for the brain's final summary (the old 6 s cut it off);
    /// a second Quit while that runs kills the brain and quits at once. Quit with nothing running is instant. SIGTERM, SIGINT and
    /// SIGHUP arrive here too (`terminateSoon`), so they behave the same.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch quitGate.quit(sessionActive: controller.running || sim.running) {
        case .force:
            FileLog.shared.write("quit again while the call was ending: killing the brain")
            BrainProcess.killAll()
            return .terminateNow
        case .now:
            SimReportWindow.closeAll()
            BrainProcess.killAll()
            return .terminateNow
        case .graceful(let budget):
            SimReportWindow.closeAll()
            FileLog.shared.write(String(format: "quit during a call: stopping it, waiting up to %.0f s for the summary", budget))
            Task { @MainActor in
                controller.meeting.end()
                await sim.shutdown()
                await controller.shutdown(timeout: budget)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrainProcess.killAll()
    }
}
