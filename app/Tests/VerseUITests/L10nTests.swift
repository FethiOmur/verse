import Foundation
@testable import VerseUI
import XCTest

/// Interface-language groundwork (spec 2.5, package L0): the module bundle carries the compiled catalog, `L10n.tr` selects the
/// language, "System" resolves against the preferred languages, `TextFold` folds the Turkish i's and accents, and
/// `l10n-sync.sh` adds new keys to a catalog.
@MainActor
final class L10nTests: XCTestCase {
    private func settingsDefaults() -> UserDefaults {
        let name = "verse-l10n-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Catalog and lookup

    func testTheCompiledCatalogIsInTheModuleBundle() {
        for lang in ["it", "tr"] {
            XCTAssertNotNil(L10n.bundle.path(forResource: lang, ofType: "lproj"), "\(lang).lproj is compiled into the VerseUI resource bundle")
        }
    }

    func testTrSelectsTheLanguage() {
        XCTAssertEqual(L10n.tr("Sessions", locale: Locale(identifier: "en")), "Sessions")
        XCTAssertEqual(L10n.tr("Sessions", locale: Locale(identifier: "it")), "Sessioni")
        XCTAssertEqual(L10n.tr("Sessions", locale: Locale(identifier: "tr")), "Oturumlar")
    }

    func testTrFollowsTheCurrentLanguage() {
        defer { L10nState.shared.apply(.en) }
        L10nState.shared.apply(.it)
        XCTAssertEqual(L10n.code, "it")
        XCTAssertEqual(L10n.tr("Sessions"), "Sessioni")
        L10nState.shared.apply(.tr)
        XCTAssertEqual(L10n.tr("Sessions"), "Oturumlar", "the switch needs no relaunch")
        L10nState.shared.apply(.en)
        XCTAssertEqual(L10n.tr("Sessions"), "Sessions")
    }

    func testFormatLocalesKeepTwentyFourHourEnglish() {
        XCTAssertEqual(L10n.formatLocale(for: "en").identifier, "en_GB")
        XCTAssertEqual(L10n.formatLocale(for: "it").identifier, "it_IT")
        XCTAssertEqual(L10n.formatLocale(for: "tr").identifier, "tr_TR")
        XCTAssertEqual(L10n.formatLocale(for: "xx").identifier, "en_GB", "an unknown code falls back to English")
    }

    // MARK: "System"

    func testSystemResolvesToTheFirstSupportedPreferredLanguage() {
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: ["tr-TR", "it-IT"]), "tr")
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: ["de-DE", "it-IT", "tr-TR"]), "it", "unsupported languages are skipped")
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: ["en-US", "tr-TR"]), "en")
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: ["it_IT"]), "it", "underscore identifiers resolve too")
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: ["zh-Hans-CN"]), "en", "no supported language: English")
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferred: []), "en")
    }

    func testAPinnedLanguageIgnoresThePreferredList() {
        XCTAssertEqual(InterfaceLanguage.en.resolved(preferred: ["tr-TR"]), "en")
        XCTAssertEqual(InterfaceLanguage.it.resolved(preferred: ["tr-TR"]), "it")
        XCTAssertEqual(InterfaceLanguage.tr.resolved(preferred: ["en-US"]), "tr")
    }

    func testPickerNamesAreEndonyms() {
        XCTAssertNil(InterfaceLanguage.system.endonym, "the System row is built from the resolved name")
        XCTAssertEqual(InterfaceLanguage.en.endonym, "English")
        XCTAssertEqual(InterfaceLanguage.it.endonym, "Italiano")
        XCTAssertEqual(InterfaceLanguage.tr.endonym, "Türkçe")
    }

    func testStateAppliesWithInjectedPreferences() {
        let state = L10nState()
        defer { L10nState.shared.apply(.en) }
        state.apply(.system, preferred: ["it-IT", "en-US"])
        XCTAssertEqual(state.language, .system)
        XCTAssertEqual(state.code, "it")
        XCTAssertEqual(state.locale.identifier, "it")
        state.apply(.tr, preferred: ["it-IT"])
        XCTAssertEqual(state.code, "tr")
    }

    // MARK: Setting

    func testInterfaceLanguageDefaultsToSystemAndPersists() {
        defer { L10nState.shared.apply(.en) }
        let d = settingsDefaults()
        let first = AppSettings(defaults: d)
        XCTAssertEqual(first.interfaceLanguage, .system, "the default follows macOS")
        first.interfaceLanguage = .it
        XCTAssertEqual(d.string(forKey: "interfaceLanguage"), "it")
        XCTAssertEqual(L10n.code, "it", "the setting drives the live language")
        XCTAssertEqual(AppSettings(defaults: d).interfaceLanguage, .it)
        d.set("klingon", forKey: "interfaceLanguage")
        XCTAssertEqual(AppSettings(defaults: d).interfaceLanguage, .system, "an unknown stored value falls back to System")
    }

    // MARK: TextFold

    func testFoldIgnoresCaseAndTurkishDots() {
        XCTAssertEqual(TextFold.fold("İstanbul"), TextFold.fold("istanbul"))
        XCTAssertEqual(TextFold.fold("İstanbul"), "istanbul")
        XCTAssertEqual(TextFold.fold("ISPARTA"), TextFold.fold("ısparta"), "dotless ı folds to i")
        XCTAssertEqual(TextFold.fold("Çalışma"), "calisma")
    }

    func testFoldStripsAccents() {
        XCTAssertEqual(TextFold.fold("perché"), TextFold.fold("perche"))
        XCTAssertEqual(TextFold.fold("Città"), "citta")
        XCTAssertEqual(TextFold.fold("Güneş Öğle"), "gunes ogle")
        XCTAssertEqual(TextFold.fold("plain ascii 123"), "plain ascii 123")
    }

    // MARK: Sync script

    func testSyncScriptAddsANewKeyFromASourceFile() throws {
        let fm = FileManager.default
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = appDir.appendingPathComponent("scripts/l10n-sync.sh")
        let realCatalog = appDir.appendingPathComponent("Sources/VerseUI/Resources/Localizable.xcstrings")
        try XCTSkipUnless(fm.isExecutableFile(atPath: script.path), "l10n-sync.sh not found next to the tests")

        // A temp copy of the catalog (named Localizable.xcstrings: the table comes from the file name) and one source file
        // that uses a key the catalog has never seen. swiftc writes the .stringsdata a package build would write.
        let tmp = fm.temporaryDirectory.appendingPathComponent("verse-l10n-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let buildDir = tmp.appendingPathComponent("build/VerseUI-t.build/Objects", isDirectory: true)
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let catalog = tmp.appendingPathComponent("Localizable.xcstrings")
        try fm.copyItem(at: realCatalog, to: catalog)

        let source = tmp.appendingPathComponent("Probe.swift")
        try """
        import SwiftUI
        struct L10nSyncProbe: View { var body: some View { Text("A brand new key from the sync test", bundle: .main) } }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-c", "-o", tmp.appendingPathComponent("Probe.o").path,
                                                "-emit-localized-strings", "-emit-localized-strings-path", buildDir.path, source.path])
        XCTAssertEqual(compile.status, 0, compile.output)

        func keys() throws -> Set<String> {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
            return Set((json?["strings"] as? [String: Any] ?? [:]).keys)
        }
        XCTAssertFalse(try keys().contains("A brand new key from the sync test"))

        let sync = try run(script.path, [], environment: [
            "L10N_CATALOG": catalog.path, "L10N_BUILD_DIR": tmp.appendingPathComponent("build").path, "L10N_SKIP_BUILD": "1",
        ])
        XCTAssertEqual(sync.status, 0, sync.output)
        XCTAssertTrue(try keys().contains("A brand new key from the sync test"), "the key was added to the catalog")
        // The repository's own catalog was not touched.
        XCTAssertFalse(try String(contentsOf: realCatalog, encoding: .utf8).contains("A brand new key from the sync test"))
    }

    private func run(_ path: String, _ args: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
