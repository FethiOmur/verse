import AppKit
import SwiftUI

/// The brief on-screen notice of dictation: a small capsule near the top of the screen for a couple of seconds.
///
/// Its own panel, not the island: the island's state belongs to the meeting and the practice interview, and the "busy" notice
/// shows while a meeting runs, so putting it there would change what the meeting shows. The panel never becomes key or
/// active (the app in front keeps the keyboard focus the text is pasted into) and ignores the mouse. One panel, made on the
/// first notice and reused.
@MainActor
final class DictationHUD: DictationNotifying {
    static let duration: Duration = .milliseconds(2600)

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ notice: DictationNotice) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: DictationNoticeView(text: notice.text))
        let size = host.fittingSize
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }
}

private struct DictationNoticeView: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold))
            Text(verbatim: text).font(.system(size: 13, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
