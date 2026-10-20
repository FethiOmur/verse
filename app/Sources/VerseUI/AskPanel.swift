import AppKit
import SwiftUI

// The "Ask this meeting" panel (spec 2.2): an inspector column on the Sessions page, 340 pt wide. Tokens and patterns are the
// redesign's: neutral fills, hairlines, one accent. The mint fill is the panel's one primary (Ask); the only other mint is the dot
// that breathes while the model thinks. No bubbles, no sparkle, no coloured model picker.

// MARK: - Render state

/// Forced by a render (`--render-home`): the panel is open and shows what `chat.jsonl` holds, with no brain process behind it.
struct AskRenderState: Equatable, Sendable {
    var open = true
}

struct AskRenderKey: EnvironmentKey {
    static var defaultValue: AskRenderState? { nil }
}

extension EnvironmentValues {
    var askRender: AskRenderState? {
        get { self[AskRenderKey.self] }
        set { self[AskRenderKey.self] = newValue }
    }
}

// MARK: - Text helpers

enum AskFormat {
    /// "$0.012" for one answer; "~$0.003" when the cost is an estimate (a cancelled answer).
    static func cost(_ value: Double, estimated: Bool = false) -> String {
        let s = value >= 1 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
        return estimated ? "~" + s : s
    }

    /// "$0.04" for the header: cents once it reaches one, thousandths before.
    static func chatCost(_ value: Double) -> String {
        value >= 0.01 || value == 0 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
    }

    /// "Sonnet · 2.4 s · $0.012".
    static func meta(_ a: ChatAnswer) -> String {
        var parts = [AskModel.displayName(forModelID: a.model)]
        if let ms = a.msTotal { parts.append(String(format: "%.1f s", Double(ms) / 1000)) }
        parts.append(cost(a.costUSD, estimated: a.costEstimated))
        if a.cancelled { parts.insert(L10n.tr("Stopped"), at: 0) }
        return parts.joined(separator: " · ")
    }
}

/// The sentence under a failed question, by the kind the brain reported (spec 2.2 "Errors").
enum AskMessages {
    static func text(for f: ChatFailure) -> String {
        switch f.kind {
        case "credit_exhausted": return L10n.tr("Your Anthropic credit is used up. Add credit, then retry.")
        case "offline": return L10n.tr("No connection. Check your network, then retry.")
        case "rate_limited":
            if let s = f.retryAfter, s >= 1 { return L10n.tr("Rate limited. Try again in \(Int(s.rounded(.up))) s.") }
            return L10n.tr("Rate limited. Try again in a moment.")
        case "overloaded": return L10n.tr("Claude is overloaded right now. Try again in a moment.")
        case "auth", "key_missing": return L10n.tr("The Anthropic key is missing or was not accepted. Check it in Settings.")
        case "refusal": return L10n.tr("The model declined to answer this question.")
        case "interrupted": return L10n.tr("This question was never answered.")
        case "start_failed": return L10n.tr("Could not start the assistant: \(f.message)")
        default:
            let detail = f.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? L10n.tr("Something went wrong.") : L10n.tr("Something went wrong: \(detail)")
        }
    }
}

// MARK: - An answer as lines of words and citation chips

enum AskAnswerPiece: Equatable {
    case word(String, spaceBefore: Bool)
    case chip(String, spaceBefore: Bool)
}

struct AskAnswerLine: Equatable {
    var bullet: Bool
    var pieces: [AskAnswerPiece]
}

enum AskAnswerParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#)

    /// The answer as the panel draws it: one line per text line, `- ` lines as bullets, every `[m:ss]` that exists in the transcript
    /// as a chip (a stamp that does not stays plain text).
    static func lines(_ text: String, validStamps: Set<String>) -> [AskAnswerLine] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var bullet = false
            for mark in ["- ", "• ", "* "] where line.hasPrefix(mark) {
                bullet = true
                line = String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return AskAnswerLine(bullet: bullet, pieces: pieces(line, validStamps: validStamps))
        }
    }

    static func pieces(_ line: String, validStamps: Set<String>) -> [AskAnswerPiece] {
        var out: [AskAnswerPiece] = []
        var gap = false
        func addText(_ s: Substring) {
            var cur = ""
            for ch in s {
                if ch.isWhitespace {
                    if !cur.isEmpty { out.append(.word(cur, spaceBefore: gap && !out.isEmpty)); cur = ""; gap = false }
                    gap = true
                } else {
                    cur.append(ch)
                }
            }
            if !cur.isEmpty { out.append(.word(cur, spaceBefore: gap && !out.isEmpty)); gap = false }
        }
        let ns = line as NSString
        var cursor = line.startIndex
        for m in stamp.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1))
            guard validStamps.contains(value), let r = Range(m.range, in: line) else { continue }
            addText(line[cursor ..< r.lowerBound])
            out.append(.chip(value, spaceBefore: gap && !out.isEmpty))
            gap = false
            cursor = r.upperBound
        }
        addText(line[cursor...])
        return out
    }
}

// MARK: - Flow layout (words and chips wrap like text)

struct AskSpaceBefore: LayoutValueKey {
    static let defaultValue = false
}

/// Wraps its children like words in a paragraph. An item has a space before it when it says so (`AskSpaceBefore`), or every item
/// does with `uniformSpace` (a row of buttons that wraps).
struct AskFlow: Layout {
    var space: CGFloat = 3.6
    var lineSpacing: CGFloat = 4
    var uniformSpace = false

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let wantsSpace = uniformSpace || s[AskSpaceBefore.self]
            let gap = (x > 0 && wantsSpace) ? space : 0
            if x > 0, x + gap + size.width > width + 0.5 {
                rows.append(Row())
                x = 0
            }
            let start = x > 0 ? x + gap : 0
            rows[rows.count - 1].items.append((i, start, size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x = start + size.width
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        let rs = rows(subviews, width: width)
        let h = rs.reduce(0) { $0 + $1.height } + CGFloat(max(rs.count - 1, 0)) * lineSpacing
        let w = rs.map { r in (r.items.last.map { $0.x + $0.size.width }) ?? 0 }.max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y + (row.height - item.size.height) / 2),
                                           anchor: .topLeading, proposal: ProposedViewSize(item.size))
            }
            y += row.height + lineSpacing
        }
    }
}

/// A citation chip: caption 11 medium, secondary on the neutral fill, 18 pt tall, radius 7. A click goes to that row of the transcript.
private struct AskChip: View {
    var stamp: String
    var action: () -> Void
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: stamp).font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.secondary)
                .padding(.horizontal, 6).frame(height: 18)
                .background(hover ? ink.selection : ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(Text("Show in the transcript", bundle: .module))
        .accessibilityLabel(Text("Go to \(stamp) in the transcript", bundle: .module))
    }
}

private struct AskAnswerView: View {
    var text: String
    var stamps: Set<String>
    var onCitation: (String) -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        let lines = AskAnswerParser.lines(text, validStamps: stamps)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if line.bullet {
                        Text(verbatim: "•").font(VT.Font.body).foregroundStyle(ink.secondary).frame(width: 8)
                    }
                    flow(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flow(_ line: AskAnswerLine) -> some View {
        AskFlow {
            ForEach(Array(line.pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .word(let w, let space):
                    Text(verbatim: w).font(VT.Font.body).foregroundStyle(ink.primary).layoutValue(key: AskSpaceBefore.self, value: space)
                case .chip(let stamp, let space):
                    AskChip(stamp: stamp) { onCitation(stamp) }.layoutValue(key: AskSpaceBefore.self, value: space)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The panel

struct AskPanel: View {
    @ObservedObject var session: AskSession
    @ObservedObject var settings: AppSettings
    /// The stamps of the transcript's rows: only these become chips.
    var stamps: Set<String>
    var onCitation: (String) -> Void
    var onClose: () -> Void

    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var confirmClear = false
    @State private var plateWidth: CGFloat = 0
    @FocusState private var composerFocused: Bool

    static let width: CGFloat = 340

    private static let modelItems: [(label: String, value: AskModel)] = AskModel.allCases.map { ($0.title, $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HomeSegmented(verbatim: Self.modelItems, selection: Binding(get: { session.model }, set: { session.model = $0; settings.askModel = $0 }))
                .padding(.top, 12)
            Text("This chat: \(AskFormat.chatCost(session.chatCost))", bundle: .module)
                .font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.tertiary).padding(.top, 8)
            conversation.padding(.top, 12)
            composer.padding(.top, 12)
            Text("Answers use your Anthropic key and only this meeting's transcript, summary, prep and profile.", bundle: .module)
                .font(VT.Font.caption).foregroundStyle(ink.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 16)
        .frame(width: Self.width).frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.home.ask")
        .confirmationDialog(Text("Clear this chat?", bundle: .module), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(role: .destructive) { session.clearChat() } label: { Text("Clear Chat", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("The questions and answers are hidden here and no longer sent to the model. Nothing is deleted.", bundle: .module)
        }
        .task { composerFocused = true }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Ask this meeting", bundle: .module).font(VT.Font.title).foregroundStyle(ink.primary).lineLimit(1)
            Spacer(minLength: 8)
            SessionChromeMenu(symbol: "ellipsis", help: "More") {
                Button { confirmClear = true } label: { Text("Clear chat…", bundle: .module) }.disabled(session.turns.isEmpty)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.secondary)
                    .frame(width: 28, height: 28)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HomePressStyle())
            .help(Text("Close", bundle: .module))
            .accessibilityLabel(Text("Close", bundle: .module))
            .accessibilityIdentifier("verse.home.ask.close")
        }
    }

    // MARK: conversation

    private var conversation: some View {
        HomeGroup(plate: true) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if session.turns.isEmpty {
                            starters
                        } else {
                            ForEach(session.turns) { turn in turnView(turn, isLast: turn.id == session.turns.last?.id).id(turn.id) }
                        }
                        if let n = session.notice, session.turns.last?.phase != .failed {
                            HomeNote(verbatim: AskMessages.text(for: n), isError: true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.turns) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .task { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plateWidth = $0 }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask a question, or start with one of these.", bundle: .module)
                .font(VT.Font.callout).foregroundStyle(ink.secondary).padding(.bottom, 2)
            starter("What did they ask me?", sends: L10n.tr("What did they ask me?"))
            starter("What did I promise to do?", sends: L10n.tr("What did I promise to do?"))
            starter("Where was my answer weak?", sends: L10n.tr("Where was my answer weak?"))
        }
    }

    /// A starter chip. A click sends the sentence in the interface language of the moment; the answer follows the question's.
    private func starter(_ key: LocalizedStringKey, sends question: String) -> some View {
        Button {
            session.send(question)
        } label: {
            Text(key, bundle: .module).font(VT.Font.body).foregroundStyle(ink.primary).multilineTextAlignment(.leading)
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .disabled(session.isBusy)
    }

    @ViewBuilder private func turnView(_ turn: ChatTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Spacer(minLength: max(plateWidth * 0.15, 24))
                Text(verbatim: turn.question).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineSpacing(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            }
            if turn.phase == .waiting {
                Thinking(reduceMotion: reduceMotion)
            }
            if !turn.shownText.isEmpty {
                AskAnswerView(text: turn.shownText, stamps: stamps, onCitation: onCitation)
            }
            if let a = turn.answer {
                HStack(spacing: 8) {
                    Text(verbatim: AskFormat.meta(a)).font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.tertiary)
                    CopyGlyph(text: a.text)
                    Spacer(minLength: 0)
                }
            }
            if let f = turn.failure {
                VStack(alignment: .leading, spacing: 8) {
                    HomeNote(verbatim: AskMessages.text(for: f), isError: true)
                    if isLast, !session.isBusy {
                        HomeSecondaryButton("Retry") { session.retry(turn.id) }
                    }
                }
            }
        }
    }

    // MARK: composer

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isBusy }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $draft, prompt: Text("Ask about this meeting", bundle: .module).foregroundStyle(ink.tertiary), axis: .vertical)
                .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary).lineLimit(1 ... 5)
                .focused($composerFocused)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(minHeight: 30)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .overlay {
                    if ink.increaseContrast {
                        RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
                    }
                }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) {
                        draft += "\n"
                    } else if canSend {
                        submit()
                    }
                    return .handled
                }
                .accessibilityIdentifier("verse.home.ask.field")
            if session.isBusy {
                HomeSecondaryButton("Stop") { session.cancel() }.accessibilityIdentifier("verse.home.ask.stop")
            } else {
                HomePrimaryButton("Ask", action: submit).disabled(!canSend).accessibilityIdentifier("verse.home.ask.send")
            }
        }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        session.send(text)
    }
}

// MARK: - Small parts

private struct Thinking: View {
    var reduceMotion: Bool
    @Environment(\.homeInk) private var ink
    @State private var on = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(VT.mint).frame(width: 7, height: 7).opacity(reduceMotion ? 1 : (on ? 1 : 0.3))
            Text("Thinking…", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct CopyGlyph: View {
    var text: String
    @Environment(\.homeInk) private var ink
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.tertiary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Copy answer", bundle: .module))
        .accessibilityLabel(Text("Copy answer", bundle: .module))
    }
}
