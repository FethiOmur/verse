import AppKit
import CoreGraphics
import VersePrompter

// What the prompter draws, as pure functions of `PrompterState`, the page and the font size. No SwiftUI here, so the
// mapping is testable without a window.

public enum PrompterWordStyle: Equatable, Sendable {
    /// Already said: dimmed.
    case read
    /// The word being read now (it sits on the eye line).
    case current
    /// Not yet said: full colour.
    case upcoming
}

/// Which words are read, current and upcoming. `wordPosition` is the fractional word index of the state (`1.5` is
/// halfway through the second word); the word the position is inside is the current one.
public struct PrompterWordRanges: Equatable, Sendable {
    public var read: Range<Int>
    public var current: Int?
    public var upcoming: Range<Int>

    public init(wordCount: Int, wordPosition: Double, isDone: Bool = false) {
        let count = max(0, wordCount)
        let whole = isDone ? count : min(count, max(0, Int((wordPosition + 1e-9).rounded(.down))))
        read = 0..<whole
        current = whole < count ? whole : nil
        upcoming = min(count, whole + 1)..<count
    }

    public init(state: PrompterState) {
        self.init(wordCount: state.wordCount, wordPosition: state.wordPosition, isDone: state.isDone)
    }

    public func style(ofWord index: Int) -> PrompterWordStyle {
        if read.contains(index) { return .read }
        if index == current { return .current }
        return .upcoming
    }
}

/// The one-line notice under the text, if any. Highest priority first.
public enum PrompterHint: Equatable, Sendable {
    /// The requested mode could not start; the prompter runs in classic mode.
    case fellBack(reason: String)
    /// Word tracking heard speech but found no match for a while.
    case lost
    case done

    public init?(state: PrompterState) {
        if case .fellBackToClassic(let reason)? = state.notice {
            self = .fellBack(reason: reason)
        } else if state.isLost, state.mode == .wordTracking {
            self = .lost
        } else if state.isDone {
            self = .done
        } else {
            return nil
        }
    }

    public var text: String {
        switch self {
        case .fellBack(let reason):
            let short = reason.count > 90 ? String(reason.prefix(88)) + "…" : reason
            return L10n.tr("Classic mode: \(short)")
        case .lost: return L10n.tr("Lost: click a word")
        case .done: return L10n.tr("End of script")
        }
    }

    public var isWarning: Bool {
        switch self {
        case .fellBack, .lost: return true
        case .done: return false
        }
    }
}

/// Line breaking for one page. A word's slot is its width plus one space (half on each side, so a click anywhere
/// between two words lands on one of them); lines are centred.
public struct PrompterLayout: Equatable, Sendable {
    /// Word index range of each line.
    public let lines: [Range<Int>]
    /// Line of each word.
    public let lineOfWord: [Int]

    public static func make(wordWidths: [CGFloat], spaceWidth: CGFloat, maxWidth: CGFloat) -> PrompterLayout {
        var lines: [Range<Int>] = []
        var lineOfWord: [Int] = []
        var start = 0
        var used: CGFloat = 0
        for (i, w) in wordWidths.enumerated() {
            let slot = w + spaceWidth
            if i > start, used + slot > maxWidth {
                lines.append(start..<i)
                start = i
                used = 0
            }
            used += slot
            lineOfWord.append(lines.count)
        }
        if start < wordWidths.count { lines.append(start..<wordWidths.count) }
        return PrompterLayout(lines: lines, lineOfWord: lineOfWord)
    }

    /// The line of the word at `position` (clamped: past the end is the last line, an empty page is line 0).
    public func line(ofWordPosition position: Double) -> Int {
        guard !lineOfWord.isEmpty else { return 0 }
        let index = min(lineOfWord.count - 1, max(0, Int((position + 1e-9).rounded(.down))))
        return lineOfWord[index]
    }
}

/// Where the text sits in the panel.
public enum PrompterGeometry {
    /// Whole lines in view from the eye line down: the current line and the upcoming ones. A sliver of the previous
    /// line shows above the eye line.
    public static let visibleLines = 4
    public static let fontSizeRange: ClosedRange<Double> = 16...44

    public static func lineHeight(fontSize: CGFloat) -> CGFloat { (fontSize * 1.32).rounded() }
    /// The eye line: top edge of the current line, measured from the top of the viewport, which is directly under the
    /// camera housing. A sliver of the previous line shows above it.
    public static func eyeLineY(lineHeight: CGFloat) -> CGFloat { (lineHeight * 0.4).rounded() }
    public static func viewportHeight(lineHeight: CGFloat) -> CGFloat { eyeLineY(lineHeight: lineHeight) + lineHeight * CGFloat(visibleLines) }

    /// Vertical offset of the whole text block that puts `line` on the eye line.
    public static func offset(forLine line: Int, lineHeight: CGFloat) -> CGFloat {
        eyeLineY(lineHeight: lineHeight) - CGFloat(line) * lineHeight
    }

    public static func spaceWidth(fontSize: CGFloat) -> CGFloat { (fontSize * 0.3).rounded() }
}

/// Word widths in the prompter font, for `PrompterLayout`.
@MainActor
enum PrompterTextMeasure {
    static func font(size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }

    /// The font's own width of a space, so words set one by one sit exactly like a plain `Text` of the whole line.
    static func spaceWidth(size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }

    static func widths(of words: [String], fontSize: CGFloat) -> [CGFloat] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size: fontSize)]
        // One point of slack: the SwiftUI text must never be a hair wider than the slot it was measured for.
        return words.map { ceil(NSAttributedString(string: $0, attributes: attributes).size().width) + 1 }
    }
}

/// The three lines the island shows (spec 3.2, state 7): the line before the current one, the current line, the next.
public struct PrompterLineWindow: Equatable, Sendable {
    public var previous: Int?
    public var current: Int
    public var next: Int?

    public init(previous: Int?, current: Int, next: Int?) {
        self.previous = previous
        self.current = current
        self.next = next
    }

    public init(currentLine: Int, lineCount: Int) {
        let last = max(0, lineCount - 1)
        current = min(max(0, currentLine), last)
        previous = current > 0 ? current - 1 : nil
        next = current < last ? current + 1 : nil
    }
}

/// Sizes of the island's prompter lines for a base font size (the Settings font size, 26 by default) and the text size
/// factor: the current line is 30/26 of the base, the others the base.
public enum PrompterIslandType {
    public static func current(fontSize: Double, scale: CGFloat) -> CGFloat { (CGFloat(fontSize) * 30 / 26 * scale).rounded() }
    public static func other(fontSize: Double, scale: CGFloat) -> CGFloat { (CGFloat(fontSize) * scale).rounded() }
}
