import Foundation

/// What Quit does (the app's `applicationShouldTerminate`; SIGTERM, SIGINT and SIGHUP come the same way).
///
/// Quit during a call ends it like Stop: the brain gets `control stop` and the same grace for its final summary merge
/// (`RunOptions.stopBudgetSeconds`), so a Quit in the middle of a call no longer loses `summary.md`. Quit with nothing running
/// is instant. A second Quit while the first is still waiting is the escape hatch: it kills the brain and quits at once.
public struct QuitGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Nothing to finish: kill any brain left and terminate now.
        case now
        /// Stop the call gracefully, waiting at most `budget` seconds, then terminate.
        case graceful(budget: TimeInterval)
        /// A Quit while the graceful stop is still waiting: kill the brain and terminate now.
        case force
    }

    public private(set) var waiting = false
    public let budget: TimeInterval

    public init(budget: TimeInterval = RunOptions.stopBudgetSeconds) { self.budget = budget }

    /// `sessionActive`: a meeting call or a practice interview is running.
    public mutating func quit(sessionActive: Bool) -> Decision {
        if waiting { return .force }
        guard sessionActive else { return .now }
        waiting = true
        return .graceful(budget: budget)
    }
}
