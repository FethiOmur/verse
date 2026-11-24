import Foundation
import SwiftUI

/// One finished dictation, kept so a paste that landed nowhere does not lose the text.
public struct DictationRecord: Codable, Sendable, Equatable {
    public var text: String
    public var date: Date
    /// The app in front when the text was inserted (its localized name), nil when unknown.
    public var app: String?

    public init(text: String, date: Date, app: String?) {
        self.text = text
        self.date = date
        self.app = app
    }
}

/// The last dictations (gap G1), newest first: in memory and in a small JSON file under Verse's Application Support folder,
/// readable by the owner only (0600). No setting: it is always on while dictation is, holds at most `capacity` entries and
/// only text the owner already pasted. A cancelled or empty dictation is never added (`DictationController`).
///
/// The file is read on first use, not at launch. A change updates memory at once and writes the file off the main actor
/// (the dictation's paste comes right after `add`): each write is a snapshot handed to one serial queue, so writes run in the
/// order of the changes and the file ends as the latest list. Each write goes to a temporary file created 0600 in the same
/// folder, then renamed over the old one, so a crash leaves either the old list or the new one.
///
/// A file that cannot be read is moved aside once, to `<name>.bak` (replacing an older one), before the list starts empty:
/// the next write would otherwise replace it and lose what was in it.
@MainActor
public final class DictationHistory: ObservableObject {
    public static let capacity = 10
    static let fileName = "dictation-recent.json"

    /// `~/Library/Application Support/Verse/dictation-recent.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Verse", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Where an unreadable `url` is moved: the same name with `.bak` appended.
    nonisolated static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
    }

    /// nil: memory only.
    public let fileURL: URL?
    private let log: (String) -> Void
    private let writeQueue: DispatchQueue
    private var loaded = false
    private var records_: [DictationRecord] = []
    /// The newest scheduled write; each one waits for the one before it.
    private var lastWrite: Task<Void, Never>?

    /// `writeQueue`: the serial queue the file is written on (tests pass one they can hold).
    public init(fileURL: URL? = DictationHistory.defaultURL, log: @escaping (String) -> Void = { _ in },
                writeQueue: DispatchQueue = DispatchQueue(label: "verse.dictation.history", qos: .utility)) {
        self.fileURL = fileURL
        self.log = log
        self.writeQueue = writeQueue
    }

    /// Newest first, at most `capacity`.
    public var records: [DictationRecord] {
        loadIfNeeded()
        return records_
    }

    public var last: DictationRecord? { records.first }

    public func add(_ record: DictationRecord) {
        loadIfNeeded()
        objectWillChange.send()
        records_.insert(record, at: 0)
        if records_.count > Self.capacity { records_.removeLast(records_.count - Self.capacity) }
        scheduleSave()
    }

    /// Empties the list, in memory at once and in the file (written as an empty list, in order after earlier writes).
    public func clear() {
        loadIfNeeded()
        objectWillChange.send()
        records_.removeAll()
        scheduleSave()
    }

    /// Returns once every write scheduled so far has finished (tests, quit).
    public func waitForWrites() async {
        await lastWrite?.value
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([DictationRecord].self, from: data) else {
            let bak = Self.backupURL(for: url)
            // rename(2) replaces an older backup in one step.
            if rename(url.path, bak.path) == 0 {
                log("dictation: the recent-dictations file is unreadable, moved to \(bak.lastPathComponent), starting empty")
            } else {
                log("dictation: the recent-dictations file is unreadable and could not be moved aside (errno \(errno)), starting empty")
            }
            return
        }
        records_ = Array(list.prefix(Self.capacity))
    }

    private func scheduleSave() {
        guard let url = fileURL else { return }
        let snapshot = records_
        let queue = writeQueue
        let previous = lastWrite
        lastWrite = Task { [weak self] in
            await previous?.value
            let problem: String? = await withCheckedContinuation { done in
                queue.async { done.resume(returning: Self.write(snapshot, to: url)) }
            }
            if let problem { self?.log(problem) }
        }
    }

    /// Writes `records` to `url` atomically and owner-only. Runs on the write queue; returns what went wrong, if anything.
    nonisolated static func write(_ records: [DictationRecord], to url: URL) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return "dictation: could not encode the recent dictations" }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return "dictation: could not write the recent-dictations file"
            }
            // The mode is checked again before the file takes the real name (it never exists there with wider access).
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, url.path) != 0 {
                let code = errno
                try? fm.removeItem(at: tmp)
                return "dictation: could not replace the recent-dictations file (errno \(code))"
            }
            return nil
        } catch {
            return "dictation: could not write the recent-dictations file: \(error.localizedDescription)"
        }
    }
}

/// The menu-bar menu's rows for the last dictations (gap G1): shown only while dictation is on, no run is active and one is
/// kept (`DictationController.offersLastDictation`). "Paste" goes through the dictation inserter once the menu has closed;
/// "Copy" puts it on the clipboard; "Clear" empties the list and its file.
public struct DictationMenuItems: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var settings: DictationSettings
    @ObservedObject var history: DictationHistory

    public init(dictation: DictationController) {
        self.dictation = dictation
        settings = dictation.settings
        history = dictation.history
    }

    public var body: some View {
        if dictation.offersLastDictation {
            Button { Task { await dictation.pasteLast() } } label: { Text("Paste last dictation", bundle: L10n.bundle) }
                .disabled(dictation.phase != .idle)
            Button { dictation.copyLast() } label: { Text("Copy last dictation", bundle: L10n.bundle) }
            Button { dictation.clearRecent() } label: { Text("Clear recent dictations", bundle: L10n.bundle) }
            Divider()
        }
    }
}
