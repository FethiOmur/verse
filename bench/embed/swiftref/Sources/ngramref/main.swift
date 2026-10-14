import Foundation

// usage: ngramref <session-dir> <queries.jsonl> [reps]
// queries.jsonl: one JSON string per line. Output: one JSON object per line, plus a header line with index time.
let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: ngramref <session-dir> <queries.jsonl> [reps]\n".utf8)); exit(2) }
let reps = args.count > 3 ? Int(args[3]) ?? 20 : 20
let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

let bank = try Bank.load(sessionDir: URL(fileURLWithPath: args[1]))
// Index build time: median of 15 builds (the first one warms the allocator).
var buildTimes: [Double] = []
var matcher = BankMatcher(bank: bank, lang: "en")
for _ in 0..<15 { buildTimes.append(ms(clock.measure { matcher = BankMatcher(bank: bank, lang: "en") })) }
buildTimes.sort()
func jstr(_ s: String) -> String { String(data: (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]))!, encoding: .utf8)!.dropFirst().dropLast().description }
print("{\"header\":true,\"entries\":\(bank.entries.count),\"index_ms_median\":\(buildTimes[buildTimes.count / 2]),\"index_ms_min\":\(buildTimes[0]),\"index_ms_max\":\(buildTimes.last!)}")

let lines = try String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8).split(whereSeparator: \.isNewline)
for line in lines {
    guard let arr = try JSONSerialization.jsonObject(with: Data(("[" + line + "]").utf8)) as? [String], let q = arr.first else { continue }
    var times: [Double] = []
    var top: [BankMatcher.Candidate] = []
    for _ in 0..<reps { times.append(ms(clock.measure { top = matcher.top2(q) })) }
    times.sort()
    let cands = top.map { "{\"id\":\"\($0.id)\",\"score\":\($0.score)}" }.joined(separator: ",")
    let qj = String(data: try JSONSerialization.data(withJSONObject: [q]), encoding: .utf8)!
    let qs = String(qj.dropFirst().dropLast())
    print("{\"q\":\(qs),\"top\":[\(cands)],\"ms_median\":\(times[times.count / 2]),\"ms_max\":\(times.last!)}")
}
