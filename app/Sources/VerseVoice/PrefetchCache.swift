import Foundation

/// In-memory store of synthesized sentences, so the next sentence (or the next question) is ready before it is due.
///
/// - Keyed by the sentence text; bounded by 16 sentences and 8 MB (least recently used dropped first).
/// - At most 2 syntheses run at once; the rest wait.
/// - Memory only. Nothing is written to disk, and `clear()` (end of the interview) empties it.
/// - `take` leaves the entry in place, so a repeated line replays without a second paid call.
public actor PrefetchCache {
    public static let maxSentences = 16
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxConcurrent = 2

    private struct Entry {
        let id: Int
        let task: Task<SynthesizedSpeech?, Never>
        var speech: SynthesizedSpeech?      // set once done
        var bytes = 0
    }

    private let engine: any VoiceEngine
    private let maxSentences: Int
    private let maxBytes: Int
    private let maxConcurrent: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []        // least recently used first
    private var nextID = 0
    private var running = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    /// Syntheses started since creation (tests, logs).
    public private(set) var synthesisCount = 0

    public init(engine: any VoiceEngine, maxSentences: Int = PrefetchCache.maxSentences,
                maxBytes: Int = PrefetchCache.maxBytes, maxConcurrent: Int = PrefetchCache.maxConcurrent) {
        self.engine = engine
        self.maxSentences = maxSentences
        self.maxBytes = maxBytes
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Starts synthesizing `text` unless it is already cached or on its way.
    public func prefetch(_ text: String) {
        let key = Self.key(text)
        guard !key.isEmpty else { return }
        if entries[key] != nil { touch(key); return }
        let id = nextID
        nextID += 1
        let engine = self.engine
        let task = Task<SynthesizedSpeech?, Never> { [weak self] in
            guard let self, await self.acquire() else { return nil }
            defer { Task { await self.release() } }
            guard !Task.isCancelled else { return nil }
            await self.started()
            let speech = try? await engine.synthesize(key)
            await self.finished(key: key, id: id, speech: speech)
            return speech
        }
        entries[key] = Entry(id: id, task: task)
        order.append(key)
        evict()
    }

    /// The prepared sentence, waiting for it when it is still being made. nil when it was never prefetched or failed
    /// (the caller then synthesizes it itself).
    public func take(_ text: String) async -> SynthesizedSpeech? {
        let key = Self.key(text)
        guard let e = entries[key] else { return nil }
        if let s = e.speech { touch(key); return s }
        let result = await e.task.value
        if result != nil, entries[key] != nil { touch(key) }
        return result
    }

    /// Drops everything and stops syntheses that are running or waiting.
    public func clear() {
        for e in entries.values { e.task.cancel() }
        entries = [:]
        order = []
        let w = waiters
        waiters = []
        for c in w { c.resume(returning: false) }
    }

    public var count: Int { entries.count }
    public var byteCount: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    public func contains(_ text: String) -> Bool { entries[Self.key(text)]?.speech != nil }

    // MARK: internals

    static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func started() { synthesisCount += 1 }

    private func acquire() async -> Bool {
        if running < maxConcurrent { running += 1; return true }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: true) }   // the slot passes on
        else { running = max(0, running - 1) }
    }

    private func finished(key: String, id: Int, speech: SynthesizedSpeech?) {
        guard var e = entries[key], e.id == id else { return }                   // cleared or replaced meanwhile
        guard let speech else {                                                 // a failed prefetch leaves nothing behind
            entries[key] = nil
            order.removeAll { $0 == key }
            return
        }
        e.speech = speech
        e.bytes = speech.byteCount
        entries[key] = e
        evict()
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        while entries.count > maxSentences || byteCount > maxBytes, order.count > 1, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)?.task.cancel()
        }
    }
}
