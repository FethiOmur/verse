import Foundation
@_exported import VerseAudio

/// A status line about the speech engines (not a transcript event, not an error). One JSON object per line
/// when written out, in the same shape `verse-listen` uses for its own status lines on stderr:
/// `{"type":"status","state":"engine_switch",...}`.
///
/// States: `engine_ready` (the local model finished loading), `engine_switch` (a channel moved from the Apple
/// engine to the local one at a turn boundary), `engine_fallback` (the local engine is not used: model folder
/// missing or load failed; the Apple engine keeps running).
public struct ListenStatus: Sendable, Codable, Equatable {
    public var type: String = "status"
    public var state: String
    public var channel: Channel?
    /// Engine that is active after this event.
    public var engine: String?
    /// Engine that was active before (`engine_switch`).
    public var from: String?
    public var reason: String?
    /// Seconds the model needed to load.
    public var loadSec: Double?
    /// Audio-timeline seconds (since this channel's first sample) at which the model was seen ready.
    public var readyAtSec: Double?
    /// Audio-timeline seconds at which the channel switched.
    public var switchAtSec: Double?
    /// `switchAtSec - readyAtSec`: how long the switch waited for a turn boundary.
    public var waitedSec: Double?

    public init(state: String, channel: Channel? = nil, engine: String? = nil, from: String? = nil, reason: String? = nil,
                loadSec: Double? = nil, readyAtSec: Double? = nil, switchAtSec: Double? = nil, waitedSec: Double? = nil) {
        self.state = state
        self.channel = channel
        self.engine = engine
        self.from = from
        self.reason = reason
        self.loadSec = loadSec
        self.readyAtSec = readyAtSec
        self.switchAtSec = switchAtSec
        self.waitedSec = waitedSec
    }

    /// One JSON line (sorted keys, numbers rounded to ms), no trailing newline.
    public var jsonLine: String {
        var s = self
        func r3(_ x: Double?) -> Double? { x.map { ($0 * 1000).rounded() / 1000 } }
        s.loadSec = r3(loadSec); s.readyAtSec = r3(readyAtSec); s.switchAtSec = r3(switchAtSec); s.waitedSec = r3(waitedSec)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"type\":\"status\",\"state\":\"\(state)\"}"
    }

    /// Default sink: the CLI contract (status lines on stderr as JSON lines).
    public static let writeToStderr: @Sendable (ListenStatus) -> Void = { status in
        FileHandle.standardError.write(Data((status.jsonLine + "\n").utf8))
    }
}
