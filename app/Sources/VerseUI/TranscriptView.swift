import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Sessions detail's Transcript tab (spec 2.1): one reading plate with a toolbar (search, Cards, Copy, Export…), the rows in
// speaker blocks and, under the row each answered, the cards Verse showed. Tokens and patterns are the redesign's: neutral fills,
// one accent (the search highlight), hairlines, no new colours.

// MARK: - Jump

/// Asks the transcript to reveal a row: Ask's citation chips (F2b) call `reveal`. The view scrolls the row to the centre, shades it
/// for 1.5 s and fades the shade out in 300 ms (no fade under Reduce Motion). `serial` changes on every request, so asking for the
/// same row twice works.
@MainActor
final class TranscriptJump: ObservableObject {
    @Published private(set) var rowID: String?
    @Published private(set) var serial = 0

    func reveal(rowID: String) {
        self.rowID = rowID
        serial += 1
    }

    /// Reveals the first row stamped `stamp` ("12:34"); false when the transcript has no such row.
    @discardableResult
    func reveal(stamp: String, in document: TranscriptDocument) -> Bool {
        guard let row = document.row(forStamp: stamp) else { return false }
        reveal(rowID: row.id)
        return true
    }
}

// MARK: - Render state

/// Forced by a render (`--render-home`): the tab to open and the search to show. nil in the app, which remembers the tab itself and
/// starts with an empty search.
struct SessionsDetailRenderState: Equatable, Sendable {
    var tab: SessionsDetailTab
    var query = ""
}

struct SessionsDetailRenderKey: EnvironmentKey {
    static var defaultValue: SessionsDetailRenderState? { nil }
}

extension EnvironmentValues {
    var sessionsDetailRender: SessionsDetailRenderState? {
        get { self[SessionsDetailRenderKey.self] }
        set { self[SessionsDetailRenderKey.self] = newValue }
    }
}

// MARK: - View

struct TranscriptView: View {
    var document: TranscriptDocument
    /// The session title and the meta line the Markdown export starts with.
    var title: String
    var meta: String
    @ObservedObject var jump: TranscriptJump

    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sessionsDetailRender) private var render
    @State private var query = ""
    @State private var find = TranscriptFind()
    @State private var showCards = true
    @State private var flashID: String?
    @State private var flashOn = false
    @State private var flashTask: Task<Void, Never>?
    @State private var handledSerial = 0
    @State private var plateWidth: CGFloat = 0
    @State private var copied = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HomeGroup(plate: true) {
            if document.isEmpty {
                Text("No transcript was saved for this session.", bundle: .module)
                    .font(VT.Font.body).foregroundStyle(ink.secondary).padding(20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    toolbar
                    Rectangle().fill(ink.separator).frame(height: 1)
                    if let error { HomeNote(verbatim: error, isError: true).padding(.horizontal, 20).padding(.top, 10) }
                    list
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("verse.home.transcript")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plateWidth = $0 }
        .onAppear {
            if let q = render?.query, !q.isEmpty, query.isEmpty { query = q }
            refind(query)
        }
        .onChange(of: document) { _, _ in refind(query) }
    }

    // MARK: toolbar

    private var toolbar: some View {
        // One row when the plate is wide, two when it is narrow. Decided by the width, not by what fits, so the toolbar does not
        // change shape when the match counter appears.
        Group {
            if plateWidth >= 660 {
                HStack(spacing: 10) {
                    searchGroup
                    Spacer(minLength: 8)
                    actions
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    searchGroup
                    actions
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(minHeight: 32)
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var searchGroup: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(ink.tertiary)
                TextField("", text: $query, prompt: Text("Search transcript", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.primary)
                    .focused($searchFocused)
                    .onKeyPress(keys: [.return]) { press in
                        step(forward: !press.modifiers.contains(.shift))
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !query.isEmpty else { return .ignored }
                        query = ""
                        return .handled
                    }
                    .accessibilityIdentifier("verse.home.transcript.search")
            }
            .padding(.horizontal, 9).frame(width: 240, height: 28)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .onChange(of: query) { _, q in refind(q) }
            counter
            if find.count > 0 {
                HStack(spacing: 2) {
                    stepButton("chevron.up", help: "Previous match", forward: false).keyboardShortcut("g", modifiers: [.command, .shift])
                    stepButton("chevron.down", help: "Next match", forward: true).keyboardShortcut("g", modifiers: .command)
                }
            }
        }
    }

    @ViewBuilder private var counter: some View {
        if let p = find.position {
            Text("\(p) of \(find.count)", bundle: .module)
                .font(VT.Font.caption).monospacedDigit().foregroundStyle(ink.secondary)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("No matches", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.secondary)
        }
    }

    private func stepButton(_ symbol: String, help: LocalizedStringKey, forward: Bool) -> some View {
        Button { step(forward: forward) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(Text(help, bundle: .module))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if document.hasCards {
                HomeSecondaryButton("Cards", symbol: showCards ? "checkmark" : nil) { showCards.toggle() }
                    .accessibilityAddTraits(showCards ? .isSelected : [])
            }
            HomeSecondaryButton(copied ? "Copied" : "Copy") { copy() }
            SessionChromeMenu(title: "Export…") {
                Button { export(.markdown) } label: { Text("Markdown (.md)", bundle: .module) }
                Button { export(.plain) } label: { Text("Plain text (.txt)", bundle: .module) }
            }
        }
    }

    // MARK: rows

    private var list: some View {
        let blocks = document.blocks
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks.indices, id: \.self) { b in block(blocks[b]) }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .onChange(of: find.current) { _, _ in
                if let m = find.currentMatch { proxy.scrollTo(document.rows[m.row].id, anchor: .center) }
            }
            .onChange(of: jump.serial) { _, _ in reveal(proxy) }
            .task { reveal(proxy) }
        }
    }

    private func block(_ indices: [Int]) -> some View {
        let first = document.rows[indices[0]]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: first.stamp).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink.tertiary)
                    .frame(width: 52, alignment: .trailing)
                Text(verbatim: document.name(of: first.speaker)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(first.speaker == .me ? ink.primary : ink.secondary)
            }
            ForEach(indices, id: \.self) { i in
                TranscriptRowView(row: document.rows[i], showStamp: i != indices[0], showCard: showCards,
                                  ranges: find.ranges(inRow: i), nameHit: find.currentMatch.map { $0.row == i && $0.range == nil } ?? false,
                                  flash: flashID == document.rows[i].id && flashOn)
                    .id(document.rows[i].id)
            }
        }
    }

    // MARK: find

    private func refind(_ q: String) {
        find = TranscriptFind(matches: TranscriptSearch.matches(in: document, query: q))
    }

    private func step(forward: Bool) {
        guard find.count > 0 else { return }
        if forward { find.next() } else { find.previous() }
    }

    // MARK: jump

    private func reveal(_ proxy: ScrollViewProxy) {
        guard jump.serial > handledSerial, let id = jump.rowID, document.rows.contains(where: { $0.id == id }) else { return }
        handledSerial = jump.serial
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            // A lazily built list needs a beat after the tab switch before it can scroll to a row.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(id, anchor: .center)
            flashID = id
            flashOn = true
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                flashOn = false
            } else {
                withAnimation(.easeOut(duration: 0.3)) { flashOn = false }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if !Task.isCancelled { flashID = nil }
        }
    }

    // MARK: copy and export

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.plainText(), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private enum ExportFormat {
        case markdown, plain
        var ext: String { self == .markdown ? "md" : "txt" }
        var type: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText }
    }

    /// Writes the transcript where Alex picks, nowhere else.
    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safe) \(L10n.tr("transcript")).\(format.ext)"
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = format == .markdown ? document.markdown(title: title, meta: meta, includeCards: showCards && document.hasCards) : document.plainText()
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "\(error.localizedDescription)"
        }
    }
}

// MARK: - One row

private struct TranscriptRowView: View {
    var row: TranscriptRow
    var showStamp: Bool
    var showCard: Bool
    var ranges: [(range: Range<Int>, isCurrent: Bool)]
    var nameHit: Bool
    var flash: Bool
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: row.stamp).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink.tertiary)
                .frame(width: 52, alignment: .trailing)
                .opacity(showStamp && hover ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(highlighted)
                    .font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if showCard, let card = row.card { TranscriptCardView(card: card) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background((flash || nameHit) ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// The row text with the search hits shaded: the accent at 35 %, and the current hit a full accent fill with its label colour.
    private var highlighted: AttributedString {
        var a = AttributedString(row.text)
        let n = a.characters.count
        for (r, isCurrent) in ranges where r.lowerBound < n {
            let s = a.characters.index(a.startIndex, offsetBy: r.lowerBound)
            let e = a.characters.index(a.startIndex, offsetBy: min(r.upperBound, n))
            a[s ..< e].backgroundColor = isCurrent ? VT.mint : VT.mint.opacity(0.35)
            if isCurrent { a[s ..< e].foregroundColor = VT.onMint }
        }
        return a
    }
}

// MARK: - A card

private struct TranscriptCardView: View {
    var card: TranscriptCard
    @Environment(\.homeInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble").font(.system(size: 10))
                Text("Card · \(card.tierLabel)", bundle: .module)
            }
            .font(VT.Font.caption).foregroundStyle(ink.tertiary)
            if let say = card.say {
                Text(verbatim: say).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(Array(card.points.enumerated()), id: \.offset) { _, p in
                Text(verbatim: "– \(p)").font(VT.Font.callout).foregroundStyle(ink.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A neutral menu button

/// A menu that looks like `HomeSecondaryButton` (a title) or a neutral icon button (a symbol): the window's one menu chrome.
struct SessionChromeMenu<Items: View>: View {
    var title: LocalizedStringKey?
    var symbol: String?
    var help: LocalizedStringKey?
    @ViewBuilder var items: Items
    @Environment(\.homeInk) private var ink
    @Environment(\.isEnabled) private var enabled

    init(title: LocalizedStringKey? = nil, symbol: String? = nil, help: LocalizedStringKey? = nil, @ViewBuilder items: () -> Items) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .regular)) }
                if let title { Text(title, bundle: .module) }
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.primary)
            .padding(.horizontal, title == nil ? 0 : 12).frame(minWidth: 28, minHeight: 28, maxHeight: 28)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .overlay {
                if ink.increaseContrast {
                    RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
                }
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(help.map { Text($0, bundle: .module) } ?? Text(verbatim: ""))
    }
}
