import AppKit
import SwiftUI

/// The brief on-screen notice of dictation, for a couple of seconds.
///
/// Most notices show in the dictation island under the notch (`island`, `DictationNotice.showsInIsland`), in the island's
/// status type. The two that come while a meeting or another run holds the notch use a small capsule near the top of the
/// screen instead: the meeting island's state belongs to the meeting and the practice interview, so putting them there would
/// change what the meeting shows. That panel never becomes key or active (the app in front keeps the keyboard focus the text
/// is pasted into) and ignores the mouse. One panel, made on the first such notice and reused.
@MainActor
final class DictationHUD: DictationNotifying {
    static let duration: Duration = .milliseconds(2600)
    /// Below the top of the visible frame when the recording indicator is not on screen.
    static let topGap: CGFloat = 24
    /// Between the recording indicator and a notice under it.
    static let indicatorGap: CGFloat = 8

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// The recording indicator's frame while it is on screen (gap G5): a notice goes below it, never on top of it.
    var avoid: (() -> NSRect?)?
    /// The dictation island; nil: every notice uses the capsule.
    weak var island: DictationIndicatorPanel?

    func show(_ notice: DictationNotice) {
        if notice.showsInIsland, let island {
            island.show(notice, for: Self.duration)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: DictationNoticeView(text: notice.text))
        panel.contentView = host
        place(panel, size: host.fittingSize)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    /// The indicator appeared or grew: a notice on screen it would cover moves below it. One it does not cover stays put
    /// (also when the indicator goes, so a notice never jumps while it is read).
    func reposition() {
        guard let panel, panel.isVisible, let r = avoid?(), panel.frame.maxY > r.minY - Self.indicatorGap else { return }
        place(panel, size: panel.frame.size)
    }

    private func place(_ panel: NSPanel, size: CGSize) {
        guard let main = NSScreen.main else { return }
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        panel.setFrame(Self.frame(size: size, screens: screens, mainVisible: main.visibleFrame, avoid: avoid?()), display: true)
        panel.invalidateShadow()
    }

    /// The notice's frame: top centre of the main screen, or, while the recording indicator is on screen, under it on the
    /// screen the indicator is on (the main screen may have changed since the indicator appeared).
    static func frame(size: CGSize, screens: [(frame: NSRect, visible: NSRect)], mainVisible: NSRect, avoid: NSRect?) -> NSRect {
        var f = mainVisible
        if let r = avoid, let s = screens.first(where: { $0.frame.intersects(r) }) { f = s.visible }
        var y = f.maxY - size.height - topGap
        if let r = avoid { y = min(y, r.minY - indicatorGap - size.height) }
        return NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height)
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
