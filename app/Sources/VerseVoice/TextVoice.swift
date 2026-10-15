import Foundation

/// No audio. The interviewer's line is shown in the overlay by the app; `speak` returns at once.
public struct TextVoice: VoiceEngine {
    public var kind: VoiceKind { .text }
    public init() {}
    public func speak(_ sentence: String) async throws {}
    public func stop() async {}
}
