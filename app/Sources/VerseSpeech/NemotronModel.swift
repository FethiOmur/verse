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

    /// Drops every idle pooled model (frees ~600 MB each). Models in use are left alone. Waits for leases given back just
    /// before (their reset, or a load still running) so a model released a moment ago is dropped too.
    ///
    /// Review S5: `ListenSession.stop()` calls it in the background (`ListenConfig.releaseIdleModelsOnStop`), so a mid-call swap
    /// does not keep the old pipeline's models resident next to the new ones, and a session's models go when it ends.
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
    /// Releases still resetting (or waiting for their load), by lease id: `unloadIdle` waits for them.
    private var pendingReleases: [Int: Task<Void, Never>] = [:]
    private let load: @Sendable (URL) async throws -> StreamingNemotronAsrManager

    init(load: @escaping @Sendable (URL) async throws -> StreamingNemotronAsrManager = NemotronModelPool.loadFromDisk) {
        self.load = load
    }

    static let loadFromDisk: @Sendable (URL) async throws -> StreamingNemotronAsrManager = { dir in
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms560)
        try await manager.loadModels(from: dir)
        return manager
    }

    func acquire(dir: URL) -> Lease {
        if let (id, e) = entries.first(where: { $0.value.dir == dir && !$0.value.claimed }) {
            entries[id]?.claimed = true
            return Lease(id: id, task: e.task)
        }
        let load = self.load
        let task = Task.detached(priority: .utility) { () throws -> StreamingNemotronAsrManager in
            try await load(dir)
        }
        nextId += 1
        entries[nextId] = Entry(dir: dir, task: task, claimed: true)
        return Lease(id: nextId, task: task)
    }

    /// Gives a lease back. The manager is reset first; if its load is still running, the load carries on and the
    /// entry becomes available when it is done. A failed load is dropped.
    func release(_ lease: Lease) {
        guard pendingReleases[lease.id] == nil else { return }
        pendingReleases[lease.id] = Task {
            do {
                let m = try await lease.task.value
                await m.reset()
                self.entries[lease.id]?.claimed = false
            } catch {
                self.entries[lease.id] = nil
            }
            self.pendingReleases[lease.id] = nil
        }
    }

    func unloadIdle() async {
        while let pending = pendingReleases.first?.value { await pending.value }
        // Taken out in one step (no suspension in between), so an `acquire` meanwhile never gets an entry being dropped.
        let idle = entries.filter { !$0.value.claimed }
        for id in idle.keys { entries[id] = nil }
        for e in idle.values {
            if let m = try? await e.task.value { await m.cleanup() }
        }
    }

    var count: Int { entries.count }
}
