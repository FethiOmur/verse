import SwiftUI

/// The redesign's tokens. The spec (docs/specs/2026-10-16-verse-ui-redesign-design.md) is the source of truth; these
/// values mirror it so the renders show exactly what the spec says.
enum VT {
    // MARK: Colour
    /// The one accent. Default is lime A (approved 16 Oct); `VERSE_ACCENT=mint|lime-b|lime-c` renders the other
    /// accent-study candidates.
    static let accent = Accent.named(ProcessInfo.processInfo.environment["VERSE_ACCENT"])
    /// Live dot, SAY marker, primary action, toggle and slider fill. Nothing else is coloured.
    static var mint: Color { accent.fill }
    /// Accent for text and glyphs on light surfaces (>= 4.5:1 on white).
    static var mintDeep: Color { accent.deep }
    /// Label colour on an accent fill.
    static var onMint: Color { accent.on }
    /// Status colours, only for status (credit, permission, error), never decoration.
    static let amber = Color(red: 1.00, green: 0.71, blue: 0.28)         // #FFB547
    static let coral = Color(red: 1.00, green: 0.42, blue: 0.37)         // #FF6B5E

    /// White text strengths on the island (always dark).
    enum Island {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.80)
        static let tertiary = Color.white.opacity(0.56)
        static let quaternary = Color.white.opacity(0.36)
        /// The heard question on the prompter-style card: a neutral cool grey, dimmer than the unspoken SAY words.
        static let question = Color(red: 0.76, green: 0.80, blue: 0.87).opacity(0.62)
        static let fill = Color.white.opacity(0.11)
        static let fillStrong = Color.white.opacity(0.17)
    }

    // MARK: Type (SF Pro; sizes at text size M)
    enum Font {
        static func say(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (22 * s).rounded(), weight: .semibold) }
        static func point(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (15 * s).rounded()) }
        static func chip(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (12.5 * s).rounded(), weight: .medium) }
        static let wing = SwiftUI.Font.system(size: 11.5, weight: .medium)
        static let meta = SwiftUI.Font.system(size: 12, weight: .medium)
        static let prompterCurrent = SwiftUI.Font.system(size: 30, weight: .semibold)
        /// Prompter current line scaled by the text-size setting (S/M/L/XL = 0.86/1/1.14/1.27 of the SAY size).
        static func prompterCurrent(_ s: CGFloat) -> SwiftUI.Font { .system(size: (30 * s).rounded(), weight: .semibold) }
        /// Line above the prompter-style SAY: heard question or "Following you".
        static let cardLead = SwiftUI.Font.system(size: 13, weight: .medium)
        static let prompterOther = SwiftUI.Font.system(size: 26, weight: .medium)
        // Window
        static let largeTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyEmph = SwiftUI.Font.system(size: 13, weight: .medium)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let sidebar = SwiftUI.Font.system(size: 13, weight: .medium)
    }

    // MARK: Spacing (4-pt grid)
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }

    // MARK: Radii (concentric: inner = outer - inset)
    enum Radius {
        static let window: CGFloat = 26
        static let group: CGFloat = 14          // inset groups inside the window content
        static let row: CGFloat = 9             // sidebar rows, list rows
        static let control: CGFloat = 9         // buttons, fields
        static let chip: CGFloat = 7
        static let islandShoulder: CGFloat = 14
        static let islandBottom: CGFloat = 26   // card; capsules scale it down to fit their height
    }

    // MARK: Island geometry (14"/16" MacBook Pro notch: 186 x 32 pt)
    static let notchWidth: CGFloat = 186
    static let notchHeight: CGFloat = 32

    /// User opacity of the island's veil (Settings > Appearance > Island). Range 35-100 %, default 62 %.
    static let islandVeilDefault: Double = 0.62
    /// Window opacity: how much of the window background colour sits on the glass. Range 0-100 % (100 = solid),
    /// default 34 %.
    static let windowVeil: Double = 0.34
}

/// Accessibility state a render runs under (System Settings > Accessibility > Display).
struct A11y {
    var reduceTransparency = false
    var increaseContrast = false
    var islandVeil: Double = VT.islandVeilDefault
}

/// An accent colour set: fill, deep (text on light) and the label colour that sits on the fill.
struct Accent: Sendable {
    var fill: Color, deep: Color, on: Color

    static let mint = Accent(fill: Color(red: 0.42, green: 0.90, blue: 0.70),     // #6BE6B3
                             deep: Color(red: 0.05, green: 0.50, blue: 0.34),     // #0D8057
                             on: Color(red: 0.02, green: 0.17, blue: 0.11))       // #052B1C
    /// A: brighter key lime.
    static let limeA = Accent(fill: Color(hex: 0xBEDC4C), deep: Color(hex: 0x5A6D0B), on: Color(hex: 0x1D2806))
    /// B: true lime.
    static let limeB = Accent(fill: Color(hex: 0x9ED13A), deep: Color(hex: 0x477A0C), on: Color(hex: 0x13220A))
    /// C: deeper, olive-leaning lime.
    static let limeC = Accent(fill: Color(hex: 0xA0B33A), deep: Color(hex: 0x5F6E0F), on: Color(hex: 0x1B2006))

    static func named(_ name: String?) -> Accent {
        switch name {
        case "mint": .mint
        case "lime-b": .limeB
        case "lime-c": .limeC
        default: .limeA
        }
    }
}
