import AppKit
import SwiftUI

/// The "New session from a conversation…" window: the pasted thread, an optional posting (link or text), the company
/// website, a note, then Prepare with progress, warnings and the result.
public struct ConversationSetupView: View {
    @ObservedObject var model: ConversationController

    public init(model: ConversationController) { self.model = model }

    private var locked: Bool { model.phase == .preparing }

    public var body: some View {
        // The form scrolls; the run bar stays at the bottom so Prepare, progress and the result are always in view.
        VStack(spacing: 0) {
            Form {
                threadSection
                postingSection
                moreSection
            }
            .formStyle(.grouped)
            Divider()
            runBar
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .frame(width: 600)
        .frame(minHeight: 600, idealHeight: 720)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    private var threadSection: some View {
        Section {
            editor($model.thread, height: 150)
            HStack {
                Text("\(model.thread.count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) { model.thread = s }
                }
                .disabled(locked)
            }
        } header: {
            Text("Conversation")
        } footer: {
            Text("Paste the LinkedIn or email thread. It stays on this Mac; only the model calls see it.")
        }
        .disabled(locked)
    }

    private var postingSection: some View {
        Section {
            HStack {
                TextField("Link", text: $model.postingLink, prompt: Text("Job posting link (optional)"))
                    .onSubmit(model.fetchPosting)
                if model.fetching { ProgressView().controlSize(.small) }
                Button("Fetch", action: model.fetchPosting)
                    .disabled(model.fetching || model.postingLink.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.posting != nil { Button("Clear", action: model.clearPosting) }
            }
            if let m = model.fetchMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
            if model.posting == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or paste the posting text").font(.callout).foregroundStyle(.secondary)
                    editor($model.postingPaste, height: 48)
                }
            }
        } header: {
            Text("Job posting")
        }
        .disabled(locked)
    }

    private var moreSection: some View {
        Section("More") {
            TextField("Company website", text: $model.companyURL, prompt: Text("example.com (optional)"))
            VStack(alignment: .leading, spacing: 6) {
                Text("Note (optional)").font(.callout).foregroundStyle(.secondary)
                editor($model.note, height: 44)
            }
        }
        .disabled(locked)
    }

    private var runBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .setup:
                HStack {
                    Button("Prepare", action: model.prepare)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canPrepare)
                    Spacer()
                }
                if let e = model.error { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let t0 = model.startedAt {
                        TimelineView(.periodic(from: t0, by: 1)) { ctx in
                            Text("Preparing · \(SimOverlay.elapsed(from: t0, now: ctx.date))").monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Cancel", action: model.cancelPrep)
                }
                if let l = model.lines.last(where: { !$0.hasPrefix("  ...") }) {
                    Text(l.trimmingCharacters(in: .whitespaces)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            case .done:
                if let s = model.summary {
                    Label("\(model.sessionDir?.lastPathComponent ?? "") is ready and selected", systemImage: "checkmark.circle.fill")
                    Text("\(s.company.isEmpty ? "Conversation" : s.company) · \(s.bankEntries) questions · \(s.searches) searches · "
                         + "\(s.sourced) sourced, \(s.unverified) unverified · \(String(format: "$%.2f", s.costUSD))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(model.warnings.prefix(3).enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if model.warnings.count > 3 {
                    Text("and \(model.warnings.count - 3) more in the session's meta.json").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show in Finder", action: model.revealSession)
                    Button("Another conversation", action: model.another)
                    Spacer()
                }
            }
        }
    }
}

/// The menu-bar block: opens the window.
public struct ConversationMenuBlock: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("New session from a conversation…") {
            NSApp.activate()
            openWindow(id: ConversationWindow.id)
        }
    }
}

public enum ConversationWindow {
    public static let id = "conversation-setup"
}
