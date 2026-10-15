import Foundation
import VerseTurns

/// Hints during a practice interview (off by default): the normal meeting card runs on the interviewer's lines, the
/// interviewer being the "remote" speaker. That card needs the meeting runtime, so a second brain process runs in
/// meeting mode beside the sim brain. Its session is `<sim session>/hints/` with `pack.md` = the sim pack (the
/// candidate's evidence and the question plan), and every finished interviewer line goes to it as a `turn` question.
/// Its answer lines feed the overlay exactly as in a meeting.
@MainActor
final class SimHints {
    private var brain: BrainProcess?
    private var reader: Task<Void, Never>?
    private let overlay: OverlayModel
    private let log: (String) -> Void

    /// The brain output the card is built from; status lines stay with the sim brain.
    private static let cardTypes: Set<String> = ["delta", "select", "opener_status", "bank_hit", "bank_verdict"]

    init(overlay: OverlayModel, log: @escaping (String) -> Void) {
        self.overlay = overlay
        self.log = log
    }

    /// Writes `hints/pack.md` and starts the meeting brain on it. Failures only turn hints off (logged).
    func start(sessionDir: URL, brainDir: URL, fake: Bool) {
        let dir = sessionDir.appendingPathComponent("hints", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pack = try Data(contentsOf: sessionDir.appendingPathComponent("sim_pack.md"))
            try pack.write(to: dir.appendingPathComponent("pack.md"), options: .atomic)
            let b = try BrainProcess(brainDir: brainDir, extraArgs: fake ? ["--fake"] : ["--no-embed"],
                                     onStderr: { l in FileLog.shared.write("[hints brain] " + l) })
            try b.start()
            brain = b
            reader = Task { [weak self] in
                for await line in b.lines {
                    guard let o = JSONValue.decodeObject(line), Self.cardTypes.contains(o.type) else { continue }
                    await MainActor.run { self?.overlay.apply(.brain(o)) }
                }
            }
            b.send(BrainCommand.start(sessionDir: dir.path, lang: "en").jsonLine())
            log("sim hints on")
        } catch {
            log("sim hints off: \(error)")
            brain = nil
        }
    }

    /// One finished interviewer line: a question for the card.
    func interviewerLine(id: String, text: String) {
        guard let brain, !text.isEmpty else { return }
        let ev = OutboundEvent.turn(turnID: "sim-\(id)", speaker: .remote, text: text, addressee: .me, tAudioEnd: 0, kind: .question)
        brain.send(ev.jsonLine())
        var o = JSONValue.decodeObject(ev.jsonLine()) ?? [:]
        o["dir"] = .string("to_brain")
        overlay.apply(.outbound(o))
    }

    func stop() async {
        reader?.cancel()
        reader = nil
        await brain?.shutdown()
        brain = nil
    }
}
