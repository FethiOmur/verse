import AppKit
import SwiftUI

// The reading side of the Ask panel: an answer as editorial text. One `Text` per paragraph (so it wraps, selects and reads like text),
// citations set as small superscript timestamps inside the line, streamed words that fade in chunk by chunk, and the "Sources" row
// with the transcript line on hover. See docs/specs/2026-10-20-ask-panel-motion.md for every curve and number.

// MARK: - Model

/// One run of an answer: words, or a citation mark (`stamp` is set and `text` is the stamp).
struct AskRun: Equatable {
    var text: String
    var stamp: String?
    /// Character offset of the run in the whole answer text: streamed chunks are measured the same way.
    var offset: Int
}

/// A paragraph or a `- ` bullet.
struct AskBlock: Equatable {
    var bullet: Bool
    var runs: [AskRun]
}

/// The transcript line a citation points at, for the hover card.
struct AskCitedLine: Equatable, Sendable {
    var speaker: String
    var text: String
}

enum AskAnswerParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#)
    private static let unfinishedStamp = try! NSRegularExpression(pattern: #"\[[\d:]*$"#)
    private static let bulletMarks = ["- ", "• ", "* "]

    /// The answer as the panel sets it: a block per text line, `- ` lines as bullets, every `[m:ss]` that exists in the transcript as a
    /// citation run (a stamp that does not stays plain text). The space before a citation is dropped: the mark hugs its word, so the
    /// line never opens a gap before a comma. While streaming, a `[` that has not closed yet is held back instead of flashing as text.
    static func blocks(_ raw: String, validStamps: Set<String>, streaming: Bool = false) -> [AskBlock] {
        var text = raw
        if streaming, let m = unfinishedStamp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
            text.removeSubrange(r)
        }
        var out: [AskBlock] = []
        var lineStart = text.startIndex
        var lineOffset = 0
        var count = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isNewline {
                if let b = block(text[lineStart ..< i], offset: lineOffset, validStamps: validStamps) { out.append(b) }
                count += 1
                lineStart = text.index(after: i)
                lineOffset = count
            } else {
                count += 1
            }
            i = text.index(after: i)
        }
        if let b = block(text[lineStart...], offset: lineOffset, validStamps: validStamps) { out.append(b) }
        return out
    }

    private static func block(_ line: Substring, offset: Int, validStamps: Set<String>) -> AskBlock? {
        var s = line
        var off = offset
        func dropLeadingSpace() {
            while let f = s.first, f.isWhitespace { s = s.dropFirst(); off += 1 }
        }
        dropLeadingSpace()
        var bullet = false
        for mark in bulletMarks where s.hasPrefix(mark) {
            bullet = true
            s = s.dropFirst(mark.count)
            off += mark.count
            dropLeadingSpace()
            break
        }
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        guard !s.isEmpty else { return nil }
        let runs = runs(String(s), offset: off, validStamps: validStamps)
        return runs.isEmpty ? nil : AskBlock(bullet: bullet, runs: runs)
    }

    private static func runs(_ line: String, offset: Int, validStamps: Set<String>) -> [AskRun] {
        var out: [AskRun] = []
        let ns = line as NSString
        var cursor = line.startIndex
        func at(_ i: String.Index) -> Int { offset + line.distance(from: line.startIndex, to: i) }
        for m in stamp.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1))
            guard validStamps.contains(value), let r = Range(m.range, in: line) else { continue }
            var before = line[cursor ..< r.lowerBound]
            let beforeStart = cursor
            while let l = before.last, l.isWhitespace { before = before.dropLast() }
            if !before.isEmpty { out.append(AskRun(text: String(before), stamp: nil, offset: at(beforeStart))) }
            out.append(AskRun(text: value, stamp: value, offset: at(r.lowerBound)))
            cursor = r.upperBound
        }
        let rest = line[cursor...]
        if !rest.isEmpty { out.append(AskRun(text: String(rest), stamp: nil, offset: at(cursor))) }
        return out
    }

    /// The distinct stamps an answer cites, in order of first appearance.
    static func citedStamps(_ blocks: [AskBlock]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for b in blocks { for r in b.runs { if let s = r.stamp, seen.insert(s).inserted { out.append(s) } } }
        return out
    }
}

// MARK: - Spoken form (VoiceOver)

enum AskSpoken {
    /// "1:20" -> "1 minute, 20 seconds"; "1:02:05" -> "1 hour, 2 minutes, 5 seconds".
    static func time(_ stamp: String, locale: Locale = L10n.locale) -> String {
        let p = stamp.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        switch p.count {
        case 3: c.hour = p[0]; c.minute = p[1]; c.second = p[2]
        case 2: c.minute = p[0]; c.second = p[1]
        default: return stamp
        }
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let f = DateComponentsFormatter()
        f.calendar = cal
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: c) ?? stamp
    }

    /// The answer as VoiceOver reads it: every mark becomes "(at 1 minute, 20 seconds)".
    static func answer(_ blocks: [AskBlock], locale: Locale = L10n.locale) -> String {
        blocks.map { b in
            b.runs.map { r in
                guard let s = r.stamp else { return r.text }
                return " (" + L10n.tr("at \(time(s, locale: locale))") + ")"
            }.joined()
        }.joined(separator: "\n")
    }
}

// MARK: - Streamed chunks

/// Text that arrived together: `start ..< end` in answer characters, and when.
struct AskChunk: Equatable {
    var start: Int
    var end: Int
    var at: Date
}

enum AskFade {
    /// A chunk fades in over this long, ease-out.
    static let duration: TimeInterval = 0.28

    static func alpha(at offset: Int, chunks: [AskChunk], now: Date) -> Double {
        guard let c = chunks.last(where: { $0.start <= offset }), offset < c.end else { return 1 }
        let t = now.timeIntervalSince(c.at) / duration
        if t >= 1 { return 1 }
        if t <= 0 { return 0 }
        return 1 - pow(1 - t, 3)
    }

    /// True while any chunk is still fading at `now`.
    static func isFading(_ chunks: [AskChunk], now: Date) -> Bool {
        chunks.contains { now.timeIntervalSince($0.at) < duration }
    }
}

// MARK: - Attributed text

enum AskAttributed {
    static let citeScheme = "verse-cite"

    static func url(for stamp: String) -> URL? { URL(string: "\(citeScheme):\(stamp.replacingOccurrences(of: ":", with: "-"))") }

    static func stamp(from url: URL) -> String? {
        guard url.scheme == citeScheme else { return nil }
        return url.absoluteString.dropFirst(citeScheme.count + 1).replacingOccurrences(of: "-", with: ":")
    }

    /// One block as a single attributed string. Words carry the chunk fade as colour alpha; a citation is a 10 pt superscript timestamp
    /// that a click follows (links only once the answer is complete, so nothing under the pointer changes while text streams).
    static func string(_ block: AskBlock, ink: VT.Window, chunks: [AskChunk], now: Date, interactive: Bool) -> AttributedString {
        var out = AttributedString()
        var previousWasMark = false
        for (n, run) in block.runs.enumerated() {
            if let stamp = run.stamp {
                // A narrow no-break space keeps the mark with its word; two marks in a row are told apart by a comma.
                let lead = previousWasMark ? ",\u{202F}" : (n > 0 ? "\u{202F}" : "")
                var s = AttributedString(lead + stamp)
                s.font = .system(size: 10, weight: .semibold).monospacedDigit()
                s.baselineOffset = 4.5
                s.foregroundColor = ink.secondary.opacity(AskFade.alpha(at: run.offset, chunks: chunks, now: now))
                if interactive, let u = url(for: stamp) { s.link = u }
                out += s
                previousWasMark = true
                continue
            }
            previousWasMark = false
            let chars = Array(run.text)
            var i = 0
            while i < chars.count {
                let a = AskFade.alpha(at: run.offset + i, chunks: chunks, now: now)
                var j = i + 1
                while j < chars.count, AskFade.alpha(at: run.offset + j, chunks: chunks, now: now) == a { j += 1 }
                var s = AttributedString(String(chars[i ..< j]))
                s.foregroundColor = ink.primary.opacity(a)
                out += s
                i = j
            }
        }
        return out
    }
}

// MARK: - The answer

/// The answer's blocks. While chunks are fading it redraws every frame (and nothing otherwise).
struct AskAnswerText: View {
    var text: String
    var stamps: Set<String>
    var streaming: Bool
    var chunks: [AskChunk]
    var fading: Bool
    var onCitation: (String) -> Void
    @Environment(\.homeInk) private var ink

    private static let lineSpacing: CGFloat = 4.5

    var body: some View {
        let blocks = AskAnswerParser.blocks(text, validStamps: stamps, streaming: streaming)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !fading)) { _ in
            // The real time at every evaluation, not the timeline's date: a paused or hidden timeline hands out a stale date, and a
            // chunk that arrived "after" it would stay invisible until the next event.
            let now = Date()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { i in
                    row(blocks[i], now: now)
                        .padding(.top, i == 0 ? 0 : (blocks[i].bullet && blocks[i - 1].bullet ? 6 : 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let stamp = AskAttributed.stamp(from: url) else { return .systemAction }
            onCitation(stamp)
            return .handled
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AskSpoken.answer(blocks)))
        .accessibilityActions {
            if !streaming {
                ForEach(AskAnswerParser.citedStamps(blocks), id: \.self) { s in
                    Button { onCitation(s) } label: { Text("Show the transcript at \(AskSpoken.time(s))", bundle: .module) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ b: AskBlock, now: Date) -> some View {
        let t = Text(AskAttributed.string(b, ink: ink, chunks: chunks, now: now, interactive: !streaming))
            .font(.system(size: 14)).lineSpacing(Self.lineSpacing).tint(ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if b.bullet {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").font(.system(size: 14)).foregroundStyle(ink.secondary).frame(width: 8, alignment: .leading)
                t
            }
        } else {
            t
        }
    }
}

// MARK: - Sources row and the hover card

struct AskSourceAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// "Sources" and one token per cited timestamp. A click goes to that row of the transcript; hovering shows the line.
struct AskSourcesRow: View {
    var turnID: String
    var stamps: [String]
    /// The key of the citation whose card is showing: its token stays lit while the card is up.
    var active: String?
    var onCitation: (String) -> Void
    var onHover: (String, Bool) -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        AskFlow(space: 4, lineSpacing: 4, uniformSpace: true) {
            Text("Sources", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary).frame(height: 20)
            ForEach(stamps, id: \.self) { s in
                AskSourceToken(stamp: s, key: "\(turnID)|\(s)", lit: active == "\(turnID)|\(s)", onCitation: onCitation, onHover: onHover)
            }
        }
    }
}

private struct AskSourceToken: View {
    var stamp: String
    var key: String
    var lit: Bool
    var onCitation: (String) -> Void
    var onHover: (String, Bool) -> Void
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        Button { onCitation(stamp) } label: {
            Text(verbatim: stamp).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(hover || lit ? ink.primary : ink.secondary)
                .padding(.horizontal, 6).frame(height: 20)
                .background(hover || lit ? ink.selection : ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(AskPressStyle(scale: 0.95))
        .onHover { hover = $0; onHover(key, $0) }
        .anchorPreference(key: AskSourceAnchors.self, value: .bounds) { [key: $0] }
        .accessibilityLabel(Text("Show the transcript at \(AskSpoken.time(stamp))", bundle: .module))
    }
}

/// The transcript line under a hovered citation: speaker, timestamp, the words. Solid (it floats over a surface that is already glass).
struct AskCitationCard: View {
    var stamp: String
    var line: AskCitedLine
    var width: CGFloat
    @Environment(\.homeInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: line.speaker).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.secondary)
                Text(verbatim: stamp).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink.tertiary)
            }
            Text(verbatim: line.text).font(.system(size: 12.5)).foregroundStyle(ink.primary).lineSpacing(2.5)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .background(ink.floating, in: RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous).strokeBorder(ink.floatingEdge, lineWidth: 1) }
        .shadow(color: .black.opacity(ink.dark ? 0.45 : 0.14), radius: 14, y: 6)
        .accessibilityHidden(true)
    }
}

extension VT.Window {
    /// A floating card or control over the reading plate: solid, so it never reads as glass on glass.
    var floating: Color { dark ? Color(red: 0.19, green: 0.19, blue: 0.205) : .white }
    var floatingEdge: Color { increaseContrast ? separator : (dark ? .white.opacity(0.10) : .black.opacity(0.10)) }
}

/// Press feedback: a small scale, 100 ms ease-out, on the press itself.
struct AskPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
