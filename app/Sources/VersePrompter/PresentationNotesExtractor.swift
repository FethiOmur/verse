import Foundation

// Ported from Textream: Textream/PresentationNotesExtractor.swift (upstream commit 2c02f3e).
// MIT License, Copyright (c) 2026 Fatih Kadir Akin. Full text: THIRD_PARTY_NOTICES at the repo root.
// Changes for Verse: no AppKit import, Keynote messages removed, XMLParser delegate is a final class.
// Like upstream, slides with empty notes (or only a slide number) are skipped, so page n is not always slide n.

/// Reads speaker notes from a `.pptx` (a ZIP of XML files), one string per slide that has notes.
public enum PresentationNotesExtractor {
    public enum ExtractionError: Error, LocalizedError, Equatable {
        case unsupportedFormat
        case extractionFailed(String)
        case noNotesFound

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "Unsupported file format. Only .pptx speaker notes can be imported."
            case .extractionFailed(let detail): return "Failed to extract notes: \(detail)"
            case .noNotesFound: return "No presenter notes found in this presentation."
            }
        }
    }

    public static func extractNotes(from url: URL) throws -> [String] {
        guard url.pathExtension.lowercased() == "pptx" else { throw ExtractionError.unsupportedFormat }
        return try extractPPTXNotes(from: url)
    }

    private static func extractPPTXNotes(from url: URL) throws -> [String] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let localArchive = tempDir.appendingPathComponent("presentation.pptx")
        do {
            try fileManager.copyItem(at: url, to: localArchive)
        } catch {
            throw ExtractionError.extractionFailed("Could not read PPTX file.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", localArchive.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed("Could not unzip PPTX file.")
        }

        let notesDir = tempDir.appendingPathComponent("ppt/notesSlides")
        guard fileManager.fileExists(atPath: notesDir.path) else { throw ExtractionError.noNotesFound }

        let noteFiles = try fileManager.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" && $0.lastPathComponent.hasPrefix("notesSlide") }
            .sorted { (extractNumber(from: $0.lastPathComponent) ?? 0) < (extractNumber(from: $1.lastPathComponent) ?? 0) }

        var pages: [String] = []
        for noteFile in noteFiles {
            pages.append(PPTXNoteXMLParser(data: try Data(contentsOf: noteFile)).parse())
        }
        pages = pages.compactMap { page in
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && Int(trimmed) == nil else { return nil }
            return trimmed
        }
        guard !pages.isEmpty else { throw ExtractionError.noNotesFound }
        return pages
    }

    private static func extractNumber(from filename: String) -> Int? {
        Int(filename.filter { $0.isNumber })
    }
}

private final class PPTXNoteXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentText = ""
    private var insideBody = false
    private var insideTextRun = false
    private var insideParagraph = false
    private var skipPlaceholder = false

    init(data: Data) { self.data = data }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return paragraphs.joined(separator: "\n")
    }

    private func isElement(_ name: String, _ local: String) -> Bool { name == local || name.hasSuffix(":" + local) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if isElement(elementName, "sp") { skipPlaceholder = false }
        if isElement(elementName, "ph") {
            let type = attributes["type"] ?? ""
            if ["sldNum", "sldImg", "dt", "hdr", "ftr"].contains(type) { skipPlaceholder = true }
        }
        if isElement(elementName, "txBody") { insideBody = true }
        if isElement(elementName, "p") && insideBody && !skipPlaceholder {
            insideParagraph = true
            currentParagraph = ""
        }
        if isElement(elementName, "t") && insideParagraph {
            insideTextRun = true
            currentText = ""
        }
        if isElement(elementName, "br") && insideParagraph { currentParagraph += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTextRun { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if isElement(elementName, "t") && insideTextRun {
            insideTextRun = false
            currentParagraph += currentText
        }
        if isElement(elementName, "p") && insideParagraph {
            insideParagraph = false
            paragraphs.append(currentParagraph)
        }
        if isElement(elementName, "txBody") { insideBody = false }
        if isElement(elementName, "sp") { skipPlaceholder = false }
    }
}
