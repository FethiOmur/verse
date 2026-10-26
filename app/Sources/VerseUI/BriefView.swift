import SwiftUI

// The ready brief, as a reading column (memory spec 5.1): the five sections with localized titles, each point a line of 13 pt text
// with small superscript marks, and a Sources row under each section. The marks are the Ask answer's (`AskAttributed`), so citations
// look and behave the same: a click opens the cited session. Used by the entity page and, in P5, by the prepared session and Up next.

// MARK: - Layout (pure)

/// What the view draws, worked out from the file: points whose sources are all gone (a trashed session) are left out, and each
/// section numbers its own sources in order of first citation.
struct BriefLayout: Equatable {
    struct Source: Equatable, Identifiable {
        var ordinal: Int
        var cite: BriefFile.Cite
        var title: String
        /// "Halden Kickoff · 19 Oct · 12:34", "… · Summary".
        var caption: String
        var id: Int { ordinal }
    }

    struct Point: Equatable, Identifiable {
        var id: Int
        var text: String
        /// Ordinals into the section's sources.
        var marks: [Int]
    }

    struct Section: Equatable, Identifiable {
        var id: String
        var title: String
        var points: [Point]
        var sources: [Source]
    }

    var sections: [Section]

    /// The section title in the interface language. The file keeps ids; the English headings live in the brain's prompt only.
    static func title(forSection id: String) -> String {
        switch id {
        case "discussed": L10n.tr("Discussed")
        case "promised_owner": L10n.tr("You promised")
        case "promised_them": L10n.tr("They promised")
        case "open": L10n.tr("Still open")
        case "tone": L10n.tr("Tone and preferences")
        default: id
        }
    }

    static func make(brief: BriefFile, available: Set<String>) -> BriefLayout {
        func ref(_ name: String) -> BriefFile.SessionRef? { brief.sessions.first { $0.name == name } }
        var out: [Section] = []
        for section in brief.sections {
            var sources: [Source] = []
            var points: [Point] = []
            for (n, p) in section.points.enumerated() {
                let visible = p.cites.filter { available.contains($0.session) }
                // A point that cited something and has nothing left to cite is hidden; one the brain allowed without a citation stays.
                if !p.cites.isEmpty, visible.isEmpty { continue }
                var marks: [Int] = []
                for c in visible {
                    let ordinal: Int
                    if let i = sources.firstIndex(where: { $0.cite == c }) {
                        ordinal = sources[i].ordinal
                    } else {
                        ordinal = sources.count + 1
                        sources.append(Source(ordinal: ordinal, cite: c, title: ref(c.session)?.title ?? c.session,
                                              caption: caption(for: c, ref: ref(c.session))))
                    }
                    if !marks.contains(ordinal) { marks.append(ordinal) }
                }
                points.append(Point(id: n, text: p.text, marks: marks))
            }
            if !points.isEmpty { out.append(Section(id: section.id, title: title(forSection: section.id), points: points, sources: sources)) }
        }
        return BriefLayout(sections: out)
    }

    private static func caption(for c: BriefFile.Cite, ref: BriefFile.SessionRef?) -> String {
        var parts = [ref?.title ?? c.session]
        if let d = ref.flatMap({ date(from: $0.date) }) { parts.append(d.formatted(shortDate)) }
        switch c.kind {
        case "turn": if let s = c.stamp { parts.append(s) }
        case "summary": parts.append(L10n.tr("Summary"))
        case "prep": parts.append(L10n.tr("Prep"))
        case "chat": parts.append(L10n.tr("Chat"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// "19 Oct".
    static var shortDate: Date.FormatStyle { Date.FormatStyle().locale(L10n.formatLocale).day().month(.abbreviated) }

    static func date(from iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: iso) ?? fractional.date(from: iso)
    }
}

// MARK: - View

struct BriefView: View {
    var brief: BriefFile
    /// The owner's name for VoiceOver ("Dana promised"); empty reads "You promised".
    var ownerName: String
    /// Session folders that still exist: a source in the Trash is not shown.
    var availableSessions: Set<String>
    var onCitation: (BriefFile.Cite) -> Void
    /// The brief was just made or updated: its sections come in one after another (spec 5.5).
    var animated = false
    @Environment(\.homeInk) private var ink

    init(brief: BriefFile, ownerName: String, availableSessions: Set<String>, onCitation: @escaping (BriefFile.Cite) -> Void) {
        self.brief = brief
        self.ownerName = ownerName
        self.availableSessions = availableSessions
        self.onCitation = onCitation
    }

    var body: some View {
        let layout = BriefLayout.make(brief: brief, available: availableSessions)
        VStack(alignment: .leading, spacing: 18) {
            if layout.sections.isEmpty {
                Text("Nothing clear to sum up yet.", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary)
            }
            ForEach(Array(layout.sections.prefix(5).enumerated()), id: \.element.id) { i, section in
                BriefSectionView(section: section, ownerName: ownerName, onCitation: onCitation)
                    .modifier(BriefAppear(index: i, enabled: animated))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.home.people.brief")
    }
}

private struct BriefSectionView: View {
    var section: BriefLayout.Section
    var ownerName: String
    var onCitation: (BriefFile.Cite) -> Void
    @Environment(\.homeInk) private var ink

    private func source(_ ordinal: Int) -> BriefLayout.Source? { section.sources.first { $0.ordinal == ordinal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: section.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(Text(verbatim: spokenTitle))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.points) { p in point(p) }
            }
            if !section.sources.isEmpty { sourcesRow }
        }
        // The marks link to ordinals of this section only.
        .environment(\.openURL, OpenURLAction { url in
            guard let stamp = AskAttributed.stamp(from: url), let n = Int(stamp), let s = source(n) else { return .systemAction }
            onCitation(s.cite)
            return .handled
        })
        .accessibilityElement(children: .contain)
    }

    private var spokenTitle: String {
        section.id == "promised_owner" && !ownerName.isEmpty ? L10n.tr("\(ownerName) promised") : section.title
    }

    private func point(_ p: BriefLayout.Point) -> some View {
        let runs = [AskRun(text: p.text, stamp: nil, offset: 0)]
            + p.marks.enumerated().map { AskRun(text: "\($1)", stamp: "\($1)", offset: p.text.count + $0 + 1) }
        let block = AskBlock(bullet: true, runs: runs)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•").font(VT.Font.body).foregroundStyle(ink.tertiary).frame(width: 8, alignment: .leading).accessibilityHidden(true)
            Text(AskAttributed.string(block, ink: ink, chunks: [], now: Date(), interactive: true))
                .font(VT.Font.body).lineSpacing(3).tint(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(p.marks, id: \.self) { n in
                if let s = source(n) {
                    Button { onCitation(s.cite) } label: { Text("Show source \(n): \(s.caption)", bundle: .module) }
                }
            }
        }
    }

    private var sourcesRow: some View {
        AskFlow(space: 4, lineSpacing: 4, uniformSpace: true) {
            Text("Sources", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary).frame(height: 20)
            ForEach(section.sources) { s in BriefSourceToken(source: s, onCitation: onCitation) }
        }
        .padding(.top, 2)
    }
}

/// "1 Halden Kickoff · 19 Oct · 12:34": the source's ordinal, then where it is. A click opens that session at that place.
private struct BriefSourceToken: View {
    var source: BriefLayout.Source
    var onCitation: (BriefFile.Cite) -> Void
    @Environment(\.homeInk) private var ink
    @State private var hover = false

    var body: some View {
        Button { onCitation(source.cite) } label: {
            HStack(spacing: 5) {
                Text(verbatim: "\(source.ordinal)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(ink.tertiary)
                Text(verbatim: source.caption).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(hover ? ink.primary : ink.secondary)
            }
            .padding(.horizontal, 6).frame(height: 20)
            .background(hover ? ink.selection : ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
            .overlay {
                if ink.increaseContrast {
                    RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(ink.controlBorder)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AskPressStyle(scale: 0.95))
        .onHover { hover = $0 }
        .animation(AskMotion.tint, value: hover)
        .help(Text(verbatim: source.caption))
        .accessibilityLabel(Text("Source \(source.ordinal): \(source.caption)", bundle: .module))
    }
}

/// A section comes in as the brief appears: opacity 0 to 1 and 6 pt up, `AskMotion.enter`, 40 ms after the section before. Reduce
/// Motion: opacity only, 150 ms, no stagger (spec 5.5).
private struct BriefAppear: ViewModifier {
    var index: Int
    var enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || shown ? 1 : 0)
            .offset(y: !enabled || shown || reduceMotion ? 0 : 6)
            .onAppear {
                guard enabled, !shown else { return }
                if reduceMotion {
                    withAnimation(AskMotion.crossfade) { shown = true }
                } else {
                    withAnimation(AskMotion.enter.delay(0.04 * Double(index)).speed(1)) { shown = true }
                }
            }
    }
}
