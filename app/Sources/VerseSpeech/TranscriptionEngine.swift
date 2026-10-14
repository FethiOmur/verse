@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import VerseAudio

/// One recognizer result. Times are seconds from the first sample fed to the engine.
public struct EngineResult: Sendable {
    public var text: String
    public var isFinal: Bool
    public var start: TimeInterval
    public var end: TimeInterval
}

/// A streaming speech recognizer. One instance per channel and session.
public protocol TranscriptionEngine: AnyObject, Sendable {
    var lang: String { get }
    var engineName: String { get }
    /// Loads (and if needed installs) the model and returns the audio format to feed.
    func prepare() async throws -> AVAudioFormat
    /// Starts analysis of `input`; results are delivered to `onResult` as they arrive.
    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws
    /// Call after finishing the input stream: flushes the last results and waits for them.
    func finish() async throws
    /// Stops at once, dropping pending results.
    func cancel() async
}

public enum EngineKind: String, Sendable, Codable {
    /// `SpeechTranscriber` with `.fastResults` (en, it).
    case speechTranscriber
    /// `DictationTranscriber` with `.frequentFinalization` (tr; SpeechTranscriber has no tr_TR on this Mac).
    case dictationTranscriber
    /// Slot for a later WhisperKit engine (not on disk; see bench/whisper/RESULTS_whisper.md).
    case whisperKit
}

public enum EngineFactory {
    public static func locale(for lang: String) -> Locale {
        switch lang {
        case "en": return Locale(identifier: "en_US")
        case "it": return Locale(identifier: "it_IT")
        case "tr": return Locale(identifier: "tr_TR")
        default: return Locale(identifier: lang)
        }
    }

    /// Decided routing (plan P1-3): en/it -> SpeechTranscriber+fastResults, tr -> DictationTranscriber+frequentFinalization.
    public static func defaultKind(for lang: String) -> EngineKind {
        lang == "tr" ? .dictationTranscriber : .speechTranscriber
    }

    public static func make(lang: String, kind: EngineKind? = nil) throws -> TranscriptionEngine {
        switch kind ?? defaultKind(for: lang) {
        case .speechTranscriber: return AppleSpeechEngine(lang: lang, kind: .speech)
        case .dictationTranscriber: return AppleSpeechEngine(lang: lang, kind: .dictation)
        case .whisperKit: throw ListenError.speechUnavailable(lang: lang, reason: "WhisperKit engine not built yet (model not on disk)")
        }
    }
}

/// SpeechAnalyzer with one module (SpeechTranscriber or DictationTranscriber), configured as measured in P0-B.
final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    enum Kind { case speech, dictation }

    let lang: String
    let kind: Kind
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Error>?
    private var startResults: ((@escaping @Sendable (EngineResult) -> Void) -> Task<Void, Error>)?

    init(lang: String, kind: Kind) {
        self.lang = lang
        self.kind = kind
    }

    var engineName: String {
        kind == .speech ? "SpeechTranscriber+fastResults" : "DictationTranscriber+frequentFinalization"
    }

    func prepare() async throws -> AVAudioFormat {
        let locale = EngineFactory.locale(for: lang)
        let module: any SpeechModule
        switch kind {
        case .speech:
            let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            guard supported.contains(locale.identifier(.bcp47)) else {
                throw ListenError.speechUnavailable(lang: lang, reason: "SpeechTranscriber does not support \(locale.identifier)")
            }
            let m = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults, .fastResults],
                                      attributeOptions: [.audioTimeRange])
            module = m
            startResults = { onResult in
                Task { for try await r in m.results { onResult(Self.map(r.text, r.range, r.isFinal)) } }
            }
        case .dictation:
            let supported = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            guard supported.contains(locale.identifier(.bcp47)) else {
                throw ListenError.speechUnavailable(lang: lang, reason: "DictationTranscriber does not support \(locale.identifier)")
            }
            let m = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults, .frequentFinalization],
                                         attributeOptions: [.audioTimeRange])
            module = m
            startResults = { onResult in
                Task { for try await r in m.results { onResult(Self.map(r.text, r.range, r.isFinal)) } }
            }
        }
        // Installs the model if it is missing (a background download, no UI). en_US, it_IT and the tr_TR
        // dictation model are already installed on the owner's Mac (P0-B).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ListenError.speechUnavailable(lang: lang, reason: "bestAvailableAudioFormat returned nil")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        return format
    }

    private static func map(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) -> EngineResult {
        EngineResult(text: String(text.characters), isFinal: isFinal,
                     start: range.start.seconds.isFinite ? range.start.seconds : 0,
                     end: range.end.seconds.isFinite ? range.end.seconds : 0)
    }

    func start(input: AsyncStream<AnalyzerInput>, onResult: @escaping @Sendable (EngineResult) -> Void) async throws {
        guard let analyzer, let startResults else {
            throw ListenError.speechUnavailable(lang: lang, reason: "engine not prepared")
        }
        resultsTask = startResults(onResult)
        try await analyzer.start(inputSequence: input)
    }

    func finish() async throws {
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try await resultsTask?.value
    }

    func cancel() async {
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }
}
