import Foundation

/// Something that delivers mono audio chunks in real time: a process tap, the mic, or an in-memory clip.
/// `onChunk` may be called on a real-time audio thread: handlers must only copy and hand off.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Human-readable route, e.g. "process tap (bundle ID)" or "memory clip".
    var routeDescription: String { get }

    /// Starts delivery. `onEnd` is called once when a finite source (file, memory) has delivered everything.
    func start(clock: SessionClock,
               onChunk: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable () -> Void) throws

    func stop()

    /// Whether the captured app is currently producing output. `nil` when the question does not apply
    /// (mic, memory clip). Used to tell real silence from a dead stream.
    func targetIsProducingOutput() -> Bool?
}
