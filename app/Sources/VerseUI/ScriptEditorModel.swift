import Combine
import Foundation
import VersePrompter

extension ScriptStore {
    /// `~/Library/Application Support/Verse/scripts/`
    public static var appDefault: ScriptStore {
        ScriptStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Verse/scripts", isDirectory: true))
    }
}

/// The script editor's state: one open script, the saved ones, import, and "Write with Verse". Files go through
/// `ScriptStore`; nothing else is written.
@MainActor
public final class ScriptEditorModel: ObservableObject {
    public enum Message: Equatable {
        case info(String)
        case error(String)
        public var text: String { switch self { case .info(let t), .error(let t): return t } }
        public var isError: Bool { if case .error = self { return true }; return false }
    }

    public static let untitled = "Untitled"

    public let store: ScriptStore
    private let writer: any ScriptWriting

    @Published public var name = ScriptEditorModel.untitled
    /// Parsed once per change (review V11: the view used to parse it four times per keystroke).
    @Published public var text = "" {
        didSet { if text != oldValue { script = ScriptParser.parse(text) } }
    }
    @Published public private(set) var entries: [ScriptStore.Entry] = []
    @Published public private(set) var message: Message?
    @Published public private(set) var isWriting = false
    /// The text before the last "Write with Verse", "New script", a click on a saved script or an import replaced it, so
    /// one click brings it back (review V5: unsaved text used to be lost without a word).
    @Published public private(set) var previousText: String?
    /// The script the replaced text belonged to, when the replacement opened another script; restored with the text so a
    /// later Save goes to the right file.
    private var previousDocument: (name: String, savedFile: String?)?

    private var savedText = ""
    /// File name (`x.md`) the open text was loaded from or saved to; nil for a script never saved.
    private var savedFile: String?

    public init(store: ScriptStore, writer: any ScriptWriting) {
        self.store = store
        self.writer = writer
        reload()
    }

    // MARK: state

    public private(set) var script = ScriptParser.parse("")
    public var wordCount: Int { script.totalWordCount }
    public var pageCount: Int { script.pages.count }

    /// Unsaved changes: other text, or a name that points at another file.
    public var isDirty: Bool {
        text != savedText || (savedFile != nil && store.url(for: name).lastPathComponent != savedFile)
    }

    public func readingSeconds(wordsPerMinute: Double) -> Int {
        Int((Double(wordCount) / max(wordsPerMinute, 1) * 60).rounded())
    }

    // MARK: files

    public func reload() {
        entries = (try? store.list()) ?? []
    }

    public func newScript() {
        let setAside = setAsideUnsavedText()
        name = Self.untitled
        text = ""
        savedText = ""
        savedFile = nil
        announce(setAside)
    }

    /// Before another script replaces the open one: unsaved text is kept for "Restore previous text".
    private func setAsideUnsavedText() -> Bool {
        guard isDirty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previousText = nil
            previousDocument = nil
            return false
        }
        previousText = text
        previousDocument = (name, savedFile)
        return true
    }

    private func announce(_ setAside: Bool) {
        message = setAside ? .info(L10n.tr("Unsaved text replaced")) : nil
    }

    public func open(_ entry: ScriptStore.Entry) {
        do {
            let loaded = try store.read(name: entry.name)
            let setAside = setAsideUnsavedText()
            name = entry.name
            text = loaded
            savedText = loaded
            savedFile = store.url(for: entry.name).lastPathComponent
            announce(setAside)
        } catch {
            message = .error(L10n.tr("Could not open \(entry.name): \(error.localizedDescription)"))
        }
    }

    /// Saves under `name`. A script that was never saved never overwrites an existing file: it gets " 2", " 3", ...
    @discardableResult
    public func save() -> Bool {
        var target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { target = Self.untitled }
        if savedFile == nil {
            var candidate = target
            var n = 2
            while FileManager.default.fileExists(atPath: store.url(for: candidate).path) {
                candidate = "\(target) \(n)"
                n += 1
            }
            target = candidate
        }
        do {
            let url = try store.write(text, name: target)
            name = url.deletingPathExtension().lastPathComponent
            savedText = text
            savedFile = url.lastPathComponent
            reload()
            message = .info(L10n.tr("Saved \(url.lastPathComponent)"))
            return true
        } catch {
            message = .error(L10n.tr("Could not save: \(error.localizedDescription)"))
            return false
        }
    }

    /// `.md` / `.txt` keep their paragraphs; `.pptx` becomes one page per slide with notes. The result replaces the
    /// editor's text (unsaved, until Save).
    public func importFile(_ url: URL) {
        do {
            let script = try ScriptLoader.load(from: url)
            let ext = url.pathExtension.lowercased()
            let imported = ["md", "markdown", "txt", "text"].contains(ext)
                ? try String(contentsOf: url, encoding: .utf8)
                : script.pages.map(\.text).joined(separator: "\n\n---\n\n")
            _ = setAsideUnsavedText()   // the import's own message below; the restore link shows next to it
            text = imported
            name = url.deletingPathExtension().lastPathComponent
            savedText = ""
            savedFile = nil
            message = .info(L10n.tr("Imported \(url.lastPathComponent): \(L10n.tr("\(script.totalWordCount) words")), \(L10n.tr("\(script.pages.count) pages"))"))
        } catch {
            FileLog.shared.write("scripts: import of \(url.lastPathComponent) failed: \(error.localizedDescription)")
            message = .error(Self.importErrorText(error))
        }
    }

    /// An import failure in the interface language (the loaders' own texts are English, for the log; review V13).
    static func importErrorText(_ error: any Error, locale: Locale? = nil) -> String {
        switch error {
        case ScriptLoader.LoadError.unsupportedType(let ext): return L10n.tr("Cannot import .\(ext) files. Use .md, .txt or .pptx.", locale: locale)
        case ScriptLoader.LoadError.unreadable: return L10n.tr("Could not read the file.", locale: locale)
        case ScriptLoader.LoadError.empty: return L10n.tr("The file has no readable text.", locale: locale)
        case PresentationNotesExtractor.ExtractionError.unsupportedFormat: return L10n.tr("Only .pptx speaker notes can be imported.", locale: locale)
        case PresentationNotesExtractor.ExtractionError.extractionFailed: return L10n.tr("Could not read the presentation's notes.", locale: locale)
        case PresentationNotesExtractor.ExtractionError.noNotesFound: return L10n.tr("No presenter notes found in this presentation.", locale: locale)
        default: return L10n.tr("Could not import the file.", locale: locale)
        }
    }

    // MARK: Write with Verse (T3)

    public func write(topic: String, seconds: Int, use: ScriptUse) async {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWriting else { return }
        isWriting = true
        message = .info(L10n.tr("Verse is writing…"))
        defer { isWriting = false }
        do {
            let draft = try await writer.write(topic: trimmed, seconds: seconds, use: use)
            previousText = text.isEmpty ? nil : text
            previousDocument = nil   // only the text is replaced; the script stays the same one
            text = draft.text
            if savedFile == nil, name == Self.untitled || name.isEmpty { name = Self.title(fromTopic: trimmed) }
            var note = L10n.tr("Verse wrote \(L10n.tr("\(draft.words) words")) on \(L10n.tr("\(draft.pages) pages"))")
            if !draft.usedVoiceProfile { note += L10n.tr(" (no voice profile found)") }
            if let warning = draft.warnings.first(where: { !$0.hasPrefix("no voice profile") }) { note += ". \(warning)" }
            message = .info(note)
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    /// Brings back the replaced text, and with it the script it belonged to when another one was opened over it.
    public func restorePreviousText() {
        guard let previous = previousText else { return }
        if let document = previousDocument {
            name = document.name
            savedFile = document.savedFile
            // What that file holds now, so "Unsaved" stays true to the disk.
            savedText = document.savedFile.flatMap { file in
                try? String(contentsOf: store.url(for: document.name).deletingLastPathComponent().appendingPathComponent(file),
                            encoding: .utf8)
            } ?? ""
        }
        text = previous
        previousText = nil
        previousDocument = nil
        message = .info(L10n.tr("Previous text restored"))
    }

    /// First words of the topic, as a file name.
    static func title(fromTopic topic: String) -> String {
        let words = topic.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let title = words.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"' "))
        return title.isEmpty ? untitled : String(title.prefix(60))
    }
}
