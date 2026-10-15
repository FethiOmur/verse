import AppKit
import SwiftUI
import VerseTurns
import VerseUI

/// Verse: a menu-bar app (no Dock icon) that listens to a meeting and shows suggestions under the notch.
@main
struct VerseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            VerseMenu(controller: delegate.controller, settings: delegate.settings, sim: delegate.sim)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("Verse Settings", id: "settings") {
            SettingsView(settings: delegate.settings, controller: delegate.controller, simSettings: delegate.simSettings)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // T-UI: the teleprompter's script editor.
        Window("Teleprompter Scripts", id: "script-editor") {
            ScriptEditorView(controller: delegate.controller)
        }
        .defaultLaunchBehavior(.suppressed)

        // S4: the practice-interview setup window.
        Window("Practice Interview", id: "sim-setup") {
            SimSetupView(sim: delegate.sim, meeting: delegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: VerseController
    var body: some View {
        Image(systemName: controller.running ? "waveform.circle.fill" : "waveform.circle")
            .accessibilityLabel("Verse")
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
        if controller.running {
            Button("Stop") { Task { await controller.stop() } }
                .keyboardShortcut("s")
                .disabled(controller.stopping)
        } else {
            Button("Start") { controller.start() }
                .keyboardShortcut("s")
                .disabled(controller.sessions.isEmpty || sim.running)
        }
        Picker("Session", selection: $settings.sessionName) {
            ForEach(controller.sessions, id: \.self) { Text($0).tag($0) }
        }
        .disabled(controller.running)
        Picker("Language", selection: $settings.language) {
            Text("English").tag("en")
            Text("Italian").tag("it")
            Text("Turkish").tag("tr")
        }
        .disabled(controller.running)
        Divider()
        // W2: self-test without a meeting app: the file is the remote side, the microphone stays "me".
        Button("Play test file as remote…") {
            if let url = RemoteFilePicker.choose() { controller.start(remoteFile: url) }
        }
        .disabled(controller.running || controller.stopping || controller.sessions.isEmpty || sim.running)
        Divider()
        if sim.running {
            Button("End practice interview") { sim.endInterview() }
        } else {
            Button("Practice interview…") {
                NSApp.activate()
                openWindow(id: "sim-setup")
            }
            .disabled(controller.running)
        }
        if sim.lastReport != nil {
            Button("Last practice report") { sim.openLastReport() }
        }
        PrompterMenuBlock(controller: controller)
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Quit Verse") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let simSettings = SimSettings()
    lazy var controller = VerseController(settings: settings)
    lazy var sim = SimController(settings: settings, simSettings: simSettings, meeting: controller)
    private var quitting = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // SIGTERM / SIGINT (e.g. `kill`, Ctrl-C on a dev run): quit the normal way, which shuts the brain down.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Self.terminateSoon() }
            src.resume()
            signalSources.append(src)
        }
        let launch = controller.launch
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
