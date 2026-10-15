import Foundation
import VersePrompter
import VerseSpeech

/// The meeting's mic channel, handed to the prompter. The runner's `ListenSession` already transcribes both channels;
/// `VerseRunner` passes every event to `RunOptions.transcriptTap`, and this keeps only what he said (`Channel.me`). The
/// prompter wraps `stream()` in an `ExternalTranscriptSource`, so it never opens a second microphone session and the
/// remote audio can never move the script.
public final class MeetingMicTap: Sendable {
    private let broadcaster = TranscriptBroadcaster()

    public init() {}

    /// Called from the runner's thread for every event of both channels.
    public func ingest(_ event: TranscriptEvent) {
        guard event.channel == .me else { return }
        broadcaster.yield(event)
    }

    /// A new subscription: events from now on.
    public func stream() -> AsyncStream<TranscriptEvent> { broadcaster.subscribe() }

    /// The meeting ended: every subscriber's stream ends.
    public func finish() { broadcaster.finish() }
}
