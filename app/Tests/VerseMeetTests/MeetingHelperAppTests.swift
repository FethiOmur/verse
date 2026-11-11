import EventKit
import Foundation
import XCTest
@testable import VerseMeet

/// S6: a WebKit helper counts as Safari only when Safari is the app it works for. S9: the EventKit store is rebuilt when
/// the authorization changes.
final class MeetingHelperAppTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func signals(_ procs: [AudioProcessInfo]) async -> [MeetingSignal] {
        let table = FakeProcessTable()
        table.set(procs)
        let d = MeetingDetector(table: table)
        var out: [MeetingSignal] = []
        for s in 0...5 { out += await d.tick(at: t0.addingTimeInterval(Double(s))) }
        return out
    }

    func testAWebKitHelperRecordingForMailIsNotSafari() async {
        // Mail (or any app with a web view) has its own com.apple.WebKit.GPU.
        let sigs = await signals([AudioProcessInfo(bundleID: "com.apple.WebKit.GPU", pid: 40, isRunningInput: true,
                                                   responsibleBundleID: "com.apple.mail")])
        XCTAssertTrue(sigs.isEmpty, "\(sigs)")
    }

    func testAWebKitHelperWithUnknownOwnerIsNotSafari() async {
        let sigs = await signals([AudioProcessInfo(bundleID: "com.apple.WebKit.WebContent", pid: 41, isRunningInput: true)])
        XCTAssertTrue(sigs.isEmpty, "\(sigs)")
    }

    func testAWebKitHelperRecordingForSafariIsSafari() async {
        let sigs = await signals([AudioProcessInfo(bundleID: "com.apple.WebKit.GPU", pid: 42, isRunningInput: true,
                                                   responsibleBundleID: "com.apple.Safari")])
        XCTAssertEqual(sigs.count, 1)
        guard case .started(let info)? = sigs.first else { return XCTFail("expected started") }
        XCTAssertEqual(info.appName, "Safari")
        XCTAssertEqual(info.bundleID, "com.apple.Safari", "reported as the app, not the helper")
    }

    func testOnlyHelpersAreLookedUp() {
        XCTAssertTrue(MeetingApp.isSharedHelper("com.apple.WebKit.GPU"))
        XCTAssertTrue(MeetingApp.isSharedHelper("com.apple.WebKit.WebContent"))
        XCTAssertFalse(MeetingApp.isSharedHelper("com.apple.Safari"))
        XCTAssertFalse(MeetingApp.isSharedHelper("com.google.Chrome.helper"))
        XCTAssertFalse(MeetingApp.isSharedHelper(nil))
    }

    func testTheOutermostAppOnAPathNamesTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verse-helper-\(UUID().uuidString)")
        func app(_ url: URL, id: String) throws {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "x", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        let outer = root.appendingPathComponent("Outer.app")
        try app(outer, id: "test.outer")
        try app(outer.appendingPathComponent("Contents/Helpers/Inner.app"), id: "test.inner")
        XCTAssertEqual(ResponsibleApp.bundleID(forExecutablePath: outer.path + "/Contents/Helpers/Inner.app/Contents/MacOS/x"), "test.outer")
        XCTAssertEqual(ResponsibleApp.bundleID(forExecutablePath: outer.path + "/Contents/MacOS/x"), "test.outer")
        XCTAssertNil(ResponsibleApp.bundleID(forExecutablePath: "/bin/sleep"))
    }

    func testAChildIsChargedToTheSameAppAsItsParent() throws {
        // A child process is charged to the app responsible for the test runner (the terminal or tool that started it,
        // or none), as a WebKit helper is charged to the app whose web view it serves.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        defer { p.terminate() }
        XCTAssertEqual(ResponsibleApp.bundleID(for: p.processIdentifier), ResponsibleApp.bundleID(for: getpid()))
        XCTAssertNil(ResponsibleApp.bundleID(for: 0))
    }

    // MARK: S9

    func testTheEventStoreIsRebuiltWhenAccessChanges() {
        final class Status: @unchecked Sendable { var value: EKAuthorizationStatus = .notDetermined }
        final class Count: @unchecked Sendable { var made = 0 }
        let status = Status(), count = Count()
        // No access is requested here: the store is only created.
        let backend = EventKitBackend(status: { status.value }, makeStore: { count.made += 1; return EKEventStore() })
        let first = backend.currentStore()
        XCTAssertTrue(first === backend.currentStore(), "kept while the status stays")
        XCTAssertEqual(count.made, 1)
        status.value = .fullAccess   // granted later, in System Settings or through another store
        let second = backend.currentStore()
        XCTAssertFalse(first === second, "a store made before access was granted is replaced")
        XCTAssertTrue(second === backend.currentStore())
        XCTAssertEqual(count.made, 2)
    }
}
