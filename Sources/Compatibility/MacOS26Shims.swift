import AppKit
import SwiftUI

/// Upstream writes against the macOS 26 SDK — Liquid Glass (`glassEffect`),
/// unified pointer styles (`pointerStyle`) — and those modifiers are absent
/// entirely from the macOS 14 SDK this machine builds with, so `#available`
/// cannot gate them: the compiler must not even see the symbol. On such
/// toolchains these shims stand in with the pre-Tahoe form of the same
/// controls — a material in the same shape, a cursor hover — which is the
/// right look on those systems anyway.
///
/// `compiler(>=6.2)` is the compile-time proxy for "the macOS 26 SDK is in this
/// toolchain" (Xcode 26 ships Swift 6.2; Xcode 15.4 ships 5.10). It has to be
/// the compiler condition, not `swift(>=6.2)`: `swift(...)` tests the *language
/// mode*, and `project.yml` pins `SWIFT_VERSION: "5.0"` so that stays false on
/// every toolchain, including Xcode 26. Newer toolchains then compile the real
/// modifier, still gated at runtime by `#available`; older ones never see the
/// symbol at all.
extension View {
    /// Liquid Glass on the view itself, in `style`'s own variant, or a material
    /// in the same shape on older macOS.
    ///
    /// Applied to `self`, which is where upstream puts it. Glass is not a
    /// background: it refracts what is behind the view it is attached to, so
    /// wrapping it in `background { Color.clear.glassEffect(…) }` renders a
    /// different surface — the older builds never reach this branch, but an
    /// Xcode 26 build would, and it would not match upstream.
    ///
    /// `interactive` is upstream's `.regular.interactive()`: the glass answers the
    /// pointer. There is no material equivalent — on the older systems this is the
    /// branch that never runs, since `NotchSurfaceStyle.glassAvailable` is false
    /// there — so the fallback stays the plain material.
    ///
    /// `slab` picks upstream's `slabGlass` instead of `glass`: the Dock style's
    /// floating slab, clear glass under its own tint rather than the frosted
    /// card that same style gives every other surface.
    ///
    /// The style arrives as a `NotchSurfaceStyle` rather than as its `Glass` value
    /// (which upstream spells at the call site) because `Glass` does not exist in
    /// an old SDK: only this file may name it, and only under `compiler(>=6.2)`.
    func compatGlassEffect<S: Shape>(_ style: NotchSurfaceStyle,
                                     in shape: S,
                                     interactive: Bool = false,
                                     slab: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let surface = slab ? style.slabGlass : style.glass
            let glass: Glass = interactive ? surface.interactive() : surface
            AnyView(glassEffect(glass, in: shape))
        } else {
            AnyView(background(.regularMaterial, in: shape))
        }
        #else
        AnyView(background(.regularMaterial, in: shape))
        #endif
    }

    /// The same glass, laid *under* the content as a background.
    ///
    /// For the call sites upstream itself writes that way — `glassBackground(in:)`
    /// on the settings chrome is `background { Color.clear.glassEffect(.regular, in: shape) }`
    /// — so the Xcode 26 build keeps upstream's shape there too, and only the
    /// symbol is redirected through this file.
    func compatGlassBackground<S: Shape>(_ style: NotchSurfaceStyle,
                                        in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            AnyView(background { Color.clear.glassEffect(style.glass, in: shape) })
        } else {
            AnyView(background(.regularMaterial, in: shape))
        }
        #else
        AnyView(background(.regularMaterial, in: shape))
        #endif
    }

    /// Open hand where the pointer may drag; a pointing hand on older macOS.
    func compatPointerStyle(active: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            AnyView(pointerStyle(active ? .grabIdle : nil))
        } else {
            AnyView(cursorCompat(active ? NSCursor.pointingHand : NSCursor.arrow))
        }
        #else
        AnyView(cursorCompat(active ? NSCursor.pointingHand : NSCursor.arrow))
        #endif
    }

    /// Reports a geometry-derived value when it changes, in the shape upstream
    /// writes for `onGeometryChange(for:_:action:)`.
    ///
    /// That modifier is macOS 15's, and the macOS 14 SDK this machine builds
    /// with does not have the symbol at all — the same "`#available` cannot
    /// save you" case as the glass below. On such toolchains a `GeometryReader`
    /// in the background reads the same frame and reports it. The report is
    /// handed to the next run loop on purpose: the value is read during layout,
    /// and assigning to the model there is what raises "Modifying state during
    /// view update" — `onGeometryChange` defers its action the same way.
    func compatOnGeometryChange<T: Equatable>(
        for type: T.Type = T.self,
        _ of: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 15, *) {
            return AnyView(onGeometryChange(for: T.self, of: of, action: action))
        } else {
            return AnyView(background(GeometryChangeReporter(of: of, action: action)))
        }
        #else
        return AnyView(background(GeometryChangeReporter(of: of, action: action)))
        #endif
    }
    private func cursorCompat(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            (hovering ? cursor : NSCursor.arrow).set()
        }
    }
}

/// The old-SDK stand-in for `onGeometryChange`: watch a frame, report changes.
private struct GeometryChangeReporter<T: Equatable>: View {
    let of: (GeometryProxy) -> T
    let action: (T) -> Void

    var body: some View {
        GeometryReader { geometry in
            let value = of(geometry)
            Color.clear
                .onAppear { report(value) }
                .onChange(of: value) { newValue in report(newValue) }
        }
    }

    private func report(_ value: T) {
        DispatchQueue.main.async { action(value) }
    }
}
