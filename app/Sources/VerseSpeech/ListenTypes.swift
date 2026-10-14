import Foundation
@_exported import VerseAudio

/// One transcript update. Volatile events (`isFinal == false`) replace the earlier volatile text of the same
/// audio range; final events are settled text.
/// Times are session seconds (since `ListenSession.start()`): `audioStart`/`audioEnd` locate the words in the audio,
/// `emittedAt` is when the event left the recognizer.
public struct TranscriptEvent: Sendable, Codable, Equatable {
    public var channel: Channel
    public var text: String
    public var isFinal: Bool
    public var audioStart: TimeInterval
    public var audioEnd: TimeInterval
    public var emittedAt: TimeInterval
    public var lang: String

    public init(channel: Channel, text: String, isFinal: Bool, audioStart: TimeInterval, audioEnd: TimeInterval,
                emittedAt: TimeInterval, lang: String) {
        self.channel = channel
        self.text = text
        self.isFinal = isFinal
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.emittedAt = emittedAt
        self.lang = lang
    }
}

public struct ListenConfig: Sendable {
    public enum Source: Sendable {
        /// Process tap on the meeting app + the default microphone.
        case live
        /// Tests and the replay harness only: the file plays as the remote channel at real-time pace.
        case file(URL)
        /// Tests and the replay harness only: in-memory clips for either channel, played at real-time pace.
        case memory(remote: PCMClip?, me: PCMClip?)
    }

    /// "en", "it" or "tr".
    public var lang: String
    public var remoteBundleIDs: [String]
    public var micEnabled: Bool
    public var source: Source
    /// Bundle-ID tap first, PID-list tap as the fallback.
    public var tapRoute: TapRoutePreference = .auto
    /// Off: voice processing ducks the meeting audio (>= 8 dB even at the minimum level, measured).
    public var voiceProcessing: Bool = false
    /// Silence appended after a file or memory clip so the recognizer settles, as it would in a live call.
    public var clipTailSeconds: TimeInterval = 2.0
    public var bleedGate = BleedGate()
    /// Engine override. Default (nil): `EngineFactory.sessionDefaultKind(for: lang)`, i.e. `.auto` for English
    /// (Nemotron once loaded, Apple until then and as the fallback), the Apple engine for it/tr.
    public var engineKind: EngineKind? = nil
    /// Folder with the Nemotron model files (never downloaded; see `NemotronModel`).
    public var nemotronModelDir: URL = NemotronModel.defaultDirectory
    /// Where engine status lines go (`engine_ready`, `engine_switch`, `engine_fallback`). Default: stderr as JSON
    /// lines, the same channel `verse-listen` uses for its own status lines. nil: dropped.
    public var statusSink: (@Sendable (ListenStatus) -> Void)? = ListenStatus.writeToStderr

    public init(lang: String, remoteBundleIDs: [String] = defaultRemoteBundleIDs, micEnabled: Bool = true,
                source: Source = .live) {
        self.lang = lang
        self.remoteBundleIDs = remoteBundleIDs
        self.micEnabled = micEnabled
        self.source = source
    }

    var isLive: Bool { if case .live = source { return true } else { return false } }
}

/// What a session is built from. `system` is the real thing; tests swap parts (permissions, sources).
public struct ListenEnvironment: Sendable {
    public var permissions: any PermissionChecking
    public var makeRemoteSource: @Sendable (ListenConfig) throws -> (any AudioCaptureSource)?
    public var makeMicSource: @Sendable (ListenConfig) throws -> (any AudioCaptureSource)?
    public var makeEngine: @Sendable (ListenConfig) throws -> any TranscriptionEngine

    public init(permissions: any PermissionChecking,
                makeRemoteSource: @escaping @Sendable (ListenConfig) throws -> (any AudioCaptureSource)?,
                makeMicSource: @escaping @Sendable (ListenConfig) throws -> (any AudioCaptureSource)?,
                makeEngine: @escaping @Sendable (ListenConfig) throws -> any TranscriptionEngine) {
        self.permissions = permissions
        self.makeRemoteSource = makeRemoteSource
        self.makeMicSource = makeMicSource
        self.makeEngine = makeEngine
    }

    public static let system = ListenEnvironment(
        permissions: SystemPermissions(),
        makeRemoteSource: { cfg in
            switch cfg.source {
            case .live:
                return ProcessTapSource(bundleIDs: cfg.remoteBundleIDs, preference: cfg.tapRoute)
            case .file(let url):
                return MemorySource(clip: try PCMClip.read(url), tailSeconds: cfg.clipTailSeconds, name: "file \(url.lastPathComponent)")
            case .memory(let remote, _):
                return remote.map { MemorySource(clip: $0, tailSeconds: cfg.clipTailSeconds, name: "memory remote") }
            }
        },
        makeMicSource: { cfg in
            switch cfg.source {
            case .live:
                return cfg.micEnabled ? MicSource(voiceProcessing: cfg.voiceProcessing) : nil
            case .file:
                return nil
            case .memory(_, let me):
                return me.map { MemorySource(clip: $0, tailSeconds: cfg.clipTailSeconds, name: "memory mic") }
            }
        },
        makeEngine: { cfg in try EngineFactory.make(config: cfg) })
}
