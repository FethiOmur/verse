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
            VerseMenu(controller: delegate.controller, settings: delegate.settings)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("Verse Settings", id: "settings") {
            SettingsView(settings: delegate.settings, controller: delegate.controller)
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
                .disabled(controller.sessions.isEmpty)
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
    lazy var controller = VerseController(settings: settings)
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
        if launch.autostart { controller.start() }
    }

    /// `terminate` runs a nested event loop while the reply is pending. Called from inside a main-queue job (a Task,
    /// a dispatch source) that loop could never run the reply, so it is started from the run loop instead.
    static func terminateSoon() {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        if !controller.running {
            BrainProcess.killAll()
            return .terminateNow
        }
        Task { @MainActor in
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrainProcess.killAll()
    }
}
