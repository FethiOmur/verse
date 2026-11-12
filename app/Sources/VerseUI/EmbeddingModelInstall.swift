import CryptoKit
import Foundation
import SwiftUI

// The paraphrase matcher's model (EmbeddingGemma 2 text 270M, LiteRT-LM). The brain uses it when the file is in place and
// silently goes without it when it is not, which is how it went unused for a week. Settings shows whether it is installed and,
// only when the owner clicks, downloads it: pinned revision, size and SHA-256 checked before the file is moved into place.
// Nothing here runs on its own.

/// Where the model comes from and where the brain looks for it (`brain/verse_brain/runtime/settings.py`, `embed_model`).
struct EmbeddingModelSpec: Sendable, Equatable {
    var url: URL
    var size: Int64
    /// Lowercase hex.
    var sha256: String
    var directory: URL
    var fileName: String
    /// Written next to the model when none is there: where it came from and its licence.
    var sourceNote: String

    var destination: URL { directory.appendingPathComponent(fileName) }

    static let revision = "9be6e8b90982095dc05c2bd162e4b954ee4dbac7"
    static let repo = "litert-community/embeddinggemma-2-text-270m-litert-lm"

    static let embeddingGemma = EmbeddingModelSpec(
        url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/embeddinggemma-2-text-270m.litertlm")!,
        size: 164_626_432,
        sha256: "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb",
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert", isDirectory: true),
        fileName: "embeddinggemma-2-text-270m.litertlm",
        sourceNote: """
        Downloaded by Verse (Settings › Listening) on the owner's request.
        Source: https://huggingface.co/\(repo) at revision \(revision)
        File: embeddinggemma-2-text-270m.litertlm, 164626432 bytes,
        SHA-256 2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb
        Licence: Apache-2.0 (the conversion and its base model google/embeddinggemma-2).
        """)
}

/// Fetches a URL into a file. Injected so tests never use the network.
protocol ModelDownloadTransport: Sendable {
    /// Downloads `url` into `file` (created or replaced). `progress` gets the bytes received so far and the expected total when
    /// the server says it. Throws `CancellationError` when the calling task is cancelled.
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

/// The live transport: one URLSession download task, cancelled with the calling task.
struct URLSessionModelTransport: ModelDownloadTransport {
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let delegate = DownloadDelegate(file: file, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(c)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let file: URL
        private let progress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?

        init(file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.file = file
            self.progress = progress
        }

        func setContinuation(_ c: CheckedContinuation<Void, Error>) { lock.withLock { continuation = c } }

        private func finish(_ result: Result<Void, Error>) {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in let c = continuation; continuation = nil; return c }
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The system deletes `location` when this returns: move it now.
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lock.withLock { moveError = EmbeddingModelInstaller.Failure.network(L10n.tr("The server answered \(http.statusCode).")) }
                return
            }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                try fm.moveItem(at: location, to: file)
            } catch {
                lock.withLock { moveError = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let e = error as? URLError, e.code == .cancelled { return finish(.failure(CancellationError())) }
            if let error { return finish(.failure(error)) }
            if let e = lock.withLock({ moveError }) { return finish(.failure(e)) }
            finish(.success(()))
        }
    }
}

/// The model's install state for Settings, and the download the owner starts there.
@MainActor
final class EmbeddingModelInstaller: ObservableObject {
    enum Failure: Error, Equatable {
        /// No connection, a refused request, a server error. The text is the system's or the status line.
        case network(String)
        /// The download finished with the wrong number of bytes.
        case sizeMismatch(got: Int64)
        case checksumMismatch
        /// The file could not be written or moved into place.
        case disk(String)

        var message: String {
            switch self {
            case .network(let why): L10n.tr("The download failed: \(why)")
            case .sizeMismatch: L10n.tr("The downloaded file has the wrong size, so it was discarded. Try again.")
            case .checksumMismatch: L10n.tr("The downloaded file did not match its checksum, so it was discarded. Try again.")
            case .disk(let why): L10n.tr("Verse could not save the model: \(why)")
            }
        }
    }

    enum State: Equatable {
        case missing
        /// A file is there but is not the expected one (a cut-off copy, another version).
        case damaged
        case downloading(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(Failure)
    }

    /// The app's one installer, so a download keeps running when Settings is left.
    static let shared = EmbeddingModelInstaller()

    @Published private(set) var state: State = .missing
    let spec: EmbeddingModelSpec
    private let transport: any ModelDownloadTransport
    private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so a late progress report of an earlier download is ignored.
    private var generation = 0

    init(spec: EmbeddingModelSpec = .embeddingGemma, transport: any ModelDownloadTransport = URLSessionModelTransport()) {
        self.spec = spec
        self.transport = transport
        refresh()
    }

    /// The running download, for a test to await after `cancel()`.
    var runningTask: Task<Void, Never>? { task }

    var isBusy: Bool {
        switch state {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// Installed means the file is there with the expected size; the checksum is checked once, before it is moved into place.
    nonisolated static func isInstalled(_ spec: EmbeddingModelSpec) -> Bool { fileState(spec) == .installed }

    nonisolated private static func fileState(_ spec: EmbeddingModelSpec) -> State {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: spec.destination.path) else { return .missing }
        return (attrs[.size] as? NSNumber)?.int64Value == spec.size ? .installed : .damaged
    }

    /// Reads the file's state again (Settings appearing). Leaves a running download and a shown failure alone.
    func refresh() {
        guard !isBusy else { return }
        if case .failed = state, !Self.isInstalled(spec) { return }
        state = Self.fileState(spec)
    }

    /// Starts the download (the owner's click). Does nothing while one runs or when the model is installed.
    func download() {
        guard !isBusy else { return }
        task = Task { await install() }
    }

    /// Stops the download; the partial file is removed and the row goes back to what is on disk.
    func cancel() {
        guard isBusy else { return }
        generation += 1
        task?.cancel()
        task = nil
        state = Self.fileState(spec)
    }

    /// The whole install. Tests await it directly; `download()` runs it in a task.
    func install() async {
        if Self.isInstalled(spec) { state = .installed; return }
        generation += 1
        let mine = generation
        let spec = self.spec
        state = .downloading(received: 0, total: spec.size)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: spec.directory, withIntermediateDirectories: true)
        } catch {
            state = .failed(.disk(error.localizedDescription))
            return
        }
        // Next to the destination, so the final move is a rename on the same volume; the dot keeps it out of sight.
        let part = spec.directory.appendingPathComponent(".\(spec.fileName).\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: part) }
        let step = max(spec.size / 200, 1)
        let lastShown = Locked<Int64>(0)
        do {
            try await transport.download(spec.url, to: part) { [weak self] received, total in
                // At most about 200 updates for the whole file.
                guard lastShown.update({ received - $0 >= step || received == total ? received : nil }) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == mine, case .downloading = self.state else { return }
                    self.state = .downloading(received: received, total: total ?? spec.size)
                }
            }
            try Task.checkCancellation()
            guard generation == mine else { return }
            state = .verifying
            try await Self.verify(part, spec: spec)
            try Task.checkCancellation()
            guard generation == mine else { return }
            try Self.moveIntoPlace(part, spec: spec)
            state = .installed
            FileLog.shared.write("embed model: installed \(spec.fileName) (\(spec.size) bytes, sha256 ok)")
        } catch is CancellationError {
            if generation == mine { state = Self.fileState(spec) }
        } catch let f as Failure {
            if generation == mine { state = .failed(f) }
            FileLog.shared.write("embed model: download failed: \(f)")
        } catch {
            if generation == mine { state = .failed(.network(error.localizedDescription)) }
            FileLog.shared.write("embed model: download failed: \(error.localizedDescription)")
        }
    }

    /// Size, then SHA-256 read in 1 MB blocks off the main thread.
    nonisolated private static func verify(_ file: URL, spec: EmbeddingModelSpec) async throws {
        try await Task.detached(priority: .utility) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            guard size == spec.size else { throw Failure.sizeMismatch(got: size) }
            let h = try FileHandle(forReadingFrom: file)
            defer { try? h.close() }
            var hasher = SHA256()
            while let block = try h.read(upToCount: 1 << 20), !block.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: block)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == spec.sha256.lowercased() else { throw Failure.checksumMismatch }
        }.value
    }

    nonisolated private static func moveIntoPlace(_ part: URL, spec: EmbeddingModelSpec) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: spec.destination.path) {
                _ = try fm.replaceItemAt(spec.destination, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: spec.destination)
            }
        } catch {
            throw Failure.disk(error.localizedDescription)
        }
        let note = spec.directory.appendingPathComponent("SOURCE.txt")
        if !fm.fileExists(atPath: note.path) { try? Data((spec.sourceNote + "\n").utf8).write(to: note, options: .atomic) }
    }
}

/// A value behind a lock, for the transport's progress callback.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    /// Sets the value to what `change` returns; false (and unchanged) when it returns nil.
    func update(_ change: (Value) -> Value?) -> Bool {
        lock.withLock {
            guard let new = change(value) else { return false }
            value = new
            return true
        }
    }
}

// MARK: - Settings row

/// Settings › Listening: the paraphrase model's status and, when it is missing, the download (only on a click).
struct EmbeddingModelRow: View {
    @ObservedObject var installer: EmbeddingModelInstaller
    @Environment(\.homeInk) private var ink

    private var sizeText: String { installer.spec.size.formatted(.byteCount(style: .file).locale(L10n.formatLocale)) }

    var body: some View {
        HomeRow("Paraphrase model") {
            switch installer.state {
            case .installed:
                Label { Text("Installed", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                    .font(VT.Font.body).foregroundStyle(ink.secondary)
            case .missing, .damaged, .failed:
                Text(verbatim: installer.state == .damaged ? L10n.tr("Incomplete copy") : L10n.tr("Not installed"))
                    .font(VT.Font.body).foregroundStyle(ink.secondary)
                HomeSecondaryButton(verbatim: L10n.tr("Download (\(sizeText))"), symbol: "arrow.down.circle") { installer.download() }
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear).frame(width: 120)
                    .accessibilityLabel(Text("Download progress", bundle: .module))
                Text(verbatim: L10n.percent(Double(received) / Double(max(total, 1))))
                    .font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit()
                HomeSecondaryButton("Cancel") { installer.cancel() }
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Checking the file…", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary)
                HomeSecondaryButton("Cancel") { installer.cancel() }
            }
        }
        .onAppear { installer.refresh() }
        if case .failed(let f) = installer.state {
            HomeRowDivider()
            HomeNote(verbatim: f.message, isError: true).padding(14)
        }
    }
}
