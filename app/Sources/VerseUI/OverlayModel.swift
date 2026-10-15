import Combine
import Foundation
import VerseTurns

/// The overlay's observable state for SwiftUI. All logic is in `OverlayReducer`; this only publishes it and runs the
/// timeout clock.
@MainActor
public final class OverlayModel: ObservableObject {
    @Published public private(set) var state = OverlayState()
    private var reducer: OverlayReducer
    private let clock: () -> TimeInterval
    private var timer: Timer?

    public init(config: OverlayConfig = OverlayConfig(), bank: [String: BankOpener] = [:],
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        reducer = OverlayReducer(config: config, bank: bank)
        self.clock = clock
    }

    public var config: OverlayConfig {
        get { reducer.config }
        set { reducer.config = newValue }
    }

    public var bank: [String: BankOpener] {
        get { reducer.bank }
        set { reducer.bank = newValue }
    }

    public func apply(_ e: RunnerEvent) {
        reducer.apply(e, now: clock())
        publish()
    }

    /// Runs the card timeout (call it on a timer; tests call it with a moved clock).
    public func tick() {
        reducer.tick(now: clock())
        publish()
    }

    public func sessionStarting(lang: String, session: String = "", app: String? = nil) {
        reducer.sessionStarting(lang: lang, session: session, app: app)
        publish()
    }

    /// Click on the capsule: closes the open card, else the start-up panel.
    public func collapse() {
        reducer.collapse()
        publish()
    }

    /// Shows an error message (with Retry) for a run that ended without saying why.
    public func showError(_ message: String) {
        reducer.setStatus(.error(message))
        publish()
    }

    /// Clears the status chip (the user closed the message).
    public func dismissStatus() {
        var s = reducer
        s.clearStatus()
        reducer = s
        publish()
    }

    /// Sets a state directly (screenshot renderer and previews).
    public func show(_ s: OverlayState) {
        state = s
    }

    public func startClock() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: practice interview (S4)

    /// What the sim panel's buttons do; the sim controller sets it while an interview runs.
    public var simActions: ((SimUIAction) -> Void)?

    public func simStarting(voice: String, showCaption: Bool) {
        reducer.simStarting(voice: voice, showCaption: showCaption)
        publish()
    }

    public func simApply(_ e: SimEvent) {
        reducer.simApply(e)
        publish()
    }

    /// A button in the sim panel. The caption toggle is local; the rest goes to the sim controller.
    public func simAction(_ a: SimUIAction) {
        if a == .toggleCaption {
            reducer.simToggleCaption()
            publish()
        }
        simActions?(a)
    }

    private func publish() {
        if state != reducer.state { state = reducer.state }
    }
}

extension OverlayReducer {
    mutating func clearStatus() { setStatus(nil) }
}

/// The sim panel's controls.
public enum SimUIAction: Equatable, Sendable {
    case skip, `repeat`, end, doneAnswering, toggleCaption
}
