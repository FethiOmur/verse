import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VersePrompter

/// The script editor window: saved scripts on the left, the text on the right. Paste works in the text. Import reads
/// .md / .txt / .pptx notes, "Write with Verse…" asks the brain for a script, "Read" starts the prompter.
public struct ScriptEditorView: View {
    @ObservedObject var controller: VerseController
    @ObservedObject var prompter: PrompterModel
    @ObservedObject var editor: ScriptEditorModel
    @State private var showWriter = false

    public init(controller: VerseController) {
        self.controller = controller
        prompter = controller.prompter
        editor = controller.prompter.editor
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            main
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $showWriter) {
            WriteWithVerseSheet(editor: editor, isPresented: $showWriter)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scripts").font(.headline)
                Spacer()
                Button { editor.newScript() } label: { Image(systemName: "square.and.pencil") }
                    .help("New script")
                    .accessibilityLabel("New script")
            }
            .padding(12)
            List {
                ForEach(editor.entries, id: \.url) { entry in
                    Button { editor.open(entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if editor.entries.isEmpty { Text("No saved scripts yet").foregroundStyle(.secondary).font(.callout) }
            }
        }
        .frame(width: 200)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                if editor.isDirty { Text("Unsaved").font(.caption).foregroundStyle(.secondary) }
            }
            TextEditor(text: $editor.text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if editor.text.isEmpty {
                        Text("Paste or type your script. A line with only --- between blank lines starts a new page. [Notes in brackets] are shown but not tracked.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            if let message = editor.message {
                HStack {
                    Text(message.text).font(.callout).foregroundStyle(message.isError ? Color.red : .secondary)
                    if editor.previousText != nil {
                        Button("Restore previous text") { editor.restorePreviousText() }.buttonStyle(.link)
                    }
                }
            }
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import…", action: importFile)
                Button("Write with Verse…") { showWriter = true }
                    .disabled(editor.isWriting)
                Button("Save") { editor.save() }
                    .keyboardShortcut("s")
                    .disabled(!editor.isDirty)
                Button("Read") { read() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.script.isEmpty)
                    .help("Save and start the prompter")
            }
        }
        .padding(14)
    }

    private var summary: String {
        let seconds = editor.readingSeconds(wordsPerMinute: prompter.settings.wordsPerMinute)
        let pages = editor.pageCount
        return "\(editor.wordCount) words · \(pages) page\(pages == 1 ? "" : "s") · about \(seconds / 60):\(String(format: "%02d", seconds % 60)) at \(Int(prompter.settings.wordsPerMinute)) wpm"
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

    private static let lengths = [30, 60, 90, 120, 180, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write with Verse").font(.headline)
            Text("What is it about? Say what you want to get across, in your own words. Verse writes it the way you talk.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $topic)
                .font(.system(size: 14))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Picker("Length", selection: $seconds) {
                    ForEach(Self.lengths, id: \.self) { s in Text(s < 60 ? "\(s) s" : "\(s / 60) min\(s % 60 == 0 ? "" : " 30 s")").tag(s) }
                }
                Picker("For", selection: $use) {
                    ForEach(ScriptUse.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                if editor.isWriting { ProgressView().controlSize(.small); Text("Writing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.isWriting)
                Button("Write") {
                    let topic = topic, seconds = seconds, use = use
                    Task { @MainActor in
                        await editor.write(topic: topic, seconds: seconds, use: use)
                        if editor.message?.isError == false { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.isWriting)
            }
            if let message = editor.message, message.isError {
                Text(message.text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
