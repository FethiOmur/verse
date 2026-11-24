import AppKit
import Foundation
import Testing
@testable import VerseUI

// The panel's own "nothing to show, hide" watcher runs one run-loop hop late. It must judge the model as it is when it
// runs, not the stale value it was handed.

@Suite("Notch panel visibility")
@MainActor
struct NotchPanelVisibilityTests {
    /// Meeting prompt → Start: the coordinator clears the prompt (a moment with nothing running), then the controller starts
    /// the session and shows the panel. The late watcher used to hide the panel of the call that had just started.
    @Test
    func startFromMeetingPromptKeepsThePanelUp() async throws {
        _ = NSApplication.shared
        let model = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
        let panel = NotchPanelController(model: model, settings: AppSettings(defaults: scratchDefaults()), onOpenSettings: { _ in })
        defer { panel.close() }

        model.showPrompt(MeetingPrompt.detected(appName: "Comet", eventTitle: "Mara · Northwind Labs", plan: .prepared("mara")))
        panel.show()
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.isVisible)

        // MeetingCoordinator.begin, then VerseController.launchSession, in the same main-actor turn.
        model.showPrompt(nil)
        model.sessionStarting(lang: "en", session: "mara", app: "Comet")
        panel.show()

        try await Task.sleep(for: .milliseconds(100))
        #expect(model.state.running)
        #expect(panel.isVisible)
    }

    /// V7: a display change rebuilds the root view; the permission panel's "Open System Settings" must still reach the
    /// controller's callback afterwards (it used to get a no-op closure).
    @Test
    func displayChangeKeepsOpenSettings() {
        _ = NSApplication.shared
        let model = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
        var opened: [String] = []
        let panel = NotchPanelController(model: model, settings: AppSettings(defaults: scratchDefaults()),
                                         onOpenSettings: { opened.append($0) })
        defer { panel.close() }

        panel.apply(metrics: NotchMetrics(notchWidth: 200, notchHeight: 38, hasNotch: true))
        panel.apply(metrics: NotchMetrics(notchWidth: 186, notchHeight: 28, hasNotch: false))
        panel.rootOverlay?.onOpenSettings("microphone")
        #expect(opened == ["microphone"])
    }

    @Test
    func idleModelStillHidesThePanel() async throws {
        _ = NSApplication.shared
        let model = OverlayModel(config: OverlayConfig(cardTimeout: .infinity), clock: { 1000 })
        let panel = NotchPanelController(model: model, settings: AppSettings(defaults: scratchDefaults()), onOpenSettings: { _ in })
        defer { panel.close() }

        model.showPrompt(MeetingPrompt.detected(appName: "Comet", eventTitle: nil, plan: .unprepared))
        panel.show()
        try await Task.sleep(for: .milliseconds(50))
        model.showPrompt(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.isVisible)
    }
}
