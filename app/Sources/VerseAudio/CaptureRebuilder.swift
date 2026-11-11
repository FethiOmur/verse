import Foundation
import os

/// What a live capture source reports while it runs, beyond its chunks (review H5).
public enum CaptureEvent: Sendable, Equatable {
    /// The source rebuilt itself after a device or format change and delivers audio again. The text says why.
    case rebuilt(String)
    /// The source could not rebuild itself after every retry; it delivers no audio until a later change succeeds.
    case failed(String)
}

/// Rebuilds a live capture source after "the device changed" signals: triggers are coalesced (a device switch fires several
/// notifications at once), the rebuild runs on the source's serial control queue, and a failed rebuild is retried a few times
/// (a device that is still appearing reports a 0 Hz format for a moment) before `.failed` is reported.
///
/// `rebuild` returns true when it rebuilt, false when nothing needed doing (the engine still runs on the same device and
/// format). That check is what keeps a notification caused by the rebuild itself from looping: the next pass finds nothing to do
/// and reports nothing. A source may also return false after a rebuild it does not want reported yet (the tap's quiet
/// silent-tap probe, which is reported only if audio comes back).
public final class CaptureRebuilder: @unchecked Sendable {
    public typealias Rebuild = @Sendable () throws -> Bool

    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let retryDelays: [TimeInterval]
    private let rebuild: Rebuild
    private let report: @Sendable (CaptureEvent) -> Void
    private let lock = OSAllocatedUnfairLock()
    /// A pass is waiting or running (including its retries).
    private var busy = false
    /// `rebuild` is executing right now (a trigger now may come from a change it did not see).
    private var running = false
    /// A trigger arrived while `rebuild` was executing: run one more pass after it.
    private var dirty = false
    private var cancelled = false
    private var reasons: [String] = []

    public init(queue: DispatchQueue, debounce: TimeInterval = 0.3, retryDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0],
                rebuild: @escaping Rebuild, report: @escaping @Sendable (CaptureEvent) -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.retryDelays = retryDelays
        self.rebuild = rebuild
        self.report = report
    }

    /// Something changed (any thread). Starts a pass after `debounce` unless one is already pending.
    public func trigger(_ reason: String) {
        let start = lock.withLockUnchecked { () -> Bool in
            guard !cancelled else { return false }
            if !reasons.contains(reason) { reasons.append(reason) }
            if busy {
                // Waiting (debounce or retry delay): the pending attempt covers it. Executing: look again afterwards.
                if running { dirty = true }
                return false
            }
            busy = true
            return true
        }
        if start { schedule(attempt: 0, after: debounce) }
    }

    /// No pass runs after this returns (one already running on the queue finishes).
    public func cancel() { lock.withLockUnchecked { cancelled = true } }

    private func schedule(attempt n: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attempt(n) }
    }

    private func attempt(_ n: Int) {
        let (go, why) = lock.withLockUnchecked { () -> (Bool, String) in
            if cancelled { busy = false } else { running = true }
            return (!cancelled, reasons.joined(separator: "; "))
        }
        guard go else { return }
        do {
            let did = try rebuild()
            lock.withLockUnchecked { running = false }
            if did { report(.rebuilt(why)) }
            finishPass()
        } catch {
            lock.withLockUnchecked { running = false }
            if n < retryDelays.count {
                schedule(attempt: n + 1, after: retryDelays[n])
            } else {
                report(.failed("\(why): \(error) (after \(n + 1) attempts)"))
                finishPass()
            }
        }
    }

    private func finishPass() {
        let again = lock.withLockUnchecked { () -> Bool in
            if dirty && !cancelled { dirty = false; return true }
            busy = false
            dirty = false
            reasons = []
            return false
        }
        if again { schedule(attempt: 0, after: debounce) }
    }
}
