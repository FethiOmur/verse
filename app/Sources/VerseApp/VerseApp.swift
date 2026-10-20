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
            VerseMenu(controller: delegate.controller, settings: delegate.settings, sim: delegate.sim)
                .interfaceLocale()
        } label: {
            MenuBarLabel(controller: delegate.controller)
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
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: controller.running ? "waveform.circle.fill" : "waveform.circle")
            .accessibilityLabel(Text("Verse", bundle: L10n.bundle))
            // The label is always alive: it hands the scene's openWindow to the router, so code outside a view (the
            // practice report, the launch options) can open the home window.
            .onAppear { HomeRouter.shared.register(openWindow: openWindow) }
    }
}

struct VerseMenu: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var settings: AppSettings
    @ObservedObject var sim: SimController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusLine)
        Divider()
        Button { HomeRouter.shared.show(HomeRouter.shared.page, openWindow: openWindow) } label: { Text("Open Verse", bundle: L10n.bundle) }
        Divider()
        if controller.running {
            Button { Task { await controller.stop() } } label: { Text("Stop", bundle: L10n.bundle) }
                .keyboardShortcut("s")
                .disabled(controller.stopping)
        } else {
            // Start at once, with or without a prepared session (anytime calls). ⌥⌘V does the same from anywhere.
            Button { controller.startNow() } label: { Text("Start now", bundle: L10n.bundle) }
                .keyboardShortcut("v", modifiers: [.option, .command])
                .disabled(sim.running || controller.stopping)
            Button { controller.start() } label: { Text("Start prepared session", bundle: L10n.bundle) }
                .keyboardShortcut("s")
                .disabled(controller.sessions.isEmpty || sim.running)
        }
        // Where Verse listens and in which language: before a Start they are the choice for it; during a call they switch it.
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
        Menu {
            Picker(selection: Binding(
                get: { controller.running ? (controller.autoLanguage ? AppSettings.autoLanguage : controller.callLanguage) : settings.defaultCallLanguage },
                set: { controller.chooseLanguage($0) })) {
                if controller.running && controller.autoLanguage {
                    Text("Auto · \(controller.callLanguage.uppercased())", bundle: L10n.bundle).tag(AppSettings.autoLanguage)
                } else {
                    Text("Auto", bundle: L10n.bundle).tag(AppSettings.autoLanguage)
                }
                Text("English", bundle: L10n.bundle).tag("en")
                Text("Italian", bundle: L10n.bundle).tag("it")
                Text("Turkish", bundle: L10n.bundle).tag("tr")
            } label: { Text("Language", bundle: L10n.bundle) }
            .pickerStyle(.inline)
        } label: { Text("Language", bundle: L10n.bundle) }
        .disabled(controller.stopping)
        Picker(selection: $settings.sessionName) {
            ForEach(controller.sessions, id: \.self) { Text(verbatim: $0).tag($0) }
        } label: { Text("Session", bundle: L10n.bundle) }
        .disabled(controller.running)
        Picker(selection: $settings.language) {
            Text("English", bundle: L10n.bundle).tag("en")
            Text("Italian", bundle: L10n.bundle).tag("it")
            Text("Turkish", bundle: L10n.bundle).tag("tr")
        } label: { Text("Meeting language", bundle: L10n.bundle) }
        .disabled(controller.running)
        Divider()
        // W2: self-test without a meeting app: the file is the remote side, the microphone stays "me".
        Button {
            if let url = RemoteFilePicker.choose() { controller.start(remoteFile: url) }
        } label: { Text("Play test file as remote…", bundle: L10n.bundle) }
        .disabled(controller.running || controller.stopping || controller.sessions.isEmpty || sim.running)
        Divider()
        if sim.running {
            Button { sim.endInterview() } label: { Text("End practice interview", bundle: L10n.bundle) }
        } else {
            Button {
                HomeRouter.shared.show(.practice, openWindow: openWindow)
            } label: { Text("Practice interview…", bundle: L10n.bundle) }
            .disabled(controller.running)
        }
        if sim.lastReport != nil {
            Button { sim.openLastReport() } label: { Text("Last practice report", bundle: L10n.bundle) }
        }
        PrompterMenuBlock(controller: controller)
        ConversationMenuBlock()
        Divider()
        Button {
            HomeRouter.shared.show(.settings, openWindow: openWindow)
        } label: { Text("Settings…", bundle: L10n.bundle) }
        .keyboardShortcut(",")
        Button { NSApp.terminate(nil) } label: { Text("Quit Verse", bundle: L10n.bundle) }
            .keyboardShortcut("q")
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
    private var quitting = false
    private var testWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        if launch.autostart { controller.start() }
        controller.meeting.begin()
    }

    /// `terminate` runs a nested event loop while the reply is pending. Called from inside a main-queue job (a Task,
    /// a dispatch source) that loop could never run the reply, so it is started from the run loop instead.
    static func terminateSoon() {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        SimReportWindow.closeAll()
        if !controller.running, !sim.running {
            BrainProcess.killAll()
            return .terminateNow
        }
        Task { @MainActor in
            controller.meeting.end()
            await sim.shutdown()
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrainProcess.killAll()
    }
}
