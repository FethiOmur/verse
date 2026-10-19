import Foundation

/// One sentence that the primary voice could not speak and the fallback voice spoke instead.
/// The app shows a small chip for it. `error` never contains a key (see `VoiceError`).
public struct FallbackEvent: Sendable, Equatable {
    public let primary: VoiceKind
    public let error: VoiceError
    public init(primary: VoiceKind, error: VoiceError) { self.primary = primary; self.error = error }
}

/// Thread-safe list of the fallbacks that happened (a struct engine cannot hold mutable state itself).
public final class FallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [FallbackEvent] = []
    public init() {}
    public var events: [FallbackEvent] { lock.lock(); defer { lock.unlock() }; return list }
    func record(_ e: FallbackEvent) { lock.lock(); list.append(e); lock.unlock() }
}

/// Tries the primary voice for every sentence; when it throws, that sentence is spoken by the fallback (Apple voice by
/// default) and the fallback is recorded and reported. The primary is tried again on the next sentence. The sim never
/// stops for a voice error: only a failure of the fallback itself is rethrown. Cancellation is never a fallback reason.
public struct FallbackVoice: VoiceEngine {
    public let primary: any VoiceEngine
    public let fallback: any VoiceEngine
    public let recorder = FallbackRecorder()
    private let onFallback: (@Sendable (FallbackEvent) -> Void)?

    /// The kind the user chose (the primary's), not the one that spoke last.
    public var kind: VoiceKind { primary.kind }

    public init(primary: any VoiceEngine, fallback: any VoiceEngine = AppleVoice(),
                onFallback: (@Sendable (FallbackEvent) -> Void)? = nil) {
        self.primary = primary
        self.fallback = fallback
        self.onFallback = onFallback
    }

    public func speak(_ sentence: String) async throws {
        do {
            try await primary.speak(sentence)
        } catch let e as CancellationError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let event = FallbackEvent(primary: primary.kind, error: .wrapping(error))
            recorder.record(event)
            onFallback?(event)
            try await fallback.speak(sentence)
        }
    }

    /// Synthesis falls back to the fallback voice (Apple: `.live`) when the primary cannot prepare the sentence.
    public func synthesize(_ sentence: String) async throws -> SynthesizedSpeech {
        do {
            return try await primary.synthesize(sentence)
        } catch let e as CancellationError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            noteFallback(error)
            return try await fallback.synthesize(sentence)
        }
    }

    /// Plays on the engine that made it; a primary that fails while playing hands the sentence to the fallback.
    public func play(_ speech: SynthesizedSpeech) async throws {
        if speech.engine != primary.kind {
            try await fallback.play(speech)
            return
        }
        do {
            try await primary.play(speech)
        } catch let e as CancellationError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            noteFallback(error)
            try await fallback.speak(speech.text)
        }
    }

    private func noteFallback(_ error: any Error) {
        let event = FallbackEvent(primary: primary.kind, error: .wrapping(error))
        recorder.record(event)
        onFallback?(event)
    }

    public func stop() async {
        await primary.stop()
        await fallback.stop()
    }
}
