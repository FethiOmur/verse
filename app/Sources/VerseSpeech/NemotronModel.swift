import Foundation
@preconcurrency import FluidAudio

/// Where the Nemotron Speech Streaming 0.6B (560 ms chunk, CoreML) files live, and a process-wide pool of loaded
/// model instances.
///
/// Nothing is ever downloaded: the folder must already exist (it was moved here from `bench/stt-models`).
public enum NemotronModel {
    /// `~/Library/Application Support/Verse/models/nemotron-en-0.6b-560ms/`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Verse/models/nemotron-en-0.6b-560ms", isDirectory: true)
    }

    /// Files FluidAudio's loader needs (the CoreML preprocessor is not used: the mel front-end is native Swift).
    static let requiredEntries = [
        "encoder/encoder_int8.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc", "tokenizer.json", "metadata.json",
    ]

    public static func missingEntries(at dir: URL = defaultDirectory) -> [String] {
        requiredEntries.filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    public static func isInstalled(at dir: URL = defaultDirectory) -> Bool { missingEntries(at: dir).isEmpty }

    /// Drops every idle pooled model (frees ~600 MB each). Models in use are left alone.
    public static func unloadIdle() async { await NemotronModelPool.shared.unloadIdle() }

    public static let engineName = "Nemotron-0.6B-560ms (FluidAudio CoreML)"
}

/// Loaded `StreamingNemotronAsrManager`s, reused across sessions so the 16-21 s load is paid once per process.
///
/// One manager carries one stream's state (encoder caches, decoder state, audio buffer), so two channels need two
/// managers; FluidAudio keeps those fields internal and offers no way to run two streams on one instance.
/// A load that nobody wants any more (the session ended first) finishes in the background and becomes an idle
/// pool entry that the next session adopts.
actor NemotronModelPool {
    static let shared = NemotronModelPool()

    struct Lease: Sendable {
        let id: Int
        let task: Task<StreamingNemotronAsrManager, Error>
    }

    private struct Entry {
        var dir: URL
        var task: Task<StreamingNemotronAsrManager, Error>
        var claimed: Bool
    }

    private var entries: [Int: Entry] = [:]
    private var nextId = 0

    func acquire(dir: URL) -> Lease {
        if let (id, e) = entries.first(where: { $0.value.dir == dir && !$0.value.claimed }) {
            entries[id]?.claimed = true
            return Lease(id: id, task: e.task)
        }
        let task = Task.detached(priority: .utility) { () throws -> StreamingNemotronAsrManager in
            let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
            try await manager.loadModels(from: dir)
            return manager
        }
        nextId += 1
        entries[nextId] = Entry(dir: dir, task: task, claimed: true)
        return Lease(id: nextId, task: task)
    }

    /// Gives a lease back. The manager is reset first; if its load is still running, the load carries on and the
    /// entry becomes available when it is done. A failed load is dropped.
    func release(_ lease: Lease) {
        Task {
            do {
                let m = try await lease.task.value
                await m.reset()
                self.entries[lease.id]?.claimed = false
            } catch {
                self.entries[lease.id] = nil
            }
        }
    }

    func unloadIdle() async {
        for (id, e) in entries where !e.claimed {
            entries[id] = nil
            if let m = try? await e.task.value { await m.cleanup() }
        }
    }

    var count: Int { entries.count }
}
