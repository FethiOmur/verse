import Foundation

/// A small rotating log file at `~/Library/Logs/Verse/verse.log` (rolls to `verse.log.1` at 1 MB).
///
/// It gets the app's own lines and the runner/brain stderr lines. Never audio, never key material: callers pass only
/// log text, and lines that look like an API key are masked as a last guard.
public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog()

    public let url: URL
    private let maxBytes: UInt64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failedWrites = 0
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Verse/verse.log"),
                maxBytes: UInt64 = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Masks anything shaped like an Anthropic key.
    static func scrub(_ s: String) -> String {
        s.replacingOccurrences(of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: "sk-ant-***", options: .regularExpression)
    }

    public func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(Self.scrub(line))\n"
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { open() }
        guard let h = handle else { return }
        // Review U1: the throwing calls. `seekToEndOfFile()`/`write(_:)`/`offsetInFile` raise an Objective-C exception on an
        // I/O error (a full disk), which no Swift code can catch: every brain stderr line comes through here, so one failed
        // write would end the app. A failed write drops the line and closes the file; the next line opens it again.
        do {
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
            if try h.offset() > maxBytes { rotate() }
        } catch {
            try? h.close()
            handle = nil
            failedWrites += 1
        }
    }

    /// Lines dropped because the file could not be written (for tests and diagnostics).
    public var droppedLines: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedWrites
    }

    /// Tests only: the open handle, to break it.
    var handleForTesting: FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        let fm = FileManager.default
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
        open()
    }
}
