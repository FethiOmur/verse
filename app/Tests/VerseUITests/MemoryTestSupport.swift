import Foundation
import VerseTurns
@testable import VerseUI
import XCTest

/// Scratch copies of the fictional memory fixtures (Marta Velin and Halden Works, Giulia Ferri and Corvo Studio; owner "Dana").
/// Nothing here reads or writes `~/Library/Application Support/Verse`.
enum MemoryFixtures {
    static let owner = "Dana"

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/memory", isDirectory: true)
    }

    struct Scratch {
        var top: URL
        var sessions: URL
        var memory: URL
        var paths: MemoryPaths { MemoryPaths(base: memory) }
        func remove() { try? FileManager.default.removeItem(at: top) }
    }

    /// A temp tree with `sessions/` (a copy of the fixture sessions, so a test may touch mtimes) and an empty `memory/`.
    static func scratch() throws -> Scratch {
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("verse-memory-\(UUID().uuidString)", isDirectory: true)
        let sessions = top.appendingPathComponent("sessions", isDirectory: true)
        let memory = top.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        try fm.copyItem(at: fixturesDir.appendingPathComponent("sessions", isDirectory: true), to: sessions)
        return Scratch(top: top, sessions: sessions, memory: memory)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func object(_ line: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
    }
}

/// An in-process stand-in for the indexer process: answers `memory_index_start`, `sync`, `put` and `end` the way spec 3.3 says.
final class ScriptedIndexBrain: SimBrainTransport, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private var syncCount = 0
    private let busy: Bool
    private let silent: Bool
    private let hold: Bool
    private let need: @Sendable ([String]) -> [String]

    /// `hold`: answers `end` only after `release()`, so a run can be kept open.
    init(busy: Bool = false, silent: Bool = false, hold: Bool = false, need: @escaping @Sendable ([String]) -> [String] = { $0 }) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.busy = busy
        self.silent = silent
        self.hold = hold
        self.need = need
    }

    func release() { finishRun() }

    private func finishRun() {
        let n = lock.withLock { syncCount }
        push(["type": "embed_progress", "done": 3, "total": 3])
        push(["type": "status", "state": "done", "context": ["sessions": n, "chunks": 9, "vectors": 9, "embed": "on"]])
        continuation.finish()
    }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    func close() async { lock.withLock { _closed = true }; continuation.finish() }

    private func push(_ obj: [String: Any]) { continuation.yield(AskWire.line(obj)) }

    func send(_ line: String) {
        lock.withLock { _sent.append(line) }
        guard !silent else { return }
        let o = MemoryFixtures.object(line)
        switch o["type"] as? String {
        case "memory_index_start":
            if busy {
                push(["type": "status", "state": "busy"])
                continuation.finish()
            } else {
                push(["type": "status", "state": "ready", "context": ["sessions": 0, "chunks": 0, "vectors": 0, "embed": "on"]])
            }
        case "sync":
            let names = ((o["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            lock.withLock { syncCount = names.count }
            push(["type": "sync_plan", "need": need(names), "dropped": [String](), "relabelled": 0])
        case "put":
            push(["type": "put_done", "name": (o["name"] as? String) ?? "", "key": "sk3f9qa", "chunks": 3, "ms": 5])
        case "drop":
            break   // no answer: the sessions are gone
        case "end":
            if !hold { finishRun() }
        default:
            break
        }
    }

    /// The `type` of each line Swift sent.
    var sentTypes: [String] { sent.map { (MemoryFixtures.object($0)["type"] as? String) ?? "?" } }

    /// The session names of the `sync` line.
    var syncedNames: [String]? {
        guard let l = sent.first(where: { MemoryFixtures.object($0)["type"] as? String == "sync" }) else { return nil }
        return ((MemoryFixtures.object(l)["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }
}

/// Stand-in for the brief process: writes the fixture brief to `out` and says `brief_done`, or says `brief_error`, or stays silent.
final class ScriptedBriefBrain: SimBrainTransport, @unchecked Sendable {
    enum Mode: Sendable {
        case done(cost: Double)
        case error(kind: String, cost: Double?)
        case silent
        /// Ends when it receives `control stop`.
        case endsOnStop
    }

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private let mode: Mode

    init(_ mode: Mode) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.mode = mode
    }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }
    func close() async { lock.withLock { _closed = true }; continuation.finish() }

    private func push(_ obj: [String: Any]) { continuation.yield(AskWire.line(obj)) }

    func send(_ line: String) {
        lock.withLock { _sent.append(line) }
        let o = MemoryFixtures.object(line)
        switch (o["type"] as? String, mode) {
        case ("brief_start", .done(let cost)):
            let out = (o["out"] as? String) ?? ""
            try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: MemoryFixtures.fixturesDir.appendingPathComponent("brief.json"), to: URL(fileURLWithPath: out))
            push(["type": "status", "state": "ready"])
            push(["type": "brief_done", "path": out, "cost_usd": cost, "points": 3, "dropped_uncited": 1, "ms_total": 4200,
                  "usage": ["input": 18420, "output": 612]])
            continuation.finish()
        case ("brief_start", .error(let kind, let cost)):
            var e: [String: Any] = ["type": "brief_error", "kind": kind, "message": "fixture message"]
            if let cost { e["cost_usd"] = cost }
            push(e)
            continuation.finish()
        case ("control", .endsOnStop):
            continuation.finish()
        default:
            break
        }
    }
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A mutable cell for collecting what a main-actor test saw.
final class MemBox<T> {
    var value: T
    init(_ v: T) { value = v }
}
