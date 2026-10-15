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
    @Published public var text = ""
    @Published public private(set) var entries: [ScriptStore.Entry] = []
    @Published public private(set) var message: Message?
    @Published public private(set) var isWriting = false
    /// The text before the last "Write with Verse" replaced it, so one click brings it back.
    @Published public private(set) var previousText: String?

    private var savedText = ""
    /// File name (`x.md`) the open text was loaded from or saved to; nil for a script never saved.
    private var savedFile: String?

    public init(store: ScriptStore, writer: any ScriptWriting) {
        self.store = store
        self.writer = writer
        reload()
    }

    // MARK: state

    public var script: PromptScript { ScriptParser.parse(text) }
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
        name = Self.untitled
        text = ""
        savedText = ""
        savedFile = nil
        previousText = nil
        message = nil
    }

    public func open(_ entry: ScriptStore.Entry) {
        do {
            let loaded = try store.read(name: entry.name)
            name = entry.name
            text = loaded
            savedText = loaded
            savedFile = store.url(for: entry.name).lastPathComponent
            previousText = nil
            message = nil
        } catch {
            message = .error("Could not open \(entry.name): \(error.localizedDescription)")
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
            message = .info("Saved \(url.lastPathComponent)")
            return true
        } catch {
            message = .error("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    /// `.md` / `.txt` keep their paragraphs; `.pptx` becomes one page per slide with notes. The result replaces the
    /// editor's text (unsaved, until Save).
    public func importFile(_ url: URL) {
        do {
            let script = try ScriptLoader.load(from: url)
            let ext = url.pathExtension.lowercased()
            if ["md", "markdown", "txt", "text"].contains(ext) {
                text = try String(contentsOf: url, encoding: .utf8)
            } else {
                text = script.pages.map(\.text).joined(separator: "\n\n---\n\n")
            }
            name = url.deletingPathExtension().lastPathComponent
            savedText = ""
            savedFile = nil
            previousText = nil
            message = .info("Imported \(url.lastPathComponent): \(script.totalWordCount) words, \(script.pages.count) page\(script.pages.count == 1 ? "" : "s")")
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    // MARK: Write with Verse (T3)

    public func write(topic: String, seconds: Int, use: ScriptUse) async {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWriting else { return }
        isWriting = true
        message = .info("Verse is writing…")
        defer { isWriting = false }
        do {
            let draft = try await writer.write(topic: trimmed, seconds: seconds, use: use)
            previousText = text.isEmpty ? nil : text
            text = draft.text
            if savedFile == nil, name == Self.untitled || name.isEmpty { name = Self.title(fromTopic: trimmed) }
            var note = "Verse wrote \(draft.words) words on \(draft.pages) page\(draft.pages == 1 ? "" : "s")"
            if !draft.usedVoiceProfile { note += " (no voice profile found)" }
            if let warning = draft.warnings.first(where: { !$0.hasPrefix("no voice profile") }) { note += ". \(warning)" }
            message = .info(note)
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    /// Brings back the text that "Write with Verse" replaced.
    public func restorePreviousText() {
        guard let previous = previousText else { return }
        text = previous
        previousText = nil
        message = .info("Previous text restored")
    }

    /// First words of the topic, as a file name.
    static func title(fromTopic topic: String) -> String {
        let words = topic.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let title = words.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"' "))
        return title.isEmpty ? untitled : String(title.prefix(60))
    }
}
