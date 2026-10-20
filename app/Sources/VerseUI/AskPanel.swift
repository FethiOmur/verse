import AppKit
import SwiftUI

// The "Ask this meeting" panel (spec 2.2), redesigned 20 Oct (docs/specs/2026-10-20-ask-panel-motion.md): an inspector column on the
// Sessions page, 340 pt wide. Tokens are the redesign's: neutral fills, hairlines, concentric radii (plate 14 -> composer 14 -> send 9),
// glass nowhere (the window behind is already glass). Accent lime appears twice: the send button and the composer's focus ring.
// No bubbles, no avatars, no sparkle, no gradients; the one gradient is the 14/20 pt opacity mask that lets text leave the plate softly.

// MARK: - Render state

/// Forced by a render (`--render-home`, `VERSE_RENDER_ASK_DIR`): the panel is open and shows what `chat.jsonl` holds, plus a scripted
/// state, with no brain process behind it.
struct AskRenderState: Equatable, Sendable {
    enum Script: Equatable, Sendable {
        /// What `chat.jsonl` holds.
        case chat
        /// The chat cleared: the empty state with its starters.
        case empty
        /// The history, then a new question and no text yet.
        case thinking
        /// The history, then a new question with part of its answer.
        case streaming
        /// The history, then a new question that failed (offline).
        case failed
    }

    struct Hover: Equatable, Sendable {
        var question: String
        var stamp: String
    }

    var open = true
    var script: Script = .chat
    /// A citation whose transcript line is shown as if the pointer rested on it.
    var hover: Hover?
    var draft = ""
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

extension AskSession {
    /// The question the scripted renders ask, and the part of the answer they stop at.
    static let renderQuestion = "Did Lena push back on the six-days-to-two claim?"
    static let renderPartial = "Yes, once. After you said it she called it a big claim [1:20] and asked how you measured it and what the baseline was [1:20]. You answered with three months of the finance lead's own checklist"

    /// Puts a freshly opened session into the scripted state of a render.
    func applyRender(_ r: AskRenderState) {
        switch r.script {
        case .chat:
            return
        case .empty:
            clearChat()
        case .thinking, .streaming, .failed:
            send(Self.renderQuestion)
            guard let id = turns.last?.id else { return }
            if r.script == .streaming { handle(.delta(question: id, text: Self.renderPartial)) }
            if r.script == .failed { handle(.error(question: id, ChatFailure(kind: "offline", message: ""))) }
        }
    }
}

// MARK: - Text helpers

enum AskFormat {
    /// "$0.012" for one answer; "~$0.003" when the cost is an estimate (a cancelled answer).
    static func cost(_ value: Double, estimated: Bool = false) -> String {
        let s = value >= 1 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
        return estimated ? "~" + s : s
    }

    /// "$0.04" for the header menu: cents once it reaches one, thousandths before.
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

/// ⇧⏎: a line break at the caret, not at the end of the text.
enum AskComposerEdit {
    /// The text with a line break replacing `selection` (an offset range in characters; nil appends), and the caret offset after it.
    static func insertNewline(in text: String, selection: Range<Int>?) -> (text: String, caret: Int) {
        let n = text.count
        let r = selection.map { max(0, min($0.lowerBound, n)) ..< max(0, min($0.upperBound, n)) } ?? n ..< n
        var chars = Array(text)
        chars.replaceSubrange(r, with: ["\n"])
        return (String(chars), r.lowerBound + 1)
    }
}

// MARK: - Flow layout

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

// MARK: - Following the stream

enum AskFollow {
    /// Within this distance of the bottom the reader is at the latest text.
    static let atBottom: CGFloat = 40
    /// The "Latest" control shows once the newest text is further away than this and the panel is not following.
    static let jumpDistance: CGFloat = 90

    /// Where a scroll comes to rest decides whether the panel follows the newest text again.
    static func pins(restingDistance d: CGFloat) -> Bool { d < atBottom }

    static func showsJump(pinned: Bool, distance: CGFloat, hasTurns: Bool) -> Bool { hasTurns && !pinned && distance > jumpDistance }
}

// MARK: - Motion

/// The panel's motion constants (docs/specs/2026-10-20-ask-panel-motion.md). Springs are written as response (s) and damping ratio.
enum AskMotion {
    /// New messages, the card between citations, the jump control: critically damped, no overshoot.
    static let settle = Animation.spring(response: 0.34, dampingFraction: 1)
    /// Things that answer a pointer (the card moving from one citation to the next): a little quicker.
    static let quick = Animation.spring(response: 0.26, dampingFraction: 1)
    /// Entrances of small elements (suggestions, errors): strong ease-out, 260 ms.
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.26)
    /// Colour and opacity changes of a control: 150 ms ease-out.
    static let tint = Animation.easeOut(duration: 0.15)
    /// Reduce Motion: every change of state is a crossfade of this length.
    static let crossfade = Animation.easeOut(duration: 0.15)
    /// A pointer must rest this long on a citation before its card shows (the next citation shows it at once), and may leave this long.
    static let cardDelay: Duration = .milliseconds(250)
    static let cardGrace: Duration = .milliseconds(90)
}

// MARK: - The panel

struct AskPanel: View {
    @ObservedObject var session: AskSession
    @ObservedObject var settings: AppSettings
    /// The stamps of the transcript's rows: only these become citations.
    var stamps: Set<String>
    /// The transcript line of each stamp, for the card shown under a hovered citation.
    var lines: [String: AskCitedLine] = [:]
    var onCitation: (String) -> Void
    var onClose: () -> Void

    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askRender) private var askRender
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var confirmClear = false
    @State private var shownCite: String?
    @State private var cardTask: Task<Void, Never>?
    /// Following the newest text. Set by the user's own scrolling and cleared by it, never by the content growing.
    @State private var pinned = true
    @State private var distanceFromBottom: CGFloat = 0
    @State private var faded = false
    @FocusState private var composerFocused: Bool

    static let width: CGFloat = 340

    private var animated: Bool { !reduceMotion && askRender == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            conversation.padding(.top, 14)
            composer.padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 16)
        .frame(width: Self.width).frame(maxHeight: .infinity, alignment: .topLeading)
        .overlayPreferenceValue(AskSourceAnchors.self) { anchors in citationCard(anchors) }
        // Reduce Motion: the panel arrives as a crossfade, not a slide.
        .opacity(reduceMotion && !faded ? 0 : 1)
        .onAppear { if reduceMotion { withAnimation(AskMotion.crossfade) { faded = true } } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.home.ask")
        .confirmationDialog(Text("Clear this chat?", bundle: .module), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(role: .destructive) { session.clearChat() } label: { Text("Clear Chat", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("The questions and answers are hidden here and no longer sent to the model. Nothing is deleted.", bundle: .module)
        }
        .task {
            composerFocused = true
            if let r = askRender {
                if let h = r.hover { shownCite = "\(h.question)|\(h.stamp)" }
                // A render's draft goes in after the field has focus, so it is not drawn selected.
                try? await Task.sleep(for: .milliseconds(80))
                draft = r.draft
            }
        }
    }

    // MARK: header

    private var modelBinding: Binding<AskModel> {
        Binding(get: { session.model }, set: { session.model = $0; settings.askModel = $0 })
    }

    /// The title, one menu (model, this chat's cost, Clear chat) and Close. Nothing else lives up here.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Ask this meeting", bundle: .module).font(VT.Font.title).foregroundStyle(ink.primary).lineLimit(1)
            Spacer(minLength: 8)
            SessionChromeMenu(symbol: "ellipsis", help: "More") {
                Picker(selection: modelBinding) {
                    ForEach(AskModel.allCases) { m in Text(verbatim: m.title).tag(m) }
                } label: {
                    Text("Model", bundle: .module)
                }
                .pickerStyle(.inline)
                Button {} label: { Text("This chat: \(AskFormat.chatCost(session.chatCost))", bundle: .module) }.disabled(true)
                Divider()
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

    private var showJump: Bool { AskFollow.showsJump(pinned: pinned, distance: distanceFromBottom, hasTurns: !session.turns.isEmpty) }

    private var conversation: some View {
        HomeGroup(plate: true) {
            ZStack(alignment: .bottom) {
                scroller
                if showJump {
                    AskJumpButton { jumpToLatest() }
                        .padding(.bottom, 14)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? AskMotion.crossfade : AskMotion.quick, value: showJump)
        }
        .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    /// Text leaves the plate through a short fade instead of a hard edge (14 pt on top, 20 pt at the bottom).
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
        }
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if session.turns.isEmpty {
                        AskEmptyState(disabled: session.isBusy, animated: animated, reduceMotion: reduceMotion) { ask($0) }
                            .containerRelativeFrame(.vertical, alignment: .center) { h, _ in max(h - 38, 0) }
                            .transition(.opacity)
                    } else {
                        ForEach(session.turns) { turn in
                            AskTurnView(turn: turn, isLast: turn.id == session.turns.last?.id, busy: session.isBusy, stamps: stamps,
                                        animated: animated, reduceMotion: reduceMotion, activeCite: shownCite, onCitation: onCitation,
                                        onHover: hover, onRetry: { pinned = true; session.retry(turn.id) })
                                .id(turn.id)
                                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        }
                    }
                    if let n = session.notice, session.turns.last?.phase != .failed {
                        AskFailureView(text: AskMessages.text(for: n), retry: nil)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clear chat and the first question: what leaves fades out in 150 ms; what arrives has its own entrance.
                .animation(reduceMotion ? AskMotion.crossfade : AskMotion.tint, value: session.turns.map(\.id))
            }
            .mask { edgeFade }
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height - g.contentOffset.y - g.containerSize.height + g.contentInsets.bottom)
            } action: { _, d in distanceFromBottom = d }
            .onScrollPhaseChange { _, phase in
                // The reader scrolling decides whether the panel keeps following: grabbing the content lets go, coming to rest at the
                // bottom picks it up again. The content growing never changes it.
                switch phase {
                case .interacting: pinned = false; hideCard()
                case .idle: pinned = AskFollow.pins(restingDistance: distanceFromBottom)
                default: break
                }
            }
            .onChange(of: session.turns) { old, new in
                guard pinned else { return }
                if new.count > old.count, animated { withAnimation(AskMotion.settle) { proxy.scrollTo("bottom", anchor: .bottom) } } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .task { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: jumpToken) { _, _ in
                if animated { withAnimation(AskMotion.settle) { proxy.scrollTo("bottom", anchor: .bottom) } } else { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @State private var jumpToken = 0

    private func jumpToLatest() {
        pinned = true
        jumpToken += 1
    }

    // MARK: citation card

    private func hover(_ key: String, _ inside: Bool) {
        cardTask?.cancel()
        if inside {
            if shownCite != nil {
                shownCite = key
            } else {
                cardTask = Task { @MainActor in
                    try? await Task.sleep(for: AskMotion.cardDelay)
                    guard !Task.isCancelled else { return }
                    shownCite = key
                }
            }
        } else {
            cardTask = Task { @MainActor in
                try? await Task.sleep(for: AskMotion.cardGrace)
                guard !Task.isCancelled else { return }
                shownCite = nil
            }
        }
    }

    private func hideCard() {
        cardTask?.cancel()
        shownCite = nil
    }

    @ViewBuilder private func citationCard(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if let key = shownCite, let anchor = anchors[key], let stamp = key.split(separator: "|").last.map(String.init), let line = lines[stamp] {
                let r = geo[anchor]
                // 292 pt at most, kept inside the plate (16 pt from the panel edge, 6 pt in).
                let w = min(292, geo.size.width - 44)
                let x = min(max(r.minX - 6, 22), geo.size.width - 22 - w)
                // Above the token when there is room, otherwise below it.
                let above = r.minY > 150
                AskCitationCard(stamp: stamp, line: line, width: w)
                    .frame(width: geo.size.width, height: above ? max(r.minY - 6, 0) : nil, alignment: above ? .bottomLeading : .topLeading)
                    .padding(.top, above ? 0 : r.maxY + 6)
                    .offset(x: x)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: above ? .bottom : .top)))
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? AskMotion.crossfade : AskMotion.quick, value: shownCite)
    }

    // MARK: composer

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isBusy }

    /// One field with the send control inside it (radius 14, control inset 5, so the 9 pt button is concentric). The plate's own
    /// material, no glass; the accent shows only on the focus ring and the send button.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("", text: $draft, selection: $selection, prompt: Text("Ask about this meeting", bundle: .module).foregroundStyle(ink.tertiary), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(ink.primary).lineLimit(1 ... 6)
                .focused($composerFocused)
                .padding(.leading, 13).padding(.vertical, 11.5)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) {
                        insertNewline()
                    } else if canSend {
                        submit()
                    }
                    return .handled
                }
                .accessibilityIdentifier("verse.home.ask.field")
            sendButton.padding([.trailing, .bottom], 5)
        }
        .frame(minHeight: 40)
        .background(ink.plate, in: RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous).strokeBorder(ink.groupEdge, lineWidth: 1) }
        .overlay {
            RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous)
                .strokeBorder(ink.mintText, lineWidth: 1.5).opacity(composerFocused ? 1 : 0)
                .animation(AskMotion.tint, value: composerFocused)
        }
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    private var sendButton: some View {
        let busy = session.isBusy
        return Button { busy ? session.cancel() : submit() } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 11 : 13, weight: .bold))
                .foregroundStyle(busy ? ink.primary : (canSend ? VT.onMint : ink.tertiary))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(busy ? ink.selection : (canSend ? VT.mint : ink.fill), in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .overlay {
                    if canSend, !busy { RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.accentEdge, lineWidth: 0.5) }
                }
        }
        .buttonStyle(AskPressStyle())
        .disabled(!busy && !canSend)
        .animation(AskMotion.tint, value: canSend)
        .animation(AskMotion.tint, value: busy)
        .help(busy ? Text("Stop", bundle: .module) : Text("Send", bundle: .module))
        .accessibilityLabel(busy ? Text("Stop", bundle: .module) : Text("Send", bundle: .module))
        .accessibilityIdentifier(busy ? "verse.home.ask.stop" : "verse.home.ask.send")
    }

    private func insertNewline() {
        var range: Range<Int>?
        if let sel = selection, case .selection(let r) = sel.indices {
            range = draft.distance(from: draft.startIndex, to: r.lowerBound) ..< draft.distance(from: draft.startIndex, to: r.upperBound)
        }
        let edit = AskComposerEdit.insertNewline(in: draft, selection: range)
        draft = edit.text
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: min(edit.caret, draft.count)))
    }

    private func submit() {
        guard canSend else { return }
        ask(draft)
        draft = ""
        selection = nil
    }

    private func ask(_ text: String) {
        pinned = true
        session.send(text)
    }
}

/// "Jump to latest": solid, a 9 pt rounded rectangle like every control here (no pill).
private struct AskJumpButton: View {
    var action: () -> Void
    @Environment(\.homeInk) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                Text("Latest", bundle: .module).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ink.primary)
            .padding(.horizontal, 11).frame(height: 28)
            .background(ink.floating, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.floatingEdge, lineWidth: 1) }
            .shadow(color: .black.opacity(ink.dark ? 0.4 : 0.10), radius: 8, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(AskPressStyle())
        .help(Text("Jump to latest", bundle: .module))
        .accessibilityLabel(Text("Jump to latest", bundle: .module))
    }
}

// MARK: - Empty state

/// One considered line and four things worth asking, the privacy line last. The rows rise in a 40 ms stagger (fade only under Reduce Motion).
private struct AskEmptyState: View {
    var disabled: Bool
    var animated: Bool
    var reduceMotion: Bool
    var send: (String) -> Void
    @Environment(\.homeInk) private var ink
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask what was said, promised or missed.", bundle: .module)
                    .font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answers come from this meeting's transcript, summary and prep, with timestamps you can tap.", bundle: .module)
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .modifier(Rise(on: appeared, index: 0, animated: animated, reduceMotion: reduceMotion))
            VStack(spacing: 0) {
                row("What did they ask me?", sends: L10n.tr("What did they ask me?"), index: 1)
                row("What did I promise to do?", sends: L10n.tr("What did I promise to do?"), index: 2)
                row("Where was my answer weak?", sends: L10n.tr("Where was my answer weak?"), index: 3)
                row("What is still open?", sends: L10n.tr("What is still open?"), index: 4, last: true)
            }
            .padding(.top, 18)
            // The group sits a little above the middle, where the eye rests.
            Spacer(minLength: 16)
            Color.clear.frame(height: 36)
            Text("Answers use your Anthropic key and only this meeting's transcript, summary, prep and profile.", bundle: .module)
                .font(VT.Font.caption).foregroundStyle(ink.tertiary).fixedSize(horizontal: false, vertical: true)
                .modifier(Rise(on: appeared, index: 5, animated: animated, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { appeared = true }
    }

    private func row(_ key: LocalizedStringKey, sends question: String, index: Int, last: Bool = false) -> some View {
        AskStarterRow(title: key, last: last, disabled: disabled) { send(question) }
            .modifier(Rise(on: appeared, index: index, animated: animated, reduceMotion: reduceMotion))
    }
}

/// Fade and a 6 pt rise, 260 ms ease-out, 40 ms apart, starting after the panel has begun to settle. Under Reduce Motion: the fade only.
private struct Rise: ViewModifier {
    var on: Bool
    var index: Int
    var animated: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(on || (!animated && !reduceMotion) ? 1 : 0)
            .offset(y: on || !animated ? 0 : 6)
            .animation(reduceMotion ? AskMotion.crossfade : AskMotion.enter.delay(0.10 + Double(index) * 0.04), value: on)
    }
}

private struct AskStarterRow: View {
    var title: LocalizedStringKey
    var last: Bool
    var disabled: Bool
    var action: () -> Void
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title, bundle: .module).font(.system(size: 13.5, weight: .medium)).foregroundStyle(ink.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hover ? ink.secondary : ink.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(hover ? ink.fill : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(AskPressStyle(scale: 0.985))
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 }
        .animation(AskMotion.tint, value: hover)
        .overlay(alignment: .bottom) { if !last, !hover { Rectangle().fill(ink.separator).frame(height: 1).padding(.horizontal, 10) } }
    }
}

// MARK: - One question and what became of it

private struct AskTurnView: View {
    var turn: ChatTurn
    var isLast: Bool
    var busy: Bool
    var stamps: Set<String>
    var animated: Bool
    var reduceMotion: Bool
    var onCitation: (String) -> Void
    /// The citation whose card is showing ("q4|22:06"), so its token stays lit.
    var activeCite: String?
    var onHover: (String, Bool) -> Void
    var onRetry: () -> Void

    @Environment(\.homeInk) private var ink
    @State private var chunks: [AskChunk] = []
    @State private var seen: Int
    @State private var fading = false
    @State private var fadeTask: Task<Void, Never>?
    @State private var entered: Bool

    init(turn: ChatTurn, isLast: Bool, busy: Bool, stamps: Set<String>, animated: Bool, reduceMotion: Bool, activeCite: String?,
         onCitation: @escaping (String) -> Void, onHover: @escaping (String, Bool) -> Void, onRetry: @escaping () -> Void) {
        self.turn = turn
        self.isLast = isLast
        self.busy = busy
        self.stamps = stamps
        self.animated = animated
        self.reduceMotion = reduceMotion
        self.activeCite = activeCite
        self.onCitation = onCitation
        self.onHover = onHover
        self.onRetry = onRetry
        // A turn that is already on screen when it is built (history, the panel opening) just is; a turn that was just asked enters.
        let fresh = turn.phase == .waiting && turn.partial.isEmpty
        _seen = State(initialValue: fresh ? 0 : turn.shownText.count)
        _entered = State(initialValue: !fresh)
    }

    private var live: Bool { turn.phase == .waiting || turn.phase == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            question
            ZStack(alignment: .topLeading) {
                if live {
                    // Out in 80 ms when the first words come, so the line and the words never overlap for long.
                    AskThinking(animated: animated).opacity(turn.phase == .waiting ? 1 : 0)
                        .animation(.easeOut(duration: 0.08), value: turn.phase)
                }
                if !turn.shownText.isEmpty {
                    AskAnswerText(text: turn.shownText, stamps: stamps, streaming: live, chunks: chunks, fading: fading, onCitation: onCitation)
                }
            }
            if let a = turn.answer {
                let cited = AskAnswerParser.citedStamps(AskAnswerParser.blocks(a.text, validStamps: stamps))
                VStack(alignment: .leading, spacing: 4) {
                    if !cited.isEmpty {
                        AskSourcesRow(turnID: turn.id, stamps: cited, active: activeCite, onCitation: onCitation, onHover: onHover)
                    }
                    HStack(spacing: 4) {
                        Text(verbatim: AskFormat.meta(a)).font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.tertiary)
                        CopyGlyph(text: a.text, reduceMotion: reduceMotion)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, -2)
            }
            if let f = turn.failure {
                AskFailureView(text: AskMessages.text(for: f), retry: isLast && !busy ? onRetry : nil)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(reduceMotion ? AskMotion.crossfade : AskMotion.enter, value: turn.phase)
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !entered else { return }
            if reduceMotion {
                withAnimation(AskMotion.crossfade) { entered = true }
            } else if animated {
                withAnimation(AskMotion.settle) { entered = true }
            } else {
                entered = true
            }
        }
        .onChange(of: turn.shownText) { _, text in absorb(text) }
        .onChange(of: turn.phase) { old, new in
            if new == .answered, old == .waiting || old == .streaming {
                AccessibilityNotification.Announcement(L10n.tr("Answer ready")).post()
            }
        }
    }

    /// His question: a neutral fill block, trailing, 13.5 medium. It comes up from the composer (scale 0.97, 8 pt, spring 0.34 / 1.0);
    /// under Reduce Motion it only fades in.
    private var question: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 36)
            Text(verbatim: turn.question).font(.system(size: 13.5, weight: .medium)).foregroundStyle(ink.primary).lineSpacing(3)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                .overlay {
                    if ink.increaseContrast { RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous).strokeBorder(ink.controlBorder) }
                }
                .accessibilityLabel(Text("Your question: \(turn.question)", bundle: .module))
        }
        .opacity(entered ? 1 : 0)
        .scaleEffect(entered || reduceMotion ? 1 : 0.97, anchor: .bottomTrailing)
        .offset(y: entered || reduceMotion ? 0 : 8)
    }

    /// New characters are one chunk that fades in from the moment it arrives; the clock only runs while a chunk is fading.
    private func absorb(_ text: String) {
        let n = text.count
        defer { seen = n }
        guard n > seen else { return }
        let now = Date()
        chunks = chunks.filter { now.timeIntervalSince($0.at) < 1 } + [AskChunk(start: seen, end: n, at: now)]
        fading = true
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(AskFade.duration * 1000) + 60))
            guard !Task.isCancelled else { return }
            fading = false
        }
    }
}

// MARK: - Small parts

/// Before the first token: one quiet line that breathes (opacity 1 to 0.45, 1.1 s ease-in-out), and after five seconds how long it has been.
private struct AskThinking: View {
    var animated: Bool
    @Environment(\.homeInk) private var ink
    @State private var dim = false
    @State private var since = Date()

    var body: some View {
        HStack(spacing: 0) {
            Text("Thinking…", bundle: .module)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(since))
                if s >= 5 { Text(verbatim: " · \(s) s").monospacedDigit().foregroundStyle(ink.tertiary) }
            }
        }
        .font(.system(size: 14)).foregroundStyle(ink.secondary)
        .opacity(animated && dim ? 0.45 : 1)
        .onAppear {
            since = Date()
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A failed question: a coral glyph (the one status colour), the sentence in primary text, and Retry on the last turn.
private struct AskFailureView: View {
    var text: String
    var retry: (() -> Void)?
    @Environment(\.homeInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(VT.coral)
                Text(verbatim: text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let retry { HomeSecondaryButton("Retry", action: retry) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Copy: the glyph becomes a checkmark for 1.4 s (a symbol replace, a crossfade under Reduce Motion) and VoiceOver hears "Copied".
private struct CopyGlyph: View {
    var text: String
    var reduceMotion: Bool
    @Environment(\.homeInk) private var ink
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(AskMotion.tint) { copied = true }
            AccessibilityNotification.Announcement(L10n.tr("Copied")).post()
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
                withAnimation(AskMotion.tint) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? ink.primary : ink.tertiary)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(AskPressStyle(scale: 0.9))
        .help(Text("Copy answer", bundle: .module))
        .accessibilityLabel(Text("Copy answer", bundle: .module))
    }
}
