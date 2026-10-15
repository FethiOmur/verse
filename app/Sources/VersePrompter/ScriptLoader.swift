import Foundation

/// Script files: `.md` / `.txt` are parsed with `ScriptParser`; `.pptx` speaker notes become one page per slide
/// that has notes. Keynote is out of scope.
public enum ScriptLoader {
    public enum LoadError: Error, LocalizedError, Equatable {
        case unsupportedType(String)
        case unreadable(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): return "Cannot import .\(ext) files. Use .md, .txt or .pptx."
            case .unreadable(let detail): return "Could not read the file: \(detail)"
            case .empty: return "The file has no readable text."
            }
        }
    }

    public static func load(from url: URL) throws -> PromptScript {
        let ext = url.pathExtension.lowercased()
        let script: PromptScript
        switch ext {
        case "md", "markdown", "txt", "text":
            let text: String
            do { text = try String(contentsOf: url, encoding: .utf8) } catch {
                throw LoadError.unreadable(error.localizedDescription)
            }
            script = ScriptParser.parse(text)
        case "pptx":
            script = PromptScript(pages: try PresentationNotesExtractor.extractNotes(from: url).map { PromptPage(text: $0) })
        default:
            throw LoadError.unsupportedType(ext)
        }
        guard !script.isEmpty else { throw LoadError.empty }
        return script
    }
}

/// Scripts saved as `.md` in one directory. The app passes `~/Library/Application Support/Verse/scripts/`;
/// tests pass a temporary one. Nothing else is written.
public struct ScriptStore: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let modified: Date
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// File-system safe stem: path separators and control characters become "-"; never empty.
    static func stem(for name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".md") { s = String(s.dropLast(3)) }
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { bad.contains($0) ? "-" : $0 }))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return s.isEmpty ? "untitled" : s
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(Self.stem(for: name)).appendingPathExtension("md")
    }

    @discardableResult
    public func write(_ text: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: name)
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    public func read(name: String) throws -> String {
        try String(contentsOf: url(for: name), encoding: .utf8)
    }

    /// Newest first.
    public func list() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return urls.filter { $0.pathExtension.lowercased() == "md" }.map { u in
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Entry(name: u.deletingPathExtension().lastPathComponent, url: u, modified: date)
        }.sorted { $0.modified > $1.modified }
    }
}
