import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

final class UsageBandTests: XCTestCase {
    func testBandsMatchTheDesignFrame() {
        // The three levels the mockup renders, and the colour it renders them in.
        XCTAssertEqual(UsageBand.band(for: 0.21), .ample)
        XCTAssertEqual(UsageBand.band(for: 0.52), .watch)
        XCTAssertEqual(UsageBand.band(for: 0.73), .critical)
    }

    func testBoundaries() {
        XCTAssertEqual(UsageBand.band(for: 0.0), .ample)
        XCTAssertEqual(UsageBand.band(for: 0.4999), .ample)
        XCTAssertEqual(UsageBand.band(for: 0.50), .watch)
        XCTAssertEqual(UsageBand.band(for: 0.6999), .watch)
        XCTAssertEqual(UsageBand.band(for: 0.70), .critical)
        XCTAssertEqual(UsageBand.band(for: 0.9999), .critical)
        XCTAssertEqual(UsageBand.band(for: 1.0), .exhausted)
        XCTAssertEqual(UsageBand.band(for: 1.4), .exhausted)
    }

    /// Only the ample state takes the user's accent choice. The warning bands
    /// exist to interrupt whatever else is on screen, and a customisable
    /// warning colour could be chosen into invisibility — so they stay fixed
    /// regardless of what accent is passed in.
    func testOnlyAmpleFollowsTheChosenAccent() {
        let accent = Color.pink
        XCTAssertEqual(UsageBand.ample.color(accent: accent), accent)
        XCTAssertEqual(UsageBand.watch.color(accent: accent), Palette.watch)
        XCTAssertEqual(UsageBand.critical.color(accent: accent), Palette.critical)
        XCTAssertEqual(UsageBand.exhausted.color(accent: accent), Palette.critical)
    }

    // MARK: - rampColor

    /// Same appearance-resolution trick `PaletteAppearanceTests.resolve` uses below: a
    /// dynamic `Color` only picks its real value once something asks for it inside a
    /// specific `NSAppearance`.
    private func resolveRamp(
        _ fraction: Double,
        watchLimit: Double = 0.50,
        appearance: NSAppearance.Name = .darkAqua
    ) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let color = UsageBand.rampColor(for: fraction, watchLimit: watchLimit)
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    private func assertRampHex(
        _ fraction: Double,
        is hex: UInt32,
        watchLimit: Double = 0.50,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolved = resolveRamp(fraction, watchLimit: watchLimit) else {
            XCTFail("ramp did not resolve", file: file, line: line)
            return
        }
        let tolerance = 1.0 / 255
        XCTAssertEqual(resolved.redComponent, Double((hex >> 16) & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, Double((hex >> 8) & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, Double(hex & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
    }

    /// Unlike `band(for:)`, the ramp is not trying to reproduce the mockup's three points —
    /// it is a deliberately different, continuous mode a user opts into, so its own correctness
    /// is defined by its own anchors: exact green at 0%, exact yellow at the watch limit, exact
    /// red only at 100%.
    func testRampAnchorsExactlyAtItsThreePoints() {
        assertRampHex(0.0, is: 0x00FF88)
        assertRampHex(0.50, is: 0xF2FF00) // exactly watch's colour, at the watch limit
        assertRampHex(1.0, is: 0xFF3F00)
    }

    /// The default critical limit (70%) is deliberately *not* where the ramp turns pure red any
    /// more — that would put the whole second half back in the narrow band this change was
    /// meant to widen. At 70% it is most of the way there, not there yet.
    func testRampIsNotPinnedToTheCriticalLimit() {
        assertRampHex(0.70, is: 0xF7B200)
    }

    /// The ramp has to move with a customised watch limit, not just the default — the Mac
    /// already lets the user drag it (`SettingsView`'s "Usage Limits" slider).
    func testRampFollowsACustomWatchLimit() {
        assertRampHex(0.0, is: 0x00FF88, watchLimit: 0.30)
        assertRampHex(0.30, is: 0xF2FF00, watchLimit: 0.30) // exact yellow, at the custom limit
        assertRampHex(0.65, is: 0xF99F00, watchLimit: 0.30) // ramp's own midpoint past the limit
        assertRampHex(1.0, is: 0xFF3F00, watchLimit: 0.30)
    }

    /// No bounce across the whole range: red only rises, green and blue only fall, so the ramp
    /// reads as one steady climb from ample to critical rather than a wobble.
    func testRampIsMonotonicAcrossTheWholeRange() {
        var previousGreen = 255.0
        var previousBlue = 136.0
        var previousRed = 0.0
        for step in 0...40 {
            let f = Double(step) / 40
            guard let c = resolveRamp(f) else { XCTFail("ramp did not resolve"); return }
            let red = c.redComponent * 255
            let green = c.greenComponent * 255
            let blue = c.blueComponent * 255
            XCTAssertGreaterThanOrEqual(red, previousRed - 0.01)
            XCTAssertLessThanOrEqual(green, previousGreen + 0.01)
            XCTAssertLessThanOrEqual(blue, previousBlue + 0.01)
            previousRed = red
            previousGreen = green
            previousBlue = blue
        }
    }
}

/// The palette went dynamic when the notch gained a glass surface, so the
/// frame's hexes are no longer visible in the source — they are one branch of
/// a colour that only resolves against an appearance. These tests keep that
/// branch honest: `darkAqua` must still be pixel-for-pixel the frame, and the
/// light branch must actually be different ink rather than a silent fallback.
final class PaletteAppearanceTests: XCTestCase {
    func testTheDarkAppearanceKeepsTheFramesHexes() {
        assertOpaque(Palette.textPrimary, .darkAqua, is: 0xFFFFFF)
        assertOpaque(Palette.textSecondary, .darkAqua, is: 0x808080)
        assertOpaque(Palette.ample, .darkAqua, is: 0x00FF88)
        assertOpaque(Palette.watch, .darkAqua, is: 0xF2FF00)
        assertOpaque(Palette.critical, .darkAqua, is: 0xFF3F00)

        // #303030 and #2D2D2D over black, so the solid style is unchanged.
        assertTrack(Palette.ringTrack, .darkAqua, white: 1, alpha: 0.188)
        assertTrack(Palette.barTrack, .darkAqua, white: 1, alpha: 0.176)
    }

    func testTheLightAppearanceHasItsOwnInk() {
        assertOpaque(Palette.textPrimary, .aqua, is: 0x000000)
        assertOpaque(Palette.textSecondary, .aqua, is: 0x6B6B6B)
        assertOpaque(Palette.ample, .aqua, is: 0x00A356)
        assertOpaque(Palette.watch, .aqua, is: 0xB08800)
        assertOpaque(Palette.critical, .aqua, is: 0xFF3F00)

        assertTrack(Palette.ringTrack, .aqua, white: 0, alpha: 0.16)
        assertTrack(Palette.barTrack, .aqua, white: 0, alpha: 0.15)
    }

    func testOnlyDarkStandardLiquidGlassGetsReadableSecondaryInk() {
        assertOpaque(TooltipGlassContrast.secondaryInk(surfaceStyle: .glass, colorScheme: .dark),
                     .darkAqua, is: 0xC2C2C2)
        assertOpaque(TooltipGlassContrast.secondaryInk(surfaceStyle: .darkGlass, colorScheme: .dark),
                     .darkAqua, is: 0x808080)
        assertOpaque(TooltipGlassContrast.secondaryInk(surfaceStyle: .solid, colorScheme: .dark),
                     .darkAqua, is: 0x808080)
        assertOpaque(TooltipGlassContrast.secondaryInk(surfaceStyle: .dock, colorScheme: .dark),
                     .darkAqua, is: 0x808080)
        assertOpaque(TooltipGlassContrast.secondaryInk(surfaceStyle: .glass, colorScheme: .dark,
                                                        reduceTransparency: true),
                     .darkAqua, is: 0x808080)
    }

    func testOnlyDarkSystemLiquidGlassGetsTheReadableDim() {
        XCTAssertTrue(TooltipGlassContrast.needsReadableDim(surfaceStyle: .glass,
                                                            colorScheme: .dark))
        XCTAssertFalse(TooltipGlassContrast.needsReadableDim(surfaceStyle: .glass,
                                                             colorScheme: .light))
        XCTAssertFalse(TooltipGlassContrast.needsReadableDim(surfaceStyle: .darkGlass,
                                                             colorScheme: .dark))
        XCTAssertFalse(TooltipGlassContrast.needsReadableDim(surfaceStyle: .solid,
                                                             colorScheme: .dark))
        XCTAssertFalse(TooltipGlassContrast.needsReadableDim(surfaceStyle: .dock,
                                                             colorScheme: .dark))
        XCTAssertFalse(TooltipGlassContrast.needsReadableDim(surfaceStyle: .glass,
                                                              colorScheme: .dark,
                                                              reduceTransparency: true))
    }

    func testReadableLiquidGlassDimStaysDarkAndTranslucent() throws {
        let dim = try XCTUnwrap(resolve(Palette.liquidGlassTooltipDim, .darkAqua))
        // `resolve` deliberately returns sRGB. `whiteComponent` is undefined
        // for that colour space and raises an AppKit exception, so assert the
        // three channels directly just as `assertOpaque` does above.
        XCTAssertEqual(dim.redComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(dim.greenComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(dim.blueComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(dim.alphaComponent, 0.35, accuracy: 1.0 / 255)

        let darkGlassDim = try XCTUnwrap(TooltipGlassContrast.dim(surfaceStyle: .darkGlass,
                                                                   colorScheme: .dark)
                .flatMap({ resolve($0, .darkAqua) }))
        XCTAssertEqual(darkGlassDim.alphaComponent, 0.80, accuracy: 1.0 / 255)
        if NotchSurfaceStyle.glassAvailable {
            let dockDim = try XCTUnwrap(TooltipGlassContrast.dim(surfaceStyle: .dock,
                                                                 colorScheme: .dark)
                    .flatMap({ resolve($0, .darkAqua) }))
            let cardDim = try XCTUnwrap(resolve(Palette.dockCardDim, .darkAqua))
            XCTAssertEqual(dockDim.alphaComponent, cardDim.alphaComponent, accuracy: 1.0 / 255,
                           "the dock's cards are backed by their own dim")
            XCTAssertEqual(dockDim.redComponent, 0, accuracy: 1.0 / 255)
            XCTAssertEqual(dockDim.greenComponent, 0, accuracy: 1.0 / 255)
            XCTAssertEqual(dockDim.blueComponent, 0, accuracy: 1.0 / 255)
        }
        let dockCardDim = try XCTUnwrap(resolve(Palette.dockCardDim, .darkAqua))
        XCTAssertEqual(dockCardDim.alphaComponent, 0.40, accuracy: 1.0 / 255,
                       "the opacity chosen with a tooltip over a terminal")
        let notchDim = try XCTUnwrap(resolve(Palette.darkGlassDim, .darkAqua))
        XCTAssertEqual(notchDim.alphaComponent, 0.60, accuracy: 1.0 / 255)
    }

    /// A tint that drifts toward a hue would colour the slab rather than
    /// darken it.
    func testTheDockTintIsBlack() throws {
        let tint = try XCTUnwrap(resolve(Palette.dockGlassTint, .darkAqua))
        XCTAssertEqual(tint.redComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(tint.greenComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(tint.blueComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(tint.alphaComponent, 0.15, accuracy: 1.0 / 255,
                       "the opacity chosen beside the real Dock")
    }

    /// The disc only has to give the ring a ground; a hue would recolour the
    /// ring's own ink.
    func testTheDockRingBackingIsBlack() throws {
        let backing = try XCTUnwrap(resolve(Palette.dockRingBacking, .darkAqua))
        XCTAssertEqual(backing.redComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(backing.greenComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(backing.blueComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(backing.alphaComponent, 0.25, accuracy: 1.0 / 255,
                       "the opacity chosen with the rings over a white window")
    }

    // MARK: -

    /// The `NSColor` has to be built *inside* the drawing appearance: a dynamic
    /// colour created outside it resolves against whatever the test host's
    /// appearance happens to be.
    private func resolve(
        _ color: Color,
        _ appearance: NSAppearance.Name,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        XCTAssertNotNil(resolved, "\(appearance.rawValue) did not resolve", file: file, line: line)
        return resolved
    }

    private func assertOpaque(
        _ color: Color,
        _ appearance: NSAppearance.Name,
        is hex: UInt32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolved = resolve(color, appearance, file: file, line: line) else { return }
        let tolerance = 1.0 / 255
        XCTAssertEqual(resolved.redComponent, Double((hex >> 16) & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, Double((hex >> 8) & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, Double(hex & 0xFF) / 255, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, 1, accuracy: tolerance, file: file, line: line)
    }

    private func assertTrack(
        _ color: Color,
        _ appearance: NSAppearance.Name,
        white: Double,
        alpha: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolved = resolve(color, appearance, file: file, line: line) else { return }
        let tolerance = 1.0 / 255
        XCTAssertEqual(resolved.redComponent, white, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, white, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, white, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, alpha, accuracy: 0.005, file: file, line: line)
    }
}
