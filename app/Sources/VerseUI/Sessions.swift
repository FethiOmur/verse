import Foundation

/// Session folders under `~/Library/Application Support/Verse/sessions/` that have a `pack.md`.
public enum SessionCatalog {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verse/sessions", isDirectory: true)
    }

    public static func list(root: URL = root) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("pack.md").path) }.sorted()
    }

    public static func url(_ name: String, root: URL = root) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

/// What Verse spent, from the brain's `metric.cost_usd`. Each run of a session is one record in `<session>/spend.json`;
/// "this month" sums the records of every session folder.
public struct SpendLedger: Sendable {
    public struct Run: Codable, Sendable, Equatable {
        public var startedAt: Date
        public var costUSD: Double
        enum CodingKeys: String, CodingKey { case startedAt = "started_at", costUSD = "cost_usd" }
    }

    struct File: Codable { var runs: [Run] }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func runs(sessionDir: URL) -> [Run] {
        guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("spend.json")),
              let f = try? decoder.decode(File.self, from: d) else { return [] }
        return f.runs
    }

    /// Writes (or updates) the record for the run that started at `startedAt`.
    public static func record(sessionDir: URL, startedAt: Date, costUSD: Double) {
        var runs = runs(sessionDir: sessionDir)
        let key = startedAt.timeIntervalSince1970.rounded()
        if let i = runs.firstIndex(where: { $0.startedAt.timeIntervalSince1970.rounded() == key }) {
            runs[i].costUSD = costUSD
        } else {
            runs.append(Run(startedAt: startedAt, costUSD: costUSD))
        }
        guard let d = try? encoder.encode(File(runs: runs)) else { return }
        try? d.write(to: sessionDir.appendingPathComponent("spend.json"), options: .atomic)
    }

    /// The total of every session's runs in the calendar month of `now`.
    public static func thisMonth(root: URL = SessionCatalog.root, now: Date = Date(), calendar: Calendar = .current) -> Double {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var total = 0.0
        for n in names {
            for r in runs(sessionDir: root.appendingPathComponent(n)) where calendar.isDate(r.startedAt, equalTo: now, toGranularity: .month) {
                total += r.costUSD
            }
        }
        return total
    }
}
