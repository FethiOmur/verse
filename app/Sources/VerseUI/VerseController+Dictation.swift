import Combine
import Foundation

/// Dictation's wiring to the session controller: what counts as "a run is active", and the launch-time activation. Nothing
/// here changes how a meeting starts, runs or stops; dictation only reads `running`, `stopping`, the practice interview's
/// phase and whether the prompter is open.
extension VerseController {
    /// A meeting runs or is stopping, a practice interview runs, or the prompter is open (its script mode listens to the
    /// microphone). Any of them blocks dictation and cancels one under way.
    nonisolated static func dictationBlocked(running: Bool, stopping: Bool, practiceRunning: Bool, prompterOpen: Bool) -> Bool {
        running || stopping || practiceRunning || prompterOpen
    }

    /// Gives dictation its run gate (the state now, and the changes). No hot key is registered here.
    public func bindDictation(practice sim: SimController) {
        let d = dictation
        d.isRunActive = { [weak self, weak sim] in
            guard let self else { return false }
            return Self.dictationBlocked(running: running, stopping: stopping, practiceRunning: sim?.running ?? false,
                                         prompterOpen: prompter.isOpen)
        }
        // @Published sends the new value before the property changes, so the values are taken from the publishers.
        d.observeRuns(Publishers.CombineLatest4($running, $stopping, sim.$phase, prompter.$isOpen).map { r, s, p, o in
            Self.dictationBlocked(running: r, stopping: s, practiceRunning: p == .running, prompterOpen: o)
        })
        // A meeting prompt or status keeps the meeting island up with no run: the dictation island hangs below it.
        d.avoidMeetingIsland { [weak self] in self?.meetingIslandFrame }
        onMeetingIslandChange = { [weak d] in d?.meetingIslandChanged() }
    }

    /// App launch: binds the gate and follows the setting (the hot key is registered only while dictation is on). A test copy
    /// (`--no-hotkeys`) or a test process registers nothing, as for ⌥⌘V.
    public func installDictation(practice sim: SimController) {
        guard Bundle.main.bundleIdentifier == AppSettings.suiteName, !launch.noHotKeys else { return }
        bindDictation(practice: sim)
        dictation.activate()
    }
}
