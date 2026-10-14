import Darwin
import Foundation
import VerseMeet

// verse-meet: manual checks for calendar prep and meeting detection.
//   verse-meet events [--within MIN]              upcoming events (titles and times; never the notes body)
//   verse-meet watch --seconds N                  print meeting start/end signals while you join a call
//   verse-meet prep --event-id ID [--repo PATH] [--live] [--lang L] [--brain-dir DIR] [--python PATH] [--out DIR]
// Calendar data is personal: output is counts, titles and times only.

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func out(_ s: String) { print(s); fflush(stdout) }

func usage() -> Never {
    err("""
    usage: verse-meet events [--within MIN]
           verse-meet watch --seconds N [--no-calendar]
           verse-meet prep --event-id ID [--repo PATH]... [--live] [--lang en] [--brain-dir DIR] [--python PATH] [--out DIR]
      events   lists events that end after now and start within MIN minutes (default 30)
      watch    polls once per second for microphone input in Brave, Chrome, Safari, Arc, Zoom and Teams
      prep     builds a session folder from the event; offline and free unless --live (spend cap 0.45 USD)
    """)
    exit(2)
}

let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM HH:mm"
    return f
}()
func clock(_ d: Date) -> String { timeFormat.string(from: d) }

/// Waits for calendar access; the first run shows the system prompt, which someone has to click.
func requestAccess(_ source: CalendarSource) async throws {
    if source.authorization() == .notDetermined {
        err("verse-meet: waiting for the Calendar permission prompt (allow it in the dialog; giving up after 60 s)")
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await source.ensureAccess() }
        group.addTask {
            try await Task.sleep(for: .seconds(60))
            throw CalendarError.failed("no answer to the Calendar permission prompt within 60 s")
        }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}

func fail(_ error: Error) -> Never {
    if let c = error as? CalendarError { err("verse-meet: \(c)") } else { err("verse-meet: \(error)") }
    exit(1)
}

func findBrainDir(_ explicit: String?) -> URL? {
    let fm = FileManager.default
    func isBrain(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("verse_brain").path) }
    if let e = explicit ?? ProcessInfo.processInfo.environment["VERSE_BRAIN_DIR"], !e.isEmpty {
        let u = URL(fileURLWithPath: (e as NSString).expandingTildeInPath, isDirectory: true)
        return isBrain(u) ? u : nil
    }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
        let cand = dir.appendingPathComponent("brain")
        if isBrain(cand) { return cand }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

@main
struct VerseMeetCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { usage() }
        let cmd = args.removeFirst()
        var opts: [String: [String]] = [:]
        var flags: Set<String> = []
        var it = args.makeIterator()
        while let k = it.next() {
            switch k {
            case "--live", "--no-calendar": flags.insert(k)
            case "--within", "--seconds", "--event-id", "--repo", "--lang", "--brain-dir", "--python", "--out":
                guard let v = it.next() else { err("verse-meet: missing value for \(k)"); usage() }
                opts[k, default: []].append(v)
            default: err("verse-meet: unknown option \(k)"); usage()
            }
        }
        let source = CalendarSource()
        switch cmd {
        case "events": await events(source, within: Double(opts["--within"]?.last ?? "") ?? 30)
        case "watch":
            guard let secs = Double(opts["--seconds"]?.last ?? ""), secs > 0 else { usage() }
            await watch(source, seconds: secs, useCalendar: !flags.contains("--no-calendar"))
        case "prep":
            guard let id = opts["--event-id"]?.last else { usage() }
            await prep(source, id: id, opts: opts, live: flags.contains("--live"))
        default: usage()
        }
    }

    static func events(_ source: CalendarSource, within minutes: Double) async {
        do {
            try await requestAccess(source)
            let list = try await source.upcoming(within: minutes * 60)
            out("events: \(list.count) (ending after now, starting within \(Int(minutes)) min)")
            for e in list {
                let mins = Int(e.end.timeIntervalSince(e.start) / 60)
                out("- \(clock(e.start)) (\(mins) min) | \(e.provider.rawValue) | attendees \(e.attendees.count) | \(e.title) | id \(e.id)")
            }
        } catch { fail(error) }
    }

    static func watch(_ source: CalendarSource, seconds: Double, useCalendar: Bool) async {
        let table = CoreAudioProcessTable()
        let now = table.snapshot()
        let known = MeetingApp.known
        let micNow = now.filter(\.isRunningInput)
        let micKnown = micNow.filter { p in known.contains { $0.matches(p.bundleID) } }
        out("watching \(Int(seconds)) s | processes with mic input now: \(micNow.count) (in meeting apps: \(micKnown.count)) | calendar: \(useCalendar ? (source.authorization() == .fullAccess ? "on" : "not authorised, skipped") : "off")")
        let lookup: @Sendable (Date) async -> [MeetingEvent] = { when in
            useCalendar ? source.overlapping(now: when) : []
        }
        let detector = MeetingDetector(table: table, eventLookup: lookup)
        let stream = await detector.signals()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await detector.stop()
        }
        var started = 0, ended = 0
        let t0 = Date()
        for await sig in stream {
            switch sig {
            case .started(let i):
                started += 1
                out("+\(Int(Date().timeIntervalSince(t0))) s started | \(i.appName) | input since +\(Int(i.since.timeIntervalSince(t0))) s | event: \(i.event?.title ?? "none")")
            case .ended(let i):
                ended += 1
                out("+\(Int(Date().timeIntervalSince(t0))) s ended   | \(i.appName)")
            }
        }
        deadline.cancel()
        out("done: \(started) started, \(ended) ended in \(Int(Date().timeIntervalSince(t0))) s")
    }

    static func prep(_ source: CalendarSource, id: String, opts: [String: [String]], live: Bool) async {
        do {
            guard let brain = findBrainDir(opts["--brain-dir"]?.last) else {
                err("verse-meet: brain directory not found (set VERSE_BRAIN_DIR or pass --brain-dir)")
                exit(1)
            }
            try await requestAccess(source)
            guard let event = try await source.event(id: id) else {
                err("verse-meet: no event with that id from a day ago to two weeks ahead")
                exit(1)
            }
            let python = (opts["--python"]?.last ?? ProcessInfo.processInfo.environment["VERSE_BRAIN_PYTHON"])
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let outRoot = opts["--out"]?.last.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            let repos = (opts["--repo"] ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            let prep = CalendarPrep(brainDir: brain, python: python, outRoot: outRoot, fake: !live)
            out("prep: \(live ? "LIVE (cap 0.45 USD)" : "offline (--fake)") for \"\(event.title)\" | attendees \(event.attendees.count)")
            let session = try await prep.makeSession(for: event, repos: repos, lang: opts["--lang"]?.last ?? "en")
            out("session: \(session.path)")
        } catch { fail(error) }
    }
}
