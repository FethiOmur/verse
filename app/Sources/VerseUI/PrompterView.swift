import SwiftUI
import VersePrompter

/// Colours of the prompter text. Read text is dimmed; upcoming text is full colour; `[cues]` are amber.
enum PrompterStyle {
    static let read = Color.white.opacity(0.30)
    static let upcoming = Color.white
    static let cue = Color(red: 1.0, green: 0.80, blue: 0.40)
    static let readCue = Color(red: 1.0, green: 0.80, blue: 0.40).opacity(0.30)
    static let warning = Color(red: 1.0, green: 0.80, blue: 0.40)

    static func color(for word: PromptWord, style: PrompterWordStyle) -> Color {
        switch (word.isCue, style) {
        case (false, .read): return read
        case (false, _): return upcoming
        case (true, .read): return readCue
        case (true, _): return cue
        }
    }
}

/// One word. A click anywhere in its slot (the word plus half a space on each side) jumps to it.
struct PrompterWordView: View {
    var word: PromptWord
    var style: PrompterWordStyle
    var fontSize: CGFloat
    var onTap: () -> Void

    var body: some View {
        Text(word.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(PrompterStyle.color(for: word, style: style))
            .lineLimit(1)
            .fixedSize()
            .overlay(alignment: .bottom) {
                if style == .current { Rectangle().fill(OverlayStyle.accent).frame(height: 2).offset(y: 3) }
            }
            .padding(.horizontal, PrompterGeometry.spaceWidth(fontSize: fontSize) / 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// The text block: lines of words, the current line held on the eye line, the read lines dimmed above it. Scrolling
/// is the block's offset only; no word fades or slides in.
struct PrompterTextView: View {
    @ObservedObject var model: PrompterModel
    var textWidth: CGFloat
    var fontSize: CGFloat

    var body: some View {
        let layout = model.layout(maxWidth: textWidth)
        let ranges = model.wordRanges
        let lineHeight = PrompterGeometry.lineHeight(fontSize: fontSize)
        let line = layout.line(ofWordPosition: Double(ranges.read.count))
        let words = model.page.words
        VStack(spacing: 0) {
            ForEach(Array(layout.lines.enumerated()), id: \.offset) { _, range in
                HStack(spacing: 0) {
                    ForEach(range, id: \.self) { index in
                        PrompterWordView(word: words[index], style: ranges.style(ofWord: index), fontSize: fontSize) {
                            Task { @MainActor in await model.jump(toWord: index) }
                        }
                    }
                }
                .frame(width: textWidth, height: lineHeight)
            }
        }
        .frame(width: textWidth, alignment: .top)
        .offset(y: PrompterGeometry.offset(forLine: line, lineHeight: lineHeight))
        .animation(.easeOut(duration: 0.16), value: line)
        .frame(width: textWidth, height: PrompterGeometry.viewportHeight(lineHeight: lineHeight), alignment: .top)
        .clipped()
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: PrompterGeometry.eyeLineY(lineHeight: lineHeight))
                Rectangle()
            }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The prompter inside the hanging glass panel, under the capsule band: the text, a one-line notice, the controls.
/// The glass itself is the panel's (`OverlayView` draws it); this view is only content on it.
struct PrompterPanelView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject var settings: PrompterSettings
    var width: CGFloat

    private let sidePadding: CGFloat = 24

    var body: some View {
        let fontSize = CGFloat(settings.fontSize)
        VStack(spacing: 0) {
            PrompterTextView(model: model, textWidth: width - 2 * sidePadding, fontSize: fontSize)
                .scaleEffect(x: settings.mirror ? -1 : 1, y: 1)
                .padding(.horizontal, sidePadding)
            if let hint = model.hint {
                Text(hint.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hint.isWarning ? PrompterStyle.warning : .white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.top, 2)
                    .accessibilityIdentifier("verse.prompter.hint")
            }
            controls
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
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
            Text("\(state.pageIndex + 1)/\(state.pageCount)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4)
            Spacer(minLength: 8)
            if state.isSpeaking { Circle().fill(OverlayStyle.accent).frame(width: 7, height: 7).accessibilityLabel("Hearing you") }
            Text(state.mode.shortName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 8)
            PrompterIconButton(symbol: "minus", help: "Slower  \(PrompterCommand.slower.shortcut)") { model.send(.slower) }
            Text("\(Int(state.wordsPerMinute.rounded())) wpm")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(state.mode == .wordTracking ? 0.4 : 0.8))
                .frame(minWidth: 52)
            PrompterIconButton(symbol: "plus", help: "Faster  \(PrompterCommand.faster.shortcut)") { model.send(.faster) }
            PrompterIconButton(symbol: "xmark", help: "Close the prompter  \(PrompterCommand.close.shortcut)") { model.send(.close) }
                .padding(.leading, 6)
        }
    }
}

extension PrompterMode {
    var shortName: String {
        switch self {
        case .wordTracking: return "Tracking"
        case .voicePaced: return "Voice-paced"
        case .classic: return "Classic"
        }
    }
}
