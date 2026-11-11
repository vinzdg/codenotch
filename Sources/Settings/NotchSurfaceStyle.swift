import SwiftUI

/// The material the expanded notch, tooltip and settings orb are painted with.
///
/// Raw values are persistence keys, not display copy: keeping them stable lets
/// labels change without losing an existing choice. The default is `.glass`
/// because an "on by default" choice must not depend on the user having opened
/// Settings.
enum NotchSurfaceStyle: String, CaseIterable, Identifiable {
    case glass
    case darkGlass
    case solid
    /// Last, so the picker's existing segments keep their places.
    case dock

    var id: String { rawValue }

    /// Whether this Mac has a Liquid Glass to hand the surface to at all.
    ///
    /// Codenotch's deployment target is macOS 15, where `glassEffect` does not
    /// exist. A material is not a stand-in: the notch panel sits over the bezel
    /// with nothing behind it to blur, so a `.regular` material there would
    /// come out as a flat grey rectangle rather than as translucency.
    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// The style that actually gets painted, which is the chosen one only where
    /// it can be. Every glass branch keys off this rather than off `self`, so a
    /// preference set on a newer Mac (or restored from one) still draws
    /// something sensible on an older one instead of drawing nothing.
    var effective: NotchSurfaceStyle {
        switch self {
        case .glass, .darkGlass, .dock: return Self.glassAvailable ? self : .solid
        case .solid: return .solid
        }
    }

    /// The one question the views ask: is there a `glassEffect` under this
    /// surface at all? Every glass style answers yes, and they differ only in
    /// `glass` and `glassDim` (plus the dock's slab), so no view has to know
    /// which of them it is drawing.
    var isGlass: Bool {
        switch effective {
        case .glass, .darkGlass, .dock: return true
        case .solid: return false
        }
    }

    /// The question every dock-only branch asks, answered after the fallback
    /// to `solid` so an older Mac never draws half a dock.
    var isDock: Bool { effective == .dock }

    /// The style drawn on a given edge. On the top edge the notch has to stay
    /// welded to the bezel and to a MacBook's own cutout, so the dock style
    /// draws there as the dark glass it is closest to.
    func resolved(on edge: NotchEdge) -> NotchSurfaceStyle {
        self == .dock && edge == .top ? .darkGlass : self
    }

    /// The variant handed to every `glassEffect` the notch draws.
    ///
    /// `darkGlass` asks for `.clear` rather than a tinted `.regular` because a
    /// tint cannot darken: `.regular` is adaptive — it reads the luminosity of
    /// whatever is behind it — and `Glass.tint(_:)` only colourises the
    /// material toward a hue, so a zero-chroma black came out *lighter* and
    /// whiter than plain regular glass. The SDK's own recipe for dark glass,
    /// quoted in the `Glass.clear` doc comment, is clear glass over a
    /// transparent black beneath it; that black is `glassDim`.
    ///
    /// `dock` takes `.regular` instead: its panel claims active appearance so
    /// that the slab's clear glass is truly clear, and with that claim a
    /// clear card laid over a terminal let the text behind it through. The
    /// tooltip and cards have to be read, so they take the frosted variant
    /// over `Palette.dockCardDim`, and only the slab (`slabGlass`) is clear.
    @available(macOS 26.0, *)
    var glass: Glass {
        switch effective {
        case .darkGlass: return .clear
        case .glass, .solid, .dock: return .regular
        }
    }

    /// The Dock's own glass, for the floating slab alone: clear, with nothing
    /// of ours beneath it, darkened by a tint. The note on `glass` that a tint
    /// cannot darken is about adaptive `.regular`; on `.clear` a black tint
    /// does, as the spike showed side by side.
    @available(macOS 26.0, *)
    var slabGlass: Glass {
        .clear.tint(Palette.dockGlassTint)
    }

    /// The wash drawn *beneath* the glass — never fed to `tint` — and only for
    /// `darkGlass` and `dock`. `nil` for `.glass` is not "no wash yet": laying
    /// nothing of ours under it keeps that style byte-for-byte the system's own
    /// glass, which is the whole promise of the option. `dock` keeps the Dark
    /// glass value although its glass is `.regular`: while the notch floats
    /// nothing but the cards reads it, and on the top edge the style has
    /// already resolved to `darkGlass`.
    var glassDim: Color? {
        switch effective {
        case .darkGlass, .dock: return Palette.darkGlassDim
        case .glass, .solid: return nil
        }
    }

    var title: String {
        switch self {
        case .glass: return L10n.t("Liquid Glass")
        case .darkGlass: return L10n.t("Dark glass")
        case .solid: return L10n.t("Solid black")
        case .dock: return L10n.t("Dock")
        }
    }

    var explanation: String {
        switch self {
        case .glass:
            return L10n.t("System Liquid Glass. Follows this Mac's Appearance settings, including Clear or Tinted glass and light or dark mode.")
        case .darkGlass:
            return L10n.t("Liquid Glass tinted black. Always dark, whatever the Mac's appearance.")
        case .solid:
            return L10n.t("The original opaque black notch. Always dark, whatever the Mac's appearance.")
        case .dock:
            return L10n.t("A floating slab of clear glass, like the Dock. Always dark. On the top edge it stays a notch.")
        }
    }

    /// One window-level switch decides both halves of "how dark is this notch":
    /// the dynamic `NSColor`s in `Palette` and SwiftUI's `colorScheme` are both
    /// resolved against the window's appearance, so pinning it here saves
    /// threading a style through every view that picks a colour.
    ///
    /// `nil` is not a fallback — it is the whole point of the glass style. With
    /// no appearance of our own, light or dark, Clear or Tinted all arrive from
    /// the Mac's Appearance settings; naming one would quietly overrule the
    /// user there. `darkGlass` is the deliberate opposite: it asks for a notch
    /// that is dark whatever the Mac is doing, so it pins `darkAqua` like
    /// `solid` and keeps `Palette`'s frame-sampled hexes. `dock` is always dark
    /// too, so it pins `darkAqua` for the same reason.
    ///
    /// Reduce transparency is the exception the window has to be told about:
    /// it means "no see-through chrome", which for the notch is the solid
    /// style, and a light palette on a black surface would be unreadable. The
    /// precedence is the Settings window's — reduce transparency first, then
    /// glass, then the opaque fill.
    func panelAppearance(reduceTransparency: Bool) -> NSAppearance? {
        effective == .glass && !reduceTransparency ? nil : NSAppearance(named: .darkAqua)
    }
}

private struct NotchSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = NotchSurfaceStyle.glass
}

/// The style the tooltip and the update and reset cards are painted with. The
/// cards are the one surface that follows the *chosen* style rather than the
/// one drawn on this edge: with the dock style on the top edge the notch is
/// Dark glass, but its clear glass over the 0.80 dim made the cards look
/// unlike the same cards on every other edge, so they keep the dock recipe.
private struct NotchCardSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = NotchSurfaceStyle.glass
}

extension EnvironmentValues {
    var notchSurfaceStyle: NotchSurfaceStyle {
        get { self[NotchSurfaceStyleKey.self] }
        set { self[NotchSurfaceStyleKey.self] = newValue }
    }

    var notchCardSurfaceStyle: NotchSurfaceStyle {
        get { self[NotchCardSurfaceStyleKey.self] }
        set { self[NotchCardSurfaceStyleKey.self] = newValue }
    }
}
