import AppKit
import SwiftUI

/// The UI redesign's tokens (docs/specs/2026-10-16-verse-ui-redesign-design.md, section 2). One file for both surfaces:
/// the island and the home window. The mockups in design/mockups use the same values.
public enum VT {
    // MARK: Colour
    /// The one accent, lime A (was Verse mint until 16 Oct): live dot, primary action fill, toggle and slider "on" state.
    /// The token names still say "mint"; renaming them would touch every view for no visible change.
    public static let mint = Color(red: 190 / 255, green: 220 / 255, blue: 76 / 255)       // #BEDC4C
    /// Accent for text and glyphs on light surfaces (5.8:1 on white).
    public static let mintDeep = Color(red: 90 / 255, green: 109 / 255, blue: 11 / 255)    // #5A6D0B
    /// Label colour on an accent fill.
    public static let onMint = Color(red: 29 / 255, green: 40 / 255, blue: 6 / 255)        // #1D2806
    /// Lime A is weak on white (1.55:1), so light-appearance toggles and slider fills get this neutral hairline.
    public static let accentHairline = Color.black.opacity(0.14)
    /// Status only (credit, permission), never decoration.
    public static let amber = Color(red: 1.00, green: 0.71, blue: 0.28)         // #FFB547
    /// Status only (errors).
    public static let coral = Color(red: 1.00, green: 0.42, blue: 0.37)         // #FF6B5E
    /// Island surface under Reduce Transparency.
    public static let islandSolid = Color(red: 0.055, green: 0.059, blue: 0.067) // #0E0F11

    /// White text and fills on the island (always dark).
    public enum Island {
        public static let primary = Color.white
        public static let secondary = Color.white.opacity(0.80)
        public static let tertiary = Color.white.opacity(0.56)
        public static let quaternary = Color.white.opacity(0.36)
        /// The heard question on the answer card (and "Following you"): a neutral cool grey, dimmer than the unspoken SAY words.
        public static let question = Color(red: 0.76, green: 0.80, blue: 0.87).opacity(0.62)
        /// SAY words not yet said / already said on the prompter-style card.
        public static let sayUnspoken = Color.white.opacity(0.55)
        /// Increase Contrast: the unsaid words stay readable but still differ from the said ones.
        public static let sayUnspokenContrast = Color.white.opacity(0.78)
        public static let saySpoken = Color.white
        public static let fill = Color.white.opacity(0.11)
        public static let fillStrong = Color.white.opacity(0.17)
    }

    /// Window colours for one appearance (spec 2.1). `increaseContrast` / `reduceTransparency` come from the
    /// environment (`colorSchemeContrast`, `accessibilityReduceTransparency`).
    public struct Window {
        public var dark: Bool
        public var increaseContrast = false
        public var reduceTransparency = false

        public init(dark: Bool, increaseContrast: Bool = false, reduceTransparency: Bool = false) {
            self.dark = dark
            self.increaseContrast = increaseContrast
            self.reduceTransparency = reduceTransparency
        }

        public var primary: Color { dark ? .white.opacity(0.92) : .black.opacity(0.86) }
        public var secondary: Color { increaseContrast ? primary : (dark ? .white.opacity(0.58) : .black.opacity(0.54)) }
        public var tertiary: Color { increaseContrast ? primary.opacity(0.8) : (dark ? .white.opacity(0.36) : .black.opacity(0.34)) }
        public var background: Color { dark ? Color(red: 0.114, green: 0.114, blue: 0.125) : Color(red: 0.961, green: 0.961, blue: 0.969) }
        private var solid: Bool { reduceTransparency || increaseContrast }
        /// Inset groups on the window glass. A fill, never glass.
        public var group: Color { solid ? (dark ? Color(red: 0.165, green: 0.165, blue: 0.18) : .white) : (dark ? .white.opacity(0.055) : .white.opacity(0.52)) }
        /// Long text (report, script editor).
        public var plate: Color { solid ? (dark ? Color(red: 0.145, green: 0.145, blue: 0.157) : .white) : (dark ? .black.opacity(0.22) : .white.opacity(0.72)) }
        public var fill: Color { dark ? .white.opacity(0.10) : .black.opacity(0.055) }
        public var selection: Color { dark ? .white.opacity(0.12) : .black.opacity(0.075) }
        public var separator: Color { increaseContrast ? (dark ? .white.opacity(0.5) : .black.opacity(0.5)) : (dark ? .white.opacity(0.08) : .black.opacity(0.08)) }
        public var groupEdge: Color { increaseContrast ? separator : (dark ? .white.opacity(0.06) : .white.opacity(0.7)) }
        public var windowEdge: Color { increaseContrast ? (dark ? .white.opacity(0.6) : .black.opacity(0.6)) : (dark ? .white.opacity(0.14) : .white.opacity(0.65)) }
        public var mintText: Color { dark ? VT.mint : VT.mintDeep }
        /// Edge for accent fills that sit on a light surface (toggle "on" track, slider fill); none in dark appearance.
        public var accentEdge: Color { dark ? .clear : VT.accentHairline }
    }

    // MARK: Type (SF Pro; island sizes at text size M, multiplied by TextScale.factor)
    public enum Font {
        public static func say(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (22 * s).rounded(), weight: .semibold) }
        public static func point(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (15 * s).rounded()) }
        public static func chip(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (12.5 * s).rounded(), weight: .medium) }
        public static let sayTracking: CGFloat = -0.35
    /// SAY on the answer card is set in the teleprompter's "current line" type: 30 semibold, scaled by the text size.
    public static let promptSayTracking: CGFloat = -0.4
    /// Line above the SAY: the heard question, or "Following you".
    public static func cardLead(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (13 * s).rounded(), weight: .medium) }
        public static let wing = SwiftUI.Font.system(size: 11.5, weight: .medium)
        public static let meta = SwiftUI.Font.system(size: 12, weight: .medium)
        public static func prompterCurrent(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (30 * s).rounded(), weight: .semibold) }
        public static func prompterOther(_ s: CGFloat = 1) -> SwiftUI.Font { .system(size: (26 * s).rounded(), weight: .medium) }
        public static let largeTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        public static let largeTitleTracking: CGFloat = -0.5
        public static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 13)
        public static let bodyEmph = SwiftUI.Font.system(size: 13, weight: .medium)
        public static let callout = SwiftUI.Font.system(size: 12)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let sidebar = SwiftUI.Font.system(size: 13, weight: .medium)
    }

    // MARK: Spacing (4-pt grid) and radii (concentric)
    public enum Space {
        public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }

    public enum Radius {
        public static let window: CGFloat = 26
        public static let group: CGFloat = 14
        public static let row: CGFloat = 9
        public static let control: CGFloat = 9
        public static let chip: CGFloat = 7
        public static let islandShoulder: CGFloat = 14
        public static let islandBottom: CGFloat = 26
    }

    /// Island content inset from the silhouette edge: shoulder + 22 on cards (dot and SAY bar share an axis), shoulder
    /// + 12 on capsules.
    public static let islandCardInset: CGFloat = Radius.islandShoulder + 22
    public static let islandCapsuleInset: CGFloat = Radius.islandShoulder + 12
    /// The island's black band covers the notch height plus this.
    public static let islandBandOverlap: CGFloat = 6
    /// Height of the glassier lower rim of the island.
    public static let islandRimHeight: CGFloat = 24
    /// Morph between island sizes: ease-out, no spring (spec 3.3).
    public static let morph = Animation.easeOut(duration: 0.14)
}
