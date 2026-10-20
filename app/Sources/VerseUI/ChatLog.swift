import Foundation

// `chat.jsonl` of Ask this meeting (spec 2.2, 3.3): one JSON object per line, append-only, written by the brain's ask runtime only.
// Swift reads it to show the history. Nothing here writes the file; "Clear chat" is a `control reset` to the brain, which appends a
// `reset` line. Earlier pairs stay on disk and are hidden.

/// What an answer cost, in the units of the Anthropic usage block.
struct ChatUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    init(_ o: [String: Any]?) {
        guard let o else { return }
        input = Int(truncating: (o["input"] as? NSNumber) ?? 0)
        output = Int(truncating: (o["output"] as? NSNumber) ?? 0)
        cacheRead = Int(truncating: (o["cache_read"] as? NSNumber) ?? 0)
        cacheWrite = Int(truncating: (o["cache_write"] as? NSNumber) ?? 0)
    }
}

/// A finished answer (an `a` line, or the `ask_done` of the stream that just ended).
struct ChatAnswer: Equatable, Sendable {
    var id: String
    var text: String
    /// The model id the API reported (`claude-sonnet-5-5`).
    var model: String
    var usage: ChatUsage
    var costUSD: Double
    /// A cancelled answer's cost: the input is exact, the output is estimated at characters / 4.
    var costEstimated: Bool
    var msFirstToken: Int?
    var msTotal: Int?
    var citations: [String]
    var stopReason: String?

    var cancelled: Bool { stopReason == "cancelled" }
}

/// Why a question has no answer: the `kind` of an `a_error` or `ask_error`.
struct ChatFailure: Equatable, Sendable {
    var kind: String
    var message: String
    var retryAfter: Double?
}

/// One question and what became of it.
struct ChatTurn: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Sent, nothing back yet ("Thinking…").
        case waiting
        /// Text is arriving.
        case streaming
        case answered
        case failed
    }

    /// The question's id (`q4`); answers are `a4`.
    var id: String
    var question: String
    var model: String
    var phase: Phase = .answered
    /// Streaming text so far (live turns only).
    var partial = ""
    var answer: ChatAnswer?
    var failure: ChatFailure?

    /// What the answer area shows: the finished text, or the stream so far.
    var shownText: String { answer?.text ?? partial }
    var cost: Double { answer?.costUSD ?? 0 }
}

enum ChatLog {
    struct Loaded: Equatable, Sendable {
        /// The pairs after the last `reset`, oldest first.
        var turns: [ChatTurn]
        /// The next free question number (`q<N>`): one past the highest in the whole file, resets included.
        var nextIndex: Int
    }

    static func url(sessionDir: URL) -> URL { sessionDir.appendingPathComponent("chat.jsonl") }

    /// A missing or unreadable file is an empty chat.
    static func load(sessionDir: URL) -> Loaded {
        guard let data = try? Data(contentsOf: url(sessionDir: sessionDir)), let text = String(data: data, encoding: .utf8) else {
            return Loaded(turns: [], nextIndex: 1)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Loaded {
        var turns: [ChatTurn] = []
        var highest = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let type = o["type"] as? String else { continue }
            switch type {
            case "reset":
                turns = []
            case "q":
                guard let id = o["id"] as? String, let q = o["text"] as? String else { continue }
                highest = max(highest, number(in: id))
                turns.append(ChatTurn(id: id, question: q, model: (o["model"] as? String) ?? "", phase: .failed,
                                      failure: ChatFailure(kind: "interrupted", message: "")))
            case "a":
                guard let q = o["q"] as? String, let i = turns.firstIndex(where: { $0.id == q }) else { continue }
                turns[i].answer = ChatAnswer(
                    id: (o["id"] as? String) ?? "", text: (o["text"] as? String) ?? "", model: (o["model"] as? String) ?? turns[i].model,
                    usage: ChatUsage(o["usage"] as? [String: Any]), costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                    costEstimated: (o["cost_estimated"] as? Bool) ?? false, msFirstToken: (o["ms_first_token"] as? NSNumber)?.intValue,
                    msTotal: (o["ms_total"] as? NSNumber)?.intValue, citations: (o["citations"] as? [String]) ?? [],
                    stopReason: o["stop_reason"] as? String)
                turns[i].failure = nil
                turns[i].phase = .answered
            case "a_error":
                guard let q = o["q"] as? String, let i = turns.firstIndex(where: { $0.id == q }) else { continue }
                turns[i].failure = ChatFailure(kind: (o["kind"] as? String) ?? "error", message: (o["message"] as? String) ?? "",
                                               retryAfter: (o["retry_after"] as? NSNumber)?.doubleValue)
                turns[i].phase = .failed
            default:
                continue
            }
        }
        return Loaded(turns: dropRetried(turns), nextIndex: highest + 1)
    }

    /// A question that failed and was asked again with the same words is shown once, by its later attempt.
    static func dropRetried(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.enumerated().filter { i, t in
            guard t.phase == .failed else { return true }
            return !turns[(i + 1)...].contains { $0.question == t.question }
        }.map(\.element)
    }

    /// `q12` -> 12; 0 when the id has no number.
    static func number(in id: String) -> Int { Int(id.drop { !$0.isNumber }) ?? 0 }
}
