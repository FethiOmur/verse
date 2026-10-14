import Foundation

/// Small, dependency-free HTML to readable-text helpers. Not a full parser: it handles the shapes job
/// boards emit (paragraphs, headings, lists, line breaks, entities) and drops everything else.
enum HTMLText {
    static func plain(_ html: String) -> String {
        var s = html
        s = sub(s, "<!--.*?-->", "")
        s = sub(s, "<(script|style|noscript|svg|template|iframe)\\b[^>]*>.*?</\\1\\s*>", "")
        s = sub(s, "<br\\s*/?>", "\n")
        s = sub(s, "<li\\b[^>]*>", "\n- ")
        s = sub(s, "</li\\s*>", "")
        s = sub(s, "</?(p|div|h[1-6]|section|article|ul|ol|table|tr|blockquote|pre|header|footer|hr)\\b[^>]*>", "\n\n")
        s = sub(s, "<[^>]+>", "")
        return normalise(decodeEntities(s))
    }

    /// Whitespace, bullet and blank-line clean-up shared by every source (and by `pasted`). No length cap here.
    static func normaliseLines(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{200B}", with: "")
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = sub(String(raw), "[ \\t\\x{2009}\\x{202F}]+", " ").trimmingCharacters(in: .whitespaces)
            line = sub(line, "^[•◦▪●·▫‣∙*–]\\s+", "- ")
            line = sub(line, "^-(?=\\S)(?![-\\d])", "- ")
            lines.append(line)
        }
        // Collapse blank runs to one, and drop a blank line sandwiched between two bullets.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        var i = 1
        while i < out.count - 1 {
            if out[i].isEmpty, out[i - 1].hasPrefix("- "), out[i + 1].hasPrefix("- ") { out.remove(at: i) } else { i += 1 }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalise(_ text: String, limit: Int = PostingFetcher.maxCharacters) -> String {
        let s = normaliseLines(text)
        guard s.count > limit else { return s }
        var cut = String(s.prefix(limit))
        if let ws = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: ws, to: cut.endIndex) < 200 {
            cut = String(cut[..<ws])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
            "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•", "middot": "·",
            "euro": "€", "copy": "©", "reg": "®", "trade": "™", "laquo": "«", "raquo": "»",
        ]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    rep = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = named[name]
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// First capture group of the first match, or nil.
    static func capture(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func allCaptures(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } : nil
        }
    }
}
