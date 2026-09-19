import AppKit
import SwiftUI

/// The dark values are sampled from `docs/design/frame-124-hover-tooltip.png`,
/// not invented, and they differ slightly from the hexes written in the design
/// spec — the frame is the source of truth, so the sampled values win.
///
/// The light values are not sampled from anything, because there is no light
/// frame: they exist only because the glass surface (`NotchSurfaceStyle.glass`)
/// hands light and dark to the Mac's Appearance settings, and white ink on
/// light glass is unreadable. They were picked for at least 3:1 against white.
/// `solid` pins the panel to `darkAqua`, so it keeps the frame's hexes exactly.
///
/// The two tracks are translucent white / black rather than a fixed grey so
/// they darken or lighten whatever is behind them instead of looking painted
/// on top of the glass. Their dark alphas are the ones that composite to the
/// frame's `#303030` / `#2D2D2D` over black, so the solid style is unchanged.
///
/// `notch` and `card` stay pure black: they paint the resting pill, which has
/// to read as the bezel, and the whole surface in the solid style.
enum Palette {
    static let notch         = Color.black                    // #000000
    static let card          = Color.black                    // #000000
    static let ringTrack     = Color(dark: .white.withAlphaComponent(0.188),
                                     light: .black.withAlphaComponent(0.16))
    static let barTrack      = Color(dark: .white.withAlphaComponent(0.176),
                                     light: .black.withAlphaComponent(0.15))

    static let ample         = Color(dark: NSColor(hex: 0x00FF88), light: NSColor(hex: 0x00A356))
    static let watch         = Color(dark: NSColor(hex: 0xF2FF00), light: NSColor(hex: 0xB08800))
    /// Already 3.5:1 on white, so the warning colour is the same in both.
    static let critical      = Color(hex: 0xFF3F00)           // orange

    // Generation-speed bands are independent of cloud quota usage.
    static let generationFast = Color(hex: 0x0A84FF)          // blue
    static let generationSlow = Color(hex: 0xFF453A)          // red

    /// The one wash of our own laid *under* the system's glass, and only for
    /// `NotchSurfaceStyle.darkGlass`: that style exists because a black notch
    /// was asked for regardless of the Mac's Appearance, which the untinted
    /// `glass` cannot promise. It is a background beneath `Glass.clear`, not a
    /// `Glass.tint` — tinting only colourises an adaptive material and made the
    /// surface lighter, so the darkening has to happen behind the glass. 0.45
    /// was the first value tried and read too light through `Glass.clear` on a
    /// real Mac (macOS 27) against a light desktop; 0.60 is what the user
    /// chose by eye instead — opaque enough to be the bezel, thin enough not
    /// to be `solid`.
    static let darkGlassDim = Color.black.opacity(0.60)

    /// Tooltip copy retains the frame's #808080 secondary ink in Dark glass.
    /// It needs a deeper local backing than the notch itself when a light
    /// desktop is visible through `Glass.clear`, otherwise the two greys merge.
    static let darkGlassTooltipDim = Color.black.opacity(0.80)

    /// A tooltip-only wash for standard Liquid Glass in dark appearance. It is
    /// intentionally weaker than `darkGlassDim`: regular glass stays visibly
    /// distinct from the user-selected always-dark surface.
    static let liquidGlassTooltipDim = Color.black.opacity(0.35)

    static let textPrimary   = Color(dark: .white, light: .black)
    static let textSecondary = Color(dark: NSColor(hex: 0x808080), light: NSColor(hex: 0x6B6B6B))
    /// Used only by dark, standard Liquid Glass tooltips. Other surfaces keep
    /// `textSecondary`, including their frame-accurate #808080 dark ink.
    static let readableTooltipTextSecondary = Color(dark: NSColor(hex: 0xC2C2C2), light: NSColor(hex: 0x6B6B6B))
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Resolved against whatever appearance is current when the colour is
    /// drawn, which for the notch is the panel's: `nil` for glass (so the Mac
    /// decides) and `darkAqua` for solid.
    init(dark: NSColor, light: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   1
        )
    }
}

private struct CodenotchReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// True when macOS Accessibility "Reduce Transparency" is enabled in system settings,
    /// or explicitly overridden via `.environment(\.codenotchReduceTransparency, ...)`.
    var codenotchReduceTransparency: Bool {
        get { self[CodenotchReduceTransparencyKey.self] || self.accessibilityReduceTransparency }
        set { self[CodenotchReduceTransparencyKey.self] = newValue }
    }
}

private struct CodenotchHeadlessGlassKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct TooltipSecondaryInkKey: EnvironmentKey {
    static let defaultValue = Palette.textSecondary
}

extension EnvironmentValues {
    /// Secondary ink resolved for the current tooltip surface. This stays
    /// frame-accurate unless ordinary dark Liquid Glass needs extra contrast.
    var tooltipSecondaryInk: Color {
        get { self[TooltipSecondaryInkKey.self] }
        set { self[TooltipSecondaryInkKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// Draw the glass path with the system material left out. Tests only; the
    /// app never sets it.
    ///
    /// `ImageRenderer` cannot draw the material faithfully: in a cold process
    /// it paints `glassEffect` as nothing at all, and once any test has shown
    /// a live `NotchPanel` it paints it as an opaque flat grey over its ZStack
    /// siblings for the rest of the process. Either way the pixels say nothing
    /// about the product. So the glass pixel tests render everything *around*
    /// the material — the transparent body fill, the `darkGlass` dim, the
    /// opaque hardware band — which is the part that is ours to get wrong.
    /// See TASKS.md, "The hardware's band stays black".
    var codenotchHeadlessGlass: Bool {
        get { self[CodenotchHeadlessGlassKey.self] }
        set { self[CodenotchHeadlessGlassKey.self] = newValue }
    }
}
