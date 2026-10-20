import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VersePrompter

/// The home window's Scripts page: saved scripts on the left, the open script on a reading plate. Paste works in the
/// text. Import reads .md / .txt / .pptx notes, "Write with Verse" asks the brain for a script, "Present" starts the
/// prompter. It replaces the "Teleprompter Scripts" window.
public struct ScriptEditorView: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var prompter: PrompterModel
    @ObservedObject var editor: ScriptEditorModel
    @State private var showWriter = false
    @State private var stats: [URL: String] = [:]
    @Environment(\.homeInk) private var ink

    public init(controller: VerseController) {
        self.controller = controller
        prompter = controller.prompter
        editor = controller.prompter.editor
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list
            main
        }
        .sheet(isPresented: $showWriter) {
            WriteWithVerseSheet(editor: editor, isPresented: $showWriter).environment(\.homeInk, ink)
        }
        .task(id: editor.entries) { stats = Self.stats(for: editor.entries) }
        .accessibilityIdentifier("verse.home.scripts")
    }

    // MARK: list

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Scripts", bundle: .module).font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                Spacer()
                Button { editor.newScript() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium)).foregroundStyle(ink.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(Text("New script", bundle: .module))
                .accessibilityLabel(Text("New script", bundle: .module))
            }
            .padding(.leading, 10).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.entries, id: \.url) { entry in
                        Button { editor.open(entry) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(1)
                                Text(stats[entry.url] ?? entry.modified.formatted(.relative(presentation: .named)))
                                    .font(VT.Font.callout).foregroundStyle(ink.secondary).monospacedDigit().lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(entry.name == editor.name ? ink.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if editor.entries.isEmpty {
                        Text("No saved scripts yet", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.tertiary).padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: 236).padding(.leading, 18).padding(.top, 22)
    }

    /// "212 words · 1:35" at the prompter's reading speed.
    private static func stats(for entries: [ScriptStore.Entry]) -> [URL: String] {
        var out: [URL: String] = [:]
        for e in entries {
            guard let text = try? String(contentsOf: e.url, encoding: .utf8) else { continue }
            let words = ScriptParser.parse(text).totalWordCount
            let seconds = Int((Double(words) / 140 * 60).rounded())
            out[e.url] = "\(L10n.tr("\(words) words")) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
        return out
    }

    // MARK: editor

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("", text: $editor.name, prompt: Text("Name", bundle: .module).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .bold)).foregroundStyle(ink.primary)
                if editor.isDirty { Text("Unsaved", bundle: .module).font(VT.Font.caption).foregroundStyle(ink.tertiary) }
                Spacer(minLength: 8)
                HomeSecondaryButton("Write with Verse") { showWriter = true }.disabled(editor.isWriting)
                HomePrimaryButton("Present", hint: "⌘P", shortcut: KeyboardShortcut("p"), action: read)
                    .disabled(editor.script.isEmpty)
                    .help(Text("Save and start the prompter", bundle: .module))
            }
            HomeGroup(plate: true) {
                TextEditor(text: $editor.text)
                    .font(.system(size: 15)).lineSpacing(5).foregroundStyle(ink.primary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 17).padding(.vertical, 14)
                    .overlay(alignment: .topLeading) {
                        if editor.text.isEmpty {
                            Text("Paste or type your script. A line with only --- between blank lines starts a new page. [Notes in brackets] are shown but not tracked.", bundle: .module)
                                .font(.system(size: 15)).foregroundStyle(ink.tertiary)
                                .padding(.horizontal, 22).padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = editor.message {
                HStack {
                    HomeNote(verbatim: message.text, isError: message.isError)
                    if editor.previousText != nil {
                        Button { editor.restorePreviousText() } label: { Text("Restore previous text", bundle: .module) }.buttonStyle(.link)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(summary).font(VT.Font.callout).foregroundStyle(ink.tertiary)
                Spacer()
                HomeSecondaryButton("Import…", action: importFile)
                HomeSecondaryButton("Save") { editor.save() }
                    .keyboardShortcut("s")
                    .disabled(!editor.isDirty)
            }
        }
        .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26).padding(.bottom, 24)
    }

    private var summary: String {
        let seconds = editor.readingSeconds(wordsPerMinute: prompter.settings.wordsPerMinute)
        let pages = editor.pageCount
        let clock = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        var parts = [L10n.tr("\(editor.wordCount) words"), L10n.tr("\(pages) pages"),
                     L10n.tr("about \(clock) at \(Int(prompter.settings.wordsPerMinute)) wpm")]
        if !editor.isDirty { parts.append(L10n.tr("saved")) }
        return parts.joined(separator: " · ")
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["md", "markdown", "txt", "pptx"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        if panel.runModal() == .OK, let url = panel.url { editor.importFile(url) }
    }

    private func read() {
        if editor.isDirty { editor.save() }
        let text = editor.text
        Task { @MainActor in await controller.readScript(text) }
    }
}

/// Topic, length and use; the brain's script fills the editor.
struct WriteWithVerseSheet: View {
    @ObservedObject var editor: ScriptEditorModel
    @Binding var isPresented: Bool
    @State private var topic = ""
    @State private var seconds = 60
    @State private var use = ScriptUse.recording
    @Environment(\.homeInk) private var ink

    private static let lengths = [30, 60, 90, 120, 180, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write with Verse", bundle: .module).font(VT.Font.title).foregroundStyle(ink.primary)
            Text("What is it about? Say what you want to get across, in your own words. Verse writes it the way you talk.", bundle: .module)
                .font(VT.Font.callout).foregroundStyle(ink.secondary)
            HomeGroup(plate: true) {
                HomeTextArea(text: $topic, placeholder: "The point, the audience, anything you want in it.", minHeight: 110, font: .system(size: 14))
                    .padding(14)
            }
            HomeGroup {
                HomeRow("Length") {
                    HomePopup(selection: $seconds, options: Self.lengths.map { s in
                        HomeOption(verbatim: s < 60 ? L10n.tr("\(s) s") : (s % 60 == 0 ? L10n.tr("\(s / 60) min") : L10n.tr("\(s / 60) min 30 s")), s)
                    })
                }
                HomeRowDivider()
                HomeRow("For") { HomeSegmented(verbatim: ScriptUse.allCases.map { ($0.title, $0) }, selection: $use) }
            }
            HStack(spacing: 8) {
                if editor.isWriting { ProgressView().controlSize(.small); Text("Writing…", bundle: .module).font(VT.Font.callout).foregroundStyle(ink.secondary) }
                Spacer()
                HomeSecondaryButton("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.isWriting)
                HomePrimaryButton("Write", shortcut: .defaultAction) {
                    let topic = topic, seconds = seconds, use = use
                    Task { @MainActor in
                        await editor.write(topic: topic, seconds: seconds, use: use)
                        if editor.message?.isError == false { isPresented = false }
                    }
                }
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.isWriting)
            }
            if let message = editor.message, message.isError { HomeNote(verbatim: message.text, isError: true) }
        }
        .padding(20)
        .frame(width: 480)
        .background(ink.background)
    }
}
