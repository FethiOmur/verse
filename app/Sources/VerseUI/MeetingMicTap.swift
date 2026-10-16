import Foundation
import VersePrompter
import VerseSpeech

/// The meeting's mic channel, handed to the prompter. The runner's `ListenSession` already transcribes both channels;
/// `VerseRunner` passes every event to `RunOptions.transcriptTap`, and this keeps only what he said (`Channel.me`). The
/// prompter wraps `stream()` in an `ExternalTranscriptSource`, so it never opens a second microphone session and the
/// remote audio can never move the script.
///
/// `cardStream()` is the card's own feed (`CardReading`): every event, so the room route (one microphone, no `me` channel,
/// its events arrive as `remote`) can still move the spoken/unspoken split of the card. The prompter never sees it.
public final class MeetingMicTap: Sendable {
    private let broadcaster = TranscriptBroadcaster()
    private let cardBroadcaster = TranscriptBroadcaster()

    public init() {}

    /// Called from the runner's thread for every event of both channels.
    public func ingest(_ event: TranscriptEvent) {
        cardBroadcaster.yield(event)
        guard event.channel == .me else { return }
        broadcaster.yield(event)
    }

    /// Every event of both channels, for `CardReading` (which decides by route which channels count).
    public func cardStream() -> AsyncStream<TranscriptEvent> { cardBroadcaster.subscribe() }

    /// A new subscription: events from now on.
    public func stream() -> AsyncStream<TranscriptEvent> { broadcaster.subscribe() }

    /// The meeting ended: every subscriber's stream ends.
    public func finish() {
        broadcaster.finish()
        cardBroadcaster.finish()
    }
}
