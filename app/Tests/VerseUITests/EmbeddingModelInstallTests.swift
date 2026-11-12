import CryptoKit
import Foundation
@testable import VerseUI
import XCTest

/// The paraphrase model download, with an injected transport: no network, a scratch folder instead of Application Support.
@MainActor
final class EmbeddingModelInstallTests: XCTestCase {
    private var dir: URL!
    private let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-embed-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func spec(sha: String? = nil, size: Int64? = nil) -> EmbeddingModelSpec {
        EmbeddingModelSpec(url: URL(string: "https://example.invalid/model.litertlm")!,
                           size: size ?? Int64(payload.count),
                           sha256: sha ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                           directory: dir.appendingPathComponent("models/embed", isDirectory: true),
                           fileName: "model.litertlm", sourceNote: "test source")
    }

    /// Writes `data` in a few pieces, reporting progress; with `hang` it then waits until cancelled.
    private final class FakeTransport: ModelDownloadTransport, @unchecked Sendable {
        let data: Data
        let hang: Bool
        let error: Error?
        private let lock = NSLock()
        private var _calls = 0
        private var _started = false
        var calls: Int { lock.withLock { _calls } }
        var started: Bool { lock.withLock { _started } }

        init(data: Data, hang: Bool = false, error: Error? = nil) {
            self.data = data
            self.hang = hang
            self.error = error
        }

        func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
            lock.withLock { _calls += 1 }
            if let error { throw error }
            let half = data.count / 2
            try data.prefix(half).write(to: file)
            progress(Int64(half), Int64(data.count))
            lock.withLock { _started = true }
            if hang {
                while true {
                    try await Task.sleep(for: .milliseconds(10))   // throws CancellationError on cancel
                }
            }
            try data.write(to: file)
            progress(Int64(data.count), Int64(data.count))
        }
    }

    private func leftovers(in spec: EmbeddingModelSpec) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: spec.directory.path)) ?? []).filter { $0.hasSuffix(".part") }
    }

    func testSuccessPutsTheVerifiedFileInPlace() async throws {
        let s = spec()
        let t = FakeTransport(data: payload)
        let installer = EmbeddingModelInstaller(spec: s, transport: t)
        XCTAssertEqual(installer.state, .missing)

        await installer.install()

        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(try Data(contentsOf: s.destination), payload)
        XCTAssertEqual(leftovers(in: s), [], "no partial file is left behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("SOURCE.txt").path))
        XCTAssertTrue(EmbeddingModelInstaller.isInstalled(s))
    }

    func testAChecksumMismatchLeavesNothingInPlace() async throws {
        let s = spec(sha: String(repeating: "0", count: 64))
        let installer = EmbeddingModelInstaller(spec: s, transport: FakeTransport(data: payload))

        await installer.install()

        XCTAssertEqual(installer.state, .failed(.checksumMismatch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.destination.path), "a file that failed its checksum is never moved into place")
        XCTAssertEqual(leftovers(in: s), [])
        installer.refresh()
        XCTAssertEqual(installer.state, .failed(.checksumMismatch), "the failure stays shown when Settings appears again")
    }

    func testAChecksumMismatchDoesNotReplaceAnIncompleteCopy() async throws {
        let s = spec(sha: String(repeating: "0", count: 64))
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data("cut off".utf8).write(to: s.destination)
        let installer = EmbeddingModelInstaller(spec: s, transport: FakeTransport(data: payload))
        XCTAssertEqual(installer.state, .damaged)

        await installer.install()

        XCTAssertEqual(installer.state, .failed(.checksumMismatch))
        XCTAssertEqual(try Data(contentsOf: s.destination), Data("cut off".utf8))
    }

    func testAShortDownloadIsASizeMismatch() async throws {
        let s = spec(size: Int64(payload.count) + 1)
        let installer = EmbeddingModelInstaller(spec: s, transport: FakeTransport(data: payload))

        await installer.install()

        XCTAssertEqual(installer.state, .failed(.sizeMismatch(got: Int64(payload.count))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.destination.path))
    }

    func testCancelStopsTheDownloadAndLeavesNothing() async throws {
        let s = spec()
        let t = FakeTransport(data: payload, hang: true)
        let installer = EmbeddingModelInstaller(spec: s, transport: t)

        installer.download()
        let deadline = Date().addingTimeInterval(5)
        while !t.started && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(t.started)
        guard case .downloading = installer.state else { return XCTFail("not downloading: \(installer.state)") }
        let running = installer.runningTask
        installer.cancel()
        XCTAssertEqual(installer.state, .missing, "the row goes back to the download button at once")
        await running?.value

        XCTAssertEqual(installer.state, .missing, "a late result of the cancelled download changes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.destination.path))
        XCTAssertEqual(leftovers(in: s), [], "the partial file is removed")
    }

    func testAlreadyInstalledDoesNotDownload() async throws {
        let s = spec()
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try payload.write(to: s.destination)
        let t = FakeTransport(data: payload)
        let installer = EmbeddingModelInstaller(spec: s, transport: t)
        XCTAssertEqual(installer.state, .installed)

        await installer.install()
        installer.download()
        await installer.runningTask?.value

        XCTAssertEqual(t.calls, 0, "nothing is fetched when the model is in place")
        XCTAssertEqual(installer.state, .installed)
    }

    func testANetworkErrorIsShownAndNothingIsLeft() async throws {
        let s = spec()
        let installer = EmbeddingModelInstaller(spec: s, transport: FakeTransport(data: payload, error: URLError(.notConnectedToInternet)))

        await installer.install()

        guard case .failed(.network) = installer.state else { return XCTFail("\(installer.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.destination.path))
        XCTAssertEqual(leftovers(in: s), [])
    }

    func testNothingStartsByItself() {
        let t = FakeTransport(data: payload)
        _ = EmbeddingModelInstaller(spec: spec(), transport: t)
        XCTAssertEqual(t.calls, 0)
    }

    /// The pinned values the brain's path and the licence notes name.
    func testTheLiveSpecIsThePinnedRevision() {
        let s = EmbeddingModelSpec.embeddingGemma
        XCTAssertEqual(s.url.absoluteString,
                       "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m.litertlm")
        XCTAssertEqual(s.size, 164_626_432)
        XCTAssertTrue(s.destination.path.hasSuffix(
            "Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/embeddinggemma-2-text-270m.litertlm"))
    }
}
