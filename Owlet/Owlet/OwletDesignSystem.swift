import SwiftUI

/// Owlet's branded design tokens — sage/coral/paper palette + serif display.
/// Drives the v0.4 rewriter popup (fka "Improve Prompt floater").
///
/// Source of truth: `colors_and_type.css` from the design handoff bundle.
///
/// **Fonts.** Fraunces (display italic) and Be Vietnam Pro (UI sans) are
/// installed system-wide by `install.sh` via Homebrew casks `font-fraunces`
/// and `font-be-vietnam-pro` — referenced here by PostScript name through
/// `Font.custom`. If the casks aren't installed, `Font.custom` silently
/// falls back to the system font, which keeps the app usable but visually
/// off-brand. The install.sh check is the contract.
enum OwletDesign {

    // MARK: Colors — Paper (light surfaces)
    enum Paper {
        static let p0 = Color(red: 0xFA/255.0, green: 0xF8/255.0, blue: 0xF2/255.0) // canvas
        static let p1 = Color(red: 0xF2/255.0, green: 0xEF/255.0, blue: 0xE7/255.0) // card
        static let p2 = Color(red: 0xE5/255.0, green: 0xE1/255.0, blue: 0xD5/255.0) // sunken / hover
        static let p3 = Color(red: 0xD2/255.0, green: 0xCD/255.0, blue: 0xC0/255.0) // hairline
    }

    // MARK: Colors — Ink (foreground)
    enum Ink {
        static let i0 = Color(red: 0x1F/255.0, green: 0x2A/255.0, blue: 0x2A/255.0) // primary text
        static let i1 = Color(red: 0x3E/255.0, green: 0x48/255.0, blue: 0x48/255.0) // secondary
        static let i2 = Color(red: 0x6E/255.0, green: 0x74/255.0, blue: 0x74/255.0) // tertiary
        static let i3 = Color(red: 0x9D/255.0, green: 0xA0/255.0, blue: 0xA0/255.0) // disabled
    }

    // MARK: Colors — Sage (primary brand)
    enum Sage {
        static let s50  = Color(red: 0xEB/255.0, green: 0xF2/255.0, blue: 0xEF/255.0)
        static let s100 = Color(red: 0xD4/255.0, green: 0xE4/255.0, blue: 0xDF/255.0)
        static let s200 = Color(red: 0xA8/255.0, green: 0xC8/255.0, blue: 0xC0/255.0)
        static let s300 = Color(red: 0x82/255.0, green: 0xAF/255.0, blue: 0xA6/255.0)
        static let s500 = Color(red: 0x5E/255.0, green: 0x95/255.0, blue: 0x90/255.0) // PRIMARY
        static let s600 = Color(red: 0x43/255.0, green: 0x79/255.0, blue: 0x75/255.0) // press
        static let s700 = Color(red: 0x30/255.0, green: 0x59/255.0, blue: 0x55/255.0)
        static let s800 = Color(red: 0x2E/255.0, green: 0x57/255.0, blue: 0x54/255.0)
        static let s900 = Color(red: 0x1E/255.0, green: 0x3E/255.0, blue: 0x3C/255.0)
    }

    // MARK: Colors — Coral (secondary / accent)
    enum Coral {
        static let c50  = Color(red: 0xFE/255.0, green: 0xEF/255.0, blue: 0xEA/255.0)
        static let c100 = Color(red: 0xFD/255.0, green: 0xE2/255.0, blue: 0xDC/255.0)
        static let c200 = Color(red: 0xF9/255.0, green: 0xC0/255.0, blue: 0xB4/255.0)
        static let c300 = Color(red: 0xF4/255.0, green: 0x96/255.0, blue: 0x84/255.0)
        static let c500 = Color(red: 0xED/255.0, green: 0x7B/255.0, blue: 0x68/255.0) // SECONDARY
        static let c600 = Color(red: 0xDF/255.0, green: 0x53/255.0, blue: 0x42/255.0)
        static let c700 = Color(red: 0xB8/255.0, green: 0x49/255.0, blue: 0x38/255.0)
    }

    // MARK: Semantic role tokens (light scheme only for v0.4 preview)
    static let bg          = Paper.p0
    static let bgElev      = Paper.p1
    static let bgSunken    = Paper.p2
    static let fg          = Ink.i0
    static let fgMuted     = Ink.i1
    static let fgSubtle    = Ink.i2
    static let fgDisabled  = Ink.i3
    static let hairline    = Paper.p3
    static let brand       = Sage.s500
    static let brandPress  = Sage.s600
    static let brandSoft   = Sage.s50
    static let accent      = Coral.c500
    static let accentSoft  = Coral.c100
    static let danger      = Color(red: 0xC4/255.0, green: 0x4A/255.0, blue: 0x37/255.0)

    /// Floater surface — paper-cream with high translucency, sits over vibrancy.
    static let floaterFill = Paper.p0.opacity(0.94)

    // MARK: Typography
    /// Display serif for the rewrite output. Fraunces Italic — installed via
    /// `brew install --cask font-fraunces`. The variable font's `SOFT`/`opsz`
    /// axes default to their factory values (SOFT=0 rather than the design's
    /// 50) because SwiftUI's Font.custom doesn't expose font-variation-
    /// settings; the type still reads as Fraunces, just slightly less rounded.
    static func displayItalic(size: CGFloat) -> Font {
        .custom("Fraunces-Italic", size: size)
    }

    /// UI sans — Be Vietnam Pro at the design's intended weight. Installed
    /// via `brew install --cask font-be-vietnam-pro`. Falls back to system
    /// (SF Pro) silently if the cask isn't installed.
    static func ui(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom(beVietnamPostScriptName(for: weight), size: size)
    }

    /// Mono — SF Mono. Design references JetBrains Mono but it's only used
    /// for the tiny keyboard-chord hint (~10pt), and the visual diff between
    /// SF Mono and JetBrains Mono at that size is negligible. Skipping the
    /// extra font install.
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Map SwiftUI's coarse weight enum to the closest Be Vietnam Pro PS name.
    /// The cask ships 9 weights × 2 (italic); the rewriter UI only needs three.
    private static func beVietnamPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "BeVietnamPro-Light"
        case .regular:                    return "BeVietnamPro-Regular"
        case .medium:                     return "BeVietnamPro-Medium"
        case .semibold:                   return "BeVietnamPro-SemiBold"
        case .bold:                       return "BeVietnamPro-Bold"
        case .heavy, .black:              return "BeVietnamPro-ExtraBold"
        default:                          return "BeVietnamPro-Medium"
        }
    }

    // MARK: Radius scale
    enum Radius {
        static let xs: CGFloat   = 4
        static let sm: CGFloat   = 6
        static let md: CGFloat   = 10
        static let lg: CGFloat   = 14
        static let xl: CGFloat   = 20
        static let pill: CGFloat = 999
    }

    // MARK: Floater dimensions — from the design (Improve Prompt.html line 261).
    enum Floater {
        static let width: CGFloat = 420
        static let paddingComfortable = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        static let paddingCompact     = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    }
}
