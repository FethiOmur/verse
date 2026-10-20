import Foundation
import XCTest

/// Spec 2.5 "Lint": a user-visible literal in VerseUI or VerseApp goes through the module bundle. SwiftUI's `Text("…")`,
/// `Button("…")`, `Label("…")`, `Toggle("…")`, `.help("…")`, `confirmationDialog("…")` and `alert("…")` look the literal up in the
/// *main* bundle, where Verse's catalog is not, so the text would stay English. This test reads the sources and fails on such a
/// literal. A line that carries `// l10n:verbatim` is exempt (a literal that is not text for a reader).
final class LocalizationLintTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// `Text("x"`, `.help("x"` …, with a non-empty literal. `HomeText(` is a different call (its argument is a `LocalizedStringKey`).
    private static let call = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z_.])(Text|Button|Label|Toggle|Picker|Menu|Section|LabeledContent|Stepper|Link)\("[^"]"#
            + #"|\.(help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle|confirmationDialog|alert)\("[^"]"#)

    private func swiftFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    func testNoUserVisibleLiteralBypassesTheModuleBundle() throws {
        var offenders: [String] = []
        var scanned = 0
        for dir in ["VerseUI", "VerseApp"] {
            for file in swiftFiles(in: sources.appendingPathComponent(dir)) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    scanned += 1
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || line.contains("// l10n:verbatim") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    guard Self.call.firstMatch(in: line, range: range) != nil else { continue }
                    // `bundle:` anywhere on the line means the module (or `L10n.bundle`) is named.
                    if line.contains("bundle:") { continue }
                    offenders.append("\(file.lastPathComponent):\(i + 1): \(trimmed.prefix(110))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10_000, "the lint found the sources")
        XCTAssertEqual(offenders, [], "a literal that skips the module bundle stays English. Use Text(\"…\", bundle: .module), a Home* component, L10n.tr, or mark the line // l10n:verbatim")
    }

    func testTheLintCatchesAnUnlocalizedLiteral() {
        func hits(_ s: String) -> Bool { Self.call.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(hits(#"Text("Hello")"#))
        XCTAssertTrue(hits(#"Button("Save") { go() }"#))
        XCTAssertTrue(hits(#"Label("Used", systemImage: "checkmark")"#))
        XCTAssertTrue(hits(#"Toggle("On", isOn: $x)"#))
        XCTAssertTrue(hits(#".help("More")"#))
        XCTAssertTrue(hits(#".confirmationDialog("Remove?", isPresented: $x)"#))
        XCTAssertTrue(hits(#".alert("Oops", isPresented: $x)"#))
        XCTAssertFalse(hits(#"HomeText("Calls read it")"#), "a Home component takes a LocalizedStringKey")
        XCTAssertFalse(hits(#"Text(verbatim: "Hello")"#))
        XCTAssertFalse(hits(#"Button("") { go() }"#), "an empty label is not text")
    }
}
