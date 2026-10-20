import SwiftUI

/// The rules of the in-app Stop controls (island and home window): one place, so both agree with the menu-bar item.
enum SessionStop {
    /// Stop is offered while a session runs and is not already stopping.
    static func canStop(running: Bool, stopping: Bool) -> Bool { running && !stopping }
    static func title(stopping: Bool) -> String { stopping ? L10n.tr("Stopping…") : L10n.tr("Stop") }
    /// What VoiceOver reads on the button (the visible text stays short).
    static func accessibilityLabel(stopping: Bool) -> String { stopping ? L10n.tr("Stopping session") : L10n.tr("Stop session") }
}

/// The island's Stop button: the neutral glass button (never the accent, never red), a square stop glyph and "Stop".
/// `compact` is the icon alone, for the band's wing on the bare capsule.
struct IslandStopButton: View {
    var stopping: Bool
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if compact {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VT.Island.primary)
                    .frame(width: 26, height: 22)
                    .background(VT.Island.fillStrong, in: Capsule())
                    .contentShape(Capsule())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    Text(SessionStop.title(stopping: stopping))
                }
            }
        }
        .buttonStyle(IslandStopButtonStyle(compact: compact))
        .disabled(stopping)
        .opacity(stopping ? 0.6 : 1)
        .help(Text("Stop the session", bundle: .module))
        .accessibilityLabel(SessionStop.accessibilityLabel(stopping: stopping))
        .accessibilityIdentifier("verse.island.stop")
    }
}

private struct IslandStopButtonStyle: ButtonStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
        } else {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VT.Island.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(VT.Island.fillStrong, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
        }
    }
}
