import Foundation

struct LocaleStatus: Codable, Sendable {
    let locale: String
    let speechTranscriberSupported: Bool
    let speechTranscriberInstalled: Bool
    let speechTranscriberEquivalent: String?
    let speechTranscriberAssetStatus: String
    let dictationTranscriberSupported: Bool
    let dictationTranscriberInstalled: Bool
    let dictationTranscriberEquivalent: String?
    let classification: String
}

struct RunReport: Codable, Sendable {
    let lang: String
    let locale: String
    let module: String
    let status: String          // ok | failed | skipped
    let error: String?
    let audioFormat: String?
    let prepareSec: Double?
    let streamSec: Double?
    let feederLateP50Ms: Double?
    let feederLateMaxMs: Double?
    let eventCount: Int?
    let volatileEventCount: Int?
    let finalEventCount: Int?
    let summary: RunSummary?
    let questions: [QuestionMetrics]?
    let utterances: [Utterance]?
    let events: [Event]?
}

struct FixtureRecord: Codable, Sendable {
    let directory: String
    var filesCreated: Int
    var filesDeleted: Int
    var directoryAbsentAfterDelete: Bool
    var deletedAt: String
}

struct Report: Codable, Sendable {
    let generatedAt: String
    let host: String
    let chunkMs: Int
    let leadSilenceSec: Double
    let gapSilenceSec: Double
    let tailSilenceSec: Double
    let locales: [LocaleStatus]
    var runs: [RunReport]
    var fixtures: FixtureRecord?
}

func ms(_ x: Double?) -> String {
    guard let x else { return "-" }
    return String(format: "%.0f", x * 1000)
}

func pair(_ s: Stat) -> String { "\(ms(s.p50)) / \(ms(s.p90))" }

func renderTable(_ runs: [RunReport]) -> String {
    var rows: [[String]] = [["lang", "module", "n", "word lag p50/p90 ms (loose)", "last-word lag p50/p90 ms (loose)", "final lag p50/p90 ms", "WER", "vol-cov", "? final", "? in vol", "? <= end"]]
    for r in runs {
        guard r.status == "ok", let s = r.summary else {
            rows.append([r.lang, r.module, "-", r.status.uppercased() + ": " + (r.error ?? "").prefix(60), "", "", "", "", "", "", ""])
            continue
        }
        rows.append([r.lang, r.module, "\(s.questions)", pair(s.wordLagLoose) + " (w=\(s.wordLagLoose.n))", pair(s.lastWordLagLoose), pair(s.finalLag),
                     String(format: "%.1f%%", s.wer * 100), String(format: "%.0f%%", s.volatileCoverage * 100),
                     String(format: "%.0f%%", s.qMarkInFinalShare * 100), String(format: "%.0f%%", s.qMarkInVolatileShare * 100),
                     String(format: "%.0f%%", s.qMarkRelBeforeEndShare * 100)])
    }
    let widths = (0..<rows[0].count).map { c in rows.map { $0[c].count }.max() ?? 0 }
    return rows.map { row in
        zip(row, widths).map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }.joined(separator: " | ")
    }.joined(separator: "\n")
}

func renderMarkdownTable(_ runs: [RunReport]) -> String {
    var out = "| lang | module | q | word lag p50 / p90 (ms) | last-word lag p50 / p90 (ms) | final lag p50 / p90 (ms) | WER | volatile coverage | `?` in final | `?` first seen in volatile | `?` visible at or before acoustic end |\n"
    out += "|---|---|---|---|---|---|---|---|---|---|---|\n"
    for r in runs {
        guard r.status == "ok", let s = r.summary else {
            out += "| \(r.lang) | \(r.module) | - | \(r.status): \((r.error ?? "").prefix(80)) | | | | | | | |\n"
            continue
        }
        out += "| \(r.lang) | \(r.module) | \(s.questions) | \(pair(s.wordLagLoose)) (w=\(s.wordLagLoose.n)) | \(pair(s.lastWordLagLoose)) | \(pair(s.finalLag)) | "
        out += String(format: "%.1f%% | %.0f%% | %.0f%% | %.0f%% | %.0f%% |\n", s.wer * 100, s.volatileCoverage * 100,
                      s.qMarkInFinalShare * 100, s.qMarkInVolatileShare * 100, s.qMarkRelBeforeEndShare * 100)
    }
    return out
}

func renderStrictMarkdown(_ runs: [RunReport]) -> String {
    var out = "| lang | module | word lag strict p50 / p90 (ms) | last-word lag strict p50 / p90 (ms) | first final lag p50 / p90 (ms) | `?` first-seen minus acoustic end p50 / p90 (ms) | finals only at stream flush |\n|---|---|---|---|---|---|---|\n"
    for r in runs {
        guard r.status == "ok", let s = r.summary else { continue }
        out += "| \(r.lang) | \(r.module) | \(pair(s.wordLag)) (w=\(s.wordLag.n)) | \(pair(s.lastWordLag)) | \(pair(s.firstFinalLag)) | \(pair(s.qMarkRel)) (n=\(s.qMarkRel.n)) | \(s.finalsAfterFeedEnd) |\n"
    }
    return out
}
