import SwiftUI

/// The rules of the in-app Stop controls (island and home window): one place, so both agree with the menu-bar item.
enum SessionStop {
    /// Stop is offered while a session runs and is not already stopping.
    static func canStop(running: Bool, stopping: Bool) -> Bool { running && !stopping }
    static func title(stopping: Bool) -> String { stopping ? L10n.tr("Stopping…") : L10n.tr("Stop") }
    /// What VoiceOver reads on the button (the visible text stays short).
    static func accessibilityLabel(stopping: Bool) -> String { stopping ? L10n.tr("Stopping session") : L10n.tr("Stop session") }
}

/// The island's Stop button: the neutral glass button (never the accent, never red) with a square stop glyph alone; the
/// words live in its tooltip and accessibility label. `compact` is the smaller capsule, for the band's wing on the bare
/// capsule.
struct IslandStopButton: View {
    var stopping: Bool
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            IslandControlGlyph(symbol: "stop.fill", compact: compact)
        }
        .buttonStyle(IslandControlButtonStyle(compact: compact))
        .disabled(stopping)
        .opacity(stopping ? 0.6 : 1)
        .help(Text("Stop the session", bundle: .module))
        .accessibilityLabel(SessionStop.accessibilityLabel(stopping: stopping))
        .accessibilityIdentifier("verse.island.stop")
    }
}

/// Back to an earlier answer, forward to a newer one, or forward back to the live card: the same neutral icon button as
/// Stop, beside it.
struct IslandHistoryButton: View {
    enum Direction { case back, forward, live }
    var direction: Direction
    var enabled: Bool
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            IslandControlGlyph(symbol: direction == .back ? "chevron.backward" : "chevron.forward", compact: compact)
        }
        .buttonStyle(IslandControlButtonStyle(compact: compact))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(direction == .back ? "verse.island.back" : "verse.island.forward")
    }

    private var label: Text {
        switch direction {
        case .back: return Text("Show the earlier answer", bundle: .module)
        case .forward: return Text("Show the newer answer", bundle: .module)
        case .live: return Text("Back to the live answer", bundle: .module)
        }
    }

    private var help: Text {
        switch direction {
        case .back: return Text("Earlier answer (⌥⌘← or ⇧<)", bundle: .module)
        case .forward: return Text("Newer answer (⌥⌘→)", bundle: .module)
        case .live: return Text("Live answer (⌥⌘→)", bundle: .module)
        }
    }
}

/// Regenerate: a new answer to the question on screen (⌥⌘R). The same neutral icon button; dimmed and inert while a new answer is
/// on its way.
struct IslandRegenerateButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            IslandControlGlyph(symbol: "arrow.clockwise", compact: false)
        }
        .buttonStyle(IslandControlButtonStyle(compact: false))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(Text("New answer to this question (⌥⌘R)", bundle: .module))
        .accessibilityLabel(Text("New answer to this question", bundle: .module))
        .accessibilityIdentifier("verse.island.regenerate")
    }
}

/// BAD on the answer on screen (⌥⌘↓). The same neutral icon button; a marked card shows the filled glyph (no colour, no badge),
/// and pressing it again clears the mark.
struct IslandMarkButton: View {
    var mark: CardMark
    var marked: Bool
    var action: () -> Void

    static func symbol(_ mark: CardMark, marked: Bool) -> String {
        marked ? "hand.thumbsdown.fill" : "hand.thumbsdown"
    }

    var body: some View {
        Button(action: action) {
            IslandControlGlyph(symbol: Self.symbol(mark, marked: marked), compact: false)
        }
        .buttonStyle(IslandControlButtonStyle(compact: false))
        .help(marked ? Text("Marked bad. Press again to clear (⌥⌘↓)", bundle: .module) : Text("Bad answer (⌥⌘↓)", bundle: .module))
        .accessibilityLabel(Text("Mark the answer bad", bundle: .module))
        .accessibilityValue(marked ? Text("Marked", bundle: .module) : Text(verbatim: ""))
        .accessibilityAddTraits(marked ? .isSelected : [])
        .accessibilityIdentifier("verse.island.markBad")
    }
}

/// The glyph of an island control button: 26 × 22 on a capsule in the wing, the plain glyph in the card's control row
/// (the style draws its plate).
private struct IslandControlGlyph: View {
    var symbol: String
    var compact: Bool

    var body: some View {
        if compact {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(VT.Island.primary)
                .frame(width: 26, height: 22)
                .background(VT.Island.fillStrong, in: Capsule())
                .contentShape(Capsule())
        } else {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 12)
        }
    }
}

private struct IslandControlButtonStyle: ButtonStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
        } else {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VT.Island.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(VT.Island.fillStrong, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
        }
    }
}
