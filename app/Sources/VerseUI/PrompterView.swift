import SwiftUI
import VersePrompter

/// Colours of the prompter text (spec 2.2): in the current line the words already said are full white and the rest 55 %;
/// the previous line is 28 %, the next 55 %. `[cues]` are amber.
enum PrompterStyle {
    static let cue = Color(red: 1.0, green: 0.80, blue: 0.40)
    static let warning = Color(red: 1.0, green: 0.80, blue: 0.40)

    enum Line { case previous, current, next }

    static func color(for word: PromptWord, style: PrompterWordStyle, line: Line) -> Color {
        let strength: Double
        switch line {
        case .previous: strength = 0.28
        case .next: strength = 0.55
        case .current: strength = style == .read ? 1.0 : 0.55
        }
        return word.isCue ? cue.opacity(strength) : Color.white.opacity(strength)
    }
}

/// One word. A click anywhere in its slot (the word plus half a space on each side) jumps to it.
struct PrompterWordView: View {
    var word: PromptWord
    var style: PrompterWordStyle
    var line: PrompterStyle.Line
    var font: Font
    var fontSize: CGFloat
    var onTap: () -> Void

    var body: some View {
        Text(word.text)
            .font(font)
            .foregroundStyle(PrompterStyle.color(for: word, style: style, line: line))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PrompterGeometry.spaceWidth(fontSize: fontSize) / 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// The three lines: previous, current, next. Nothing scrolls or fades: a new line is simply in place.
struct PrompterTextView: View {
    @ObservedObject var model: PrompterModel
    var textWidth: CGFloat
    var fontSize: Double
    var scale: CGFloat

    var body: some View {
        let current = PrompterIslandType.current(fontSize: fontSize, scale: scale)
        let other = PrompterIslandType.other(fontSize: fontSize, scale: scale)
        let words = model.page.words
        // Lines break as if every word were in the current line (the largest type), so no line is ever too wide.
        let layout = PrompterLayout.make(wordWidths: PrompterTextMeasure.widths(of: words.map(\.text), fontSize: current),
                                         spaceWidth: PrompterGeometry.spaceWidth(fontSize: current), maxWidth: textWidth)
        let ranges = model.wordRanges
        let window = PrompterLineWindow(currentLine: layout.line(ofWordPosition: Double(ranges.read.count)), lineCount: layout.lines.count)
        VStack(alignment: .leading, spacing: 8) {
            row(window.previous, role: .previous, layout: layout, ranges: ranges, words: words, size: other,
                font: .system(size: other, weight: .medium))
            row(window.current, role: .current, layout: layout, ranges: ranges, words: words, size: current,
                font: .system(size: current, weight: .semibold))
            row(window.next, role: .next, layout: layout, ranges: ranges, words: words, size: other,
                font: .system(size: other, weight: .medium))
        }
        .frame(width: textWidth, alignment: .leading)
    }

    @ViewBuilder private func row(_ index: Int?, role: PrompterStyle.Line, layout: PrompterLayout, ranges: PrompterWordRanges,
                                  words: [PromptWord], size: CGFloat, font: Font) -> some View {
        let height = (size * 1.2).rounded()
        if let index, layout.lines.indices.contains(index) {
            HStack(spacing: 0) {
                ForEach(layout.lines[index], id: \.self) { wordIndex in
                    PrompterWordView(word: words[wordIndex], style: ranges.style(ofWord: wordIndex), line: role, font: font, fontSize: size) {
                        Task { @MainActor in await model.jump(toWord: wordIndex) }
                    }
                }
            }
            .padding(.leading, -PrompterGeometry.spaceWidth(fontSize: size) / 2)
            .tracking(role == .current ? -0.4 : 0)
            .frame(width: textWidth, height: height, alignment: .leading)
        } else {
            Color.clear.frame(width: textWidth, height: height)
        }
    }
}

struct PrompterIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VT.Island.primary)
                .frame(width: 30, height: 26)
                .background(VT.Island.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip + 1, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The prompter in the island (spec 3.2, state 7): three lines under the band, a one-line notice, the controls. The glass
/// is the island's (`OverlayView` draws it); this view is only content on it.
struct PrompterPanelView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject var settings: PrompterSettings
    var width: CGFloat
    var scale: CGFloat = 1

    private var inset: CGFloat { VT.Radius.islandShoulder + 26 }

    var body: some View {
        VStack(spacing: 0) {
            PrompterTextView(model: model, textWidth: width - 2 * inset, fontSize: settings.fontSize, scale: scale)
                .scaleEffect(x: settings.mirror ? -1 : 1, y: 1)
                .padding(.horizontal, inset)
                .padding(.top, 14)
            if let hint = model.hint {
                Text(hint.text)
                    .font(VT.Font.meta)
                    .foregroundStyle(hint.isWarning ? PrompterStyle.warning : VT.Island.tertiary)
                    .lineLimit(1)
                    .padding(.top, 6)
                    .accessibilityIdentifier("verse.prompter.hint")
            }
            controls
                .padding(.horizontal, VT.islandCardInset - 6)   // the buttons' own 6 pt inner margin lines up with the text
                .padding(.top, 10)
                .padding(.bottom, 20)
        }
        .frame(width: width)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.prompter")
    }

    private var controls: some View {
        let state = model.state
        return HStack(spacing: 6) {
            PrompterIconButton(symbol: "chevron.left", help: "Previous page  \(PrompterCommand.previousPage.shortcut)") { model.send(.previousPage) }
            PrompterIconButton(symbol: state.isPaused || state.isDone ? "play.fill" : "pause.fill",
                               help: "Start / pause  \(PrompterCommand.toggle.shortcut)") { model.send(.toggle) }
            PrompterIconButton(symbol: "chevron.right", help: "Next page  \(PrompterCommand.nextPage.shortcut)") { model.send(.nextPage) }
            Spacer(minLength: 8)
            PrompterIconButton(symbol: "minus", help: "Slower  \(PrompterCommand.slower.shortcut)") { model.send(.slower) }
            Text("\(Int(state.wordsPerMinute.rounded())) wpm")
                .font(VT.Font.meta.monospacedDigit())
                .foregroundStyle(state.mode == .wordTracking ? VT.Island.quaternary : VT.Island.secondary)
                .frame(minWidth: 52)
            PrompterIconButton(symbol: "plus", help: "Faster  \(PrompterCommand.faster.shortcut)") { model.send(.faster) }
            PrompterIconButton(symbol: "xmark", help: "Close the prompter  \(PrompterCommand.close.shortcut)") { model.send(.close) }
                .padding(.leading, 6)
        }
    }
}

extension PrompterMode {
    /// The word in the island's left wing.
    var wingName: String {
        switch self {
        case .wordTracking: return "tracking"
        case .voicePaced: return "voice"
        case .classic: return "classic"
        }
    }

    var shortName: String {
        switch self {
        case .wordTracking: return "Tracking"
        case .voicePaced: return "Voice-paced"
        case .classic: return "Classic"
        }
    }
}
