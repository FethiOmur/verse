@testable import VerseSpeech
import Speech
import XCTest

/// The session's names reach the Apple engines as the analyzer's contextual strings (`ListenConfig.contextualStrings`).
/// No audio: what is checked is the plumbing; whether an engine uses them was measured separately (see `ListenConfig`).
final class ContextualStringsTests: XCTestCase {
    private let names = ["Lantern", "Halden Freight Systems", "ETA drift"]

    func testTheFactoryGivesTheNamesToEveryAppleEngine() throws {
        for (lang, kind) in [("it", EngineKind?.none), ("tr", nil), ("en", .speechTranscriber), ("it", .dictationTranscriber)] {
            var cfg = ListenConfig(lang: lang, micEnabled: false, source: .live)
            cfg.engineKind = kind
            cfg.contextualStrings = names
            let engine = try EngineFactory.make(config: cfg)
            let apple = try XCTUnwrap(engine as? AppleSpeechEngine, "\(lang) \(String(describing: kind))")
            XCTAssertEqual(apple.contextualStrings, names)
        }
    }

    func testTheContextHoldsTheNamesUnderGeneral() throws {
        XCTAssertNil(AppleSpeechEngine.context(for: []), "no names: the analyzer keeps its default context")
        XCTAssertNil(AppleSpeechEngine.context(for: ["  "]))
        let ctx = try XCTUnwrap(AppleSpeechEngine.context(for: names))
        XCTAssertEqual(ctx.contextualStrings[.general], names)
    }
}
