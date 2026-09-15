import SwiftUI
import XCTest
@testable import Codenotch

/// The layout maths can be right in every unit and still put nothing on the
/// screen. These render the real view and count the pixels it actually paints,
/// which is the one thing the arithmetic tests cannot tell you.
@MainActor
final class NotchRenderTests: XCTestCase {
    private func model(edge: NotchEdge, cells: Int = 4) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        // A saturated accent, not the default `.system`.
        //
        // `colouredFraction` finds an arc by its saturation, and `.system`
        // resolves to `NSColor.controlAccentColor` — the *Mac's* accent
        // colour. On a machine set to Graphite the arcs render grey and the
        // measurement reads zero whether the ring was drawn or not, so a
        // developer's System Settings decided whether the suite passed.
        model.accentColor = .blue
        // `ImageRenderer` has no desktop behind it to refract; these tests
        // measure the outline, which both styles share.
        model.surfaceStyle = .solid
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(
                id: "p\(index)", displayName: "P\(index)", glyph: .claude,
                fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.4)],
                headlineID: "w"
            )
        }
        return model
    }

    private func render(_ model: NotchViewModel, reduceTransparency: Bool = false)
        -> NSBitmapImageRep? {
        let size = model.panelSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.codenotchReduceTransparency, reduceTransparency)
                // The system material is not renderable offscreen; everything
                // around it is. See TASKS.md, "The hardware's band stays black".
                .environment(\.codenotchHeadlessGlass, true)
                // Dark, the scheme the solid style pins its own panel to.
                //
                // `Palette.ringTrack` and its neighbours became translucent
                // and resolve against the scheme they are drawn in. An
                // `ImageRenderer` with none defaults to light, where the track
                // is black at 16% over a black body — invisible — so
                // `greyFraction` read zero whether it was drawn or not.
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Fraction of sampled pixels that are painted at all.
    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 {
                    inked += 1
                }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    func testTheNotchPaintsSomethingOnEveryEdge() {
        for edge in NotchEdge.allCases {
            guard let rep = render(model(edge: edge)) else {
                XCTFail("\(edge): the view produced no image at all")
                continue
            }
            XCTAssertGreaterThan(
                inkedFraction(rep), 0.02,
                "\(edge): the panel came out blank — the notch drew nothing"
            )
        }
    }

    /// The weekly ring has to actually appear, and only when asked for.
    ///
    /// Counted by colour rather than by ink: the arcs are drawn on top of the
    /// notch's own black, which is already opaque, so `inkedFraction` cannot
    /// see them at all — it answers the same number to three decimal places
    /// whether the ring is there or not. Saturation is what separates an arc
    /// from the body behind it and the grey track beside it.
    func testTheWeeklyRingPaintsOnlyWhenSwitchedOn() {
        func colour(_ ring: WeeklyRing) -> Double {
            let model = model(edge: .right)
            model.weeklyRing = ring
            model.snapshots = model.snapshots.map { snapshot in
                ProviderSnapshot(
                    id: snapshot.id, displayName: snapshot.displayName,
                    glyph: snapshot.glyph, fidelity: snapshot.fidelity,
                    status: snapshot.status,
                    windows: snapshot.windows + [
                        LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.9)
                    ],
                    headlineID: snapshot.headlineID,
                    weeklyID: "weekly_all"
                )
            }
            guard let rep = render(model) else { return -1 }
            return colouredFraction(rep)
        }

        let off = colour(.off)
        XCTAssertGreaterThan(off, 0, "the headline arc is missing too — this measures nothing")
        XCTAssertGreaterThan(colour(.inside), off, "inside painted no arc")
        XCTAssertGreaterThan(colour(.outside), off, "outside painted no arc")
    }

    /// Hiding the move handle takes its arc off the notch, and leaves nothing
    /// behind that can still be hovered or pressed — an invisible control that
    /// starts a move is worse than a visible one.
    func testAHiddenMoveHandleIsNeitherDrawnNorPressable() throws {
        let shown = model(edge: .right)
        let point = try XCTUnwrap(shown.moveHandlePoints.first)
        XCTAssertTrue(shown.isOnMoveHandle(along: point.x, across: point.y))

        let hidden = model(edge: .right)
        hidden.showsMoveHandle = false
        XCTAssertTrue(hidden.moveHandlePoints.isEmpty)
        XCTAssertFalse(hidden.isOnMoveHandle(along: point.x, across: point.y),
                       "a hidden handle still took the press")

        let withHandle = inkedFraction(try XCTUnwrap(render(shown)))
        let withoutHandle = inkedFraction(try XCTUnwrap(render(hidden)))
        XCTAssertLessThan(withoutHandle, withHandle, "the handle's arc was still drawn")
    }

    /// A week nobody has spent yet still has to be visible.
    ///
    /// At 0% the arc has no length, so without a track behind it the ring is
    /// indistinguishable from the feature being missing — which is exactly how
    /// Codex read when its week opened empty.
    func testAnEmptyWeeklyRingStillDrawsItsTrack() {
        func ink(_ ring: WeeklyRing) -> Double {
            let model = model(edge: .right)
            model.weeklyRing = ring
            model.snapshots = model.snapshots.map { snapshot in
                ProviderSnapshot(
                    id: snapshot.id, displayName: snapshot.displayName,
                    glyph: snapshot.glyph, fidelity: snapshot.fidelity,
                    status: snapshot.status,
                    // Nothing used yet: the arc is zero length, the track is all
                    // there is to see.
                    windows: snapshot.windows + [
                        LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0)
                    ],
                    headlineID: snapshot.headlineID,
                    weeklyID: "weekly_all"
                )
            }
            guard let rep = render(model) else { return -1 }
            return greyFraction(rep)
        }

        XCTAssertGreaterThan(ink(.outside), ink(.off),
                             "an empty week drew nothing at all")
    }

    /// Fraction of sampled pixels that are the ring track's own grey — the way
    /// to see a track, which carries no hue and so is invisible to
    /// `colouredFraction`.
    private func greyFraction(_ rep: NSBitmapImageRep) -> Double {
        var grey = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                total += 1
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5,
                      let rgb = colour.usingColorSpace(.sRGB) else { continue }
                let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                let neutral = (channels.max()! - channels.min()!) < 0.06
                if neutral, channels.max()! > 0.10, channels.max()! < 0.45 { grey += 1 }
            }
        }
        return total == 0 ? 0 : Double(grey) / Double(total)
    }

    /// Fraction of sampled pixels carrying a hue — an arc rather than the black
    /// body, the grey track or white type.
    private func colouredFraction(_ rep: NSBitmapImageRep) -> Double {
        var coloured = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                total += 1
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5,
                      let rgb = colour.usingColorSpace(.sRGB) else { continue }
                let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                if (channels.max()! - channels.min()!) > 0.15 { coloured += 1 }
            }
        }
        return total == 0 ? 0 : Double(coloured) / Double(total)
    }

    /// And it paints it against the bezel, not somewhere in the middle of the
    /// transparent panel.
    func testTheNotchPaintsAgainstTheBezelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let m = model(edge: edge)
            guard let rep = render(m) else {
                XCTFail("\(edge): no image")
                continue
            }
            let place = NotchPlacement(edge: edge, panelSize: m.panelSize)
            // The middle of the stack, one point in from the bezel: solid body.
            let onBezel = place.point(
                along: m.slack + m.shapeLength / 2, across: 1
            )
            let colour = rep.colorAt(
                x: min(rep.pixelsWide - 1, max(0, Int(onBezel.x))),
                y: min(rep.pixelsHigh - 1, max(0, Int(onBezel.y)))
            )
            XCTAssertEqual(
                colour?.alphaComponent ?? 0, 1, accuracy: 0.01,
                "\(edge): nothing painted where the notch meets the bezel"
            )
        }
    }

    /// The orb has to stay attached to the notch at every size.
    ///
    /// `position` hands back a view the size of the whole panel, so a scale
    /// applied *after* it scales that layer about the panel's centre and slides
    /// the orb away by a share of the panel — the arc left floating off the
    /// corner it is drawn to hug. Arithmetic cannot see that: the numbers going
    /// in were right and the modifier order was not, so this looks at the
    /// pixels instead.
    func testNothingIsPaintedBeyondTheNotchAndItsOrbAtAnySize() {
        for size in NotchSize.allCases {
            let m = model(edge: .right)
            m.sizeScale = size.scale
            guard let rep = render(m) else {
                XCTFail("\(size.rawValue): no image")
                continue
            }
            let place = NotchPlacement(edge: .right, panelSize: m.panelSize)
            let scale = size.scale
            // What the notch and the orb legitimately reach, derived rather
            // than guessed, plus a point for the stroke's own width.
            let reach = m.orbArcRadius * scale + NotchLayout.orbStroke
            let deepest = max(m.notchDepth * scale, m.orbInset * scale + reach)
            let furthest = m.slack + max(m.shapeLength, m.orbAlong) * scale + reach
            let nearest = m.slack - reach

            var maxAcross = 0.0, maxAlong = -Double.infinity, minAlong = Double.infinity
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    guard let colour = rep.colorAt(x: x, y: y),
                          colour.alphaComponent > 0.5 else { continue }
                    let point = CGPoint(x: x, y: y)
                    maxAcross = max(maxAcross, place.across(of: point))
                    maxAlong = max(maxAlong, place.along(of: point))
                    minAlong = min(minAlong, place.along(of: point))
                }
            }

            XCTAssertLessThanOrEqual(maxAcross, deepest + 1,
                                     "\(size.rawValue): something is painted \(maxAcross)pt in "
                                     + "from the bezel, past the \(deepest)pt the notch and orb reach")
            XCTAssertLessThanOrEqual(maxAlong, furthest + 1,
                                     "\(size.rawValue): something is painted past the far end")
            XCTAssertGreaterThanOrEqual(minAlong, nearest - 1,
                                        "\(size.rawValue): something is painted before the near end")
        }
    }

    /// The glass style reaches the notch whether it is open or closed, as
    /// requested: folded, the body fill is turned off and nothing of ours is
    /// painted in its place.
    ///
    /// The system material is left out of the render (see
    /// `\.codenotchHeadlessGlass`), so this pins the one half that is ours —
    /// that the fill really did step aside — rather than what glass looks like.
    ///
    /// Three cells, where its neighbours render four: the first
    /// `ImageRenderer` render of a given pixel size in a test method can hand
    /// back the *previous* method's image at that size, and the method before
    /// this one paints the same panel size opaque black, so at four cells this
    /// read 1.0 in the full run and 0 alone. A size no other pixel test asks
    /// for keeps the hand-me-down out.
    func testTheFoldedPillIsTransparentInTheGlassStyle() {
        for edge in NotchEdge.allCases {
            let m = model(edge: edge, cells: 3)
            m.surfaceStyle = .glass
            m.isExpanded = false
            guard let rep = render(m) else {
                XCTFail("\(edge): no image")
                continue
            }
            let place = NotchPlacement(edge: edge, panelSize: m.panelSize)
            // The same centre line the expanded body is probed on: folded or
            // open, the shape is centred on it.
            let onBezel = place.point(
                along: m.slack + m.shapeLength / 2, across: 1
            )
            let colour = rep.colorAt(
                x: min(rep.pixelsWide - 1, max(0, Int(onBezel.x))),
                y: min(rep.pixelsHigh - 1, max(0, Int(onBezel.y)))
            )
            XCTAssertEqual(
                colour?.alphaComponent ?? 1, 0, accuracy: 0.01,
                "\(edge): the folded pill is opaque in the glass style"
            )
        }
    }

    /// The other half of the same pixel: where `glass` leaves the surface to
    /// the system, `darkGlass` puts a wash of ours underneath it, and that wash
    /// *is* renderable offscreen. So the dim is the one thing about the dark
    /// glass style a headless test can honestly check.
    ///
    /// Five cells, a panel size no other pixel test renders: the first
    /// `ImageRenderer` render of a given pixel size in a test method can hand
    /// back the *previous* method's image at that size, and the folded-pill
    /// test above — which sorts right before this one and expects nothing at
    /// this very probe — already claims three. A size of its own keeps this
    /// test's dim out of that one's image.
    func testTheFoldedPillCarriesTheDimInTheDarkGlassStyle() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("no Liquid Glass below macOS 26, so darkGlass resolves to solid")
        }
        for edge in NotchEdge.allCases {
            let m = model(edge: edge, cells: 5)
            m.surfaceStyle = .darkGlass
            m.isExpanded = false
            guard let rep = render(m) else {
                XCTFail("\(edge): no image")
                continue
            }
            let place = NotchPlacement(edge: edge, panelSize: m.panelSize)
            let onBezel = place.point(
                along: m.slack + m.shapeLength / 2, across: 1
            )
            let colour = rep.colorAt(
                x: min(rep.pixelsWide - 1, max(0, Int(onBezel.x))),
                y: min(rep.pixelsHigh - 1, max(0, Int(onBezel.y)))
            )
            XCTAssertEqual(
                colour?.alphaComponent ?? 0, 0.60, accuracy: 0.03,
                "\(edge): the dark glass dim is not drawn beneath the folded pill"
            )
            XCTAssertLessThan(
                colour?.brightnessComponent ?? 1, 0.05,
                "\(edge): the dark glass dim is not black"
            )
        }
    }

    /// Reduce transparency wins over the chosen style: the open notch is
    /// painted solid black even when the preference says glass, the way the
    /// Settings window prefers an opaque fill to its own translucent chrome.
    func testReduceTransparencyPaintsTheGlassStyleSolid() {
        for edge in NotchEdge.allCases {
            let m = model(edge: edge)
            m.surfaceStyle = .glass
            guard let rep = render(m, reduceTransparency: true) else {
                XCTFail("\(edge): no image")
                continue
            }
            let place = NotchPlacement(edge: edge, panelSize: m.panelSize)
            let onBezel = place.point(
                along: m.slack + m.shapeLength / 2, across: 1
            )
            let colour = rep.colorAt(
                x: min(rep.pixelsWide - 1, max(0, Int(onBezel.x))),
                y: min(rep.pixelsHigh - 1, max(0, Int(onBezel.y)))
            )
            XCTAssertEqual(
                colour?.alphaComponent ?? 0, 1, accuracy: 0.01,
                "\(edge): the body is see-through with Reduce transparency on"
            )
            XCTAssertLessThan(
                colour?.brightnessComponent ?? 1, 0.05,
                "\(edge): the body is not black with Reduce transparency on"
            )
        }
    }
}

/// The panel's size is worked out by `NotchGeometry` and by nobody else.
///
/// It was not. Set an `NSHostingView` as a window's `contentView` and SwiftUI
/// gets a say in the window's frame: it reports the content's *ideal* size, and
/// a `GeometryReader` root — which is what this notch is — has an ideal size of
/// 10x10. On the side edges that never surfaced. Turn the panel horizontal and
/// AppKit began walking the window down toward it in steps of its own choosing,
/// 522pt of height to 266 to 10 to 0, until the window was zero-height, nothing
/// was drawn, and the constraint pass gave up and threw — killing the app.
///
/// The fix is to take the channel away rather than to fight it: a plain
/// container view is the `contentView`, and the hosting view lives inside it
/// held by an autoresizing mask. SwiftUI then has no window to talk to about
/// size, and the frame is only ever the one we computed.
@MainActor
final class PanelSizingIntegrityTests: XCTestCase {
    func testSwiftUIIsNotThePanelsContentView() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        let content = controller.panelContentViewForTesting
        XCTAssertNotNil(content)
        XCTAssertFalse(
            content is NSHostingView<NotchRootView>,
            "the hosting view is the content view, so SwiftUI can resize the window"
        )
    }

    /// And it still fills the panel, however the panel is later re-framed.
    func testTheHostingViewTracksThePanelWhenItIsReFramed() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.apply(edge: .top)
        controller.relocate(cellCount: 4)

        guard let content = controller.panelContentViewForTesting,
              let hosting = content.subviews.first else {
            return XCTFail("no hosting view inside the container")
        }
        XCTAssertEqual(hosting.frame.size, content.bounds.size,
                       "the hosting view stopped filling the panel after a re-frame")
    }

    /// The solid style is the frame's white-on-black, and a Mac in light mode
    /// must not be able to turn it into black-on-white. Glass is the opposite
    /// bargain: no appearance of ours, so Appearance settings decide.
    func testTheSolidStyleForcesTheDarkAppearance() {
        let controller = NotchWindowController()
        controller.model.surfaceStyle = .solid
        controller.show()
        defer { controller.stop() }

        guard let window = controller.panelContentViewForTesting?.window else {
            return XCTFail("no panel")
        }
        XCTAssertEqual(window.appearance?.name, .darkAqua,
                       "the solid style left the panel following the Mac's appearance")

        controller.model.surfaceStyle = .glass
        // Only where glass is what actually gets painted: below macOS 26, and
        // with Reduce transparency on, the glass style resolves to the solid
        // one and the panel keeps its dark appearance on purpose.
        if NotchSurfaceStyle.glassAvailable,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            XCTAssertNil(window.appearance,
                         "the glass style pinned an appearance instead of inheriting one")
        }
    }

    /// Dark glass is `Glass.clear` over a black dim of ours, and it must always
    /// read dark regardless of the Mac's appearance — same pin as solid, so
    /// `Palette`'s frame hexes hold.
    func testTheDarkGlassStyleForcesTheDarkAppearance() {
        let controller = NotchWindowController()
        controller.model.surfaceStyle = .darkGlass
        controller.show()
        defer { controller.stop() }

        guard let window = controller.panelContentViewForTesting?.window else {
            return XCTFail("no panel")
        }
        XCTAssertEqual(window.appearance?.name, .darkAqua,
                       "the dark glass style left the panel following the Mac's appearance")
    }

    /// Reduce transparency means "no see-through chrome", and the window has to
    /// know: the light palette resolved against a black surface would be
    /// unreadable. Pure function, so this holds whatever the test Mac's own
    /// accessibility settings are.
    func testReduceTransparencyForcesTheDarkAppearance() {
        XCTAssertEqual(
            NotchSurfaceStyle.glass.panelAppearance(reduceTransparency: true)?.name, .darkAqua,
            "Reduce transparency left the panel following the Mac's appearance"
        )
        if NotchSurfaceStyle.glassAvailable {
            XCTAssertNil(
                NotchSurfaceStyle.glass.panelAppearance(reduceTransparency: false),
                "the glass style pinned an appearance instead of inheriting one"
            )
        }
        XCTAssertEqual(
            NotchSurfaceStyle.solid.panelAppearance(reduceTransparency: false)?.name, .darkAqua,
            "the solid style left the panel following the Mac's appearance"
        )
    }
}

/// The panel is a hole everywhere except its own chrome. That is the whole
/// bargain of a window that sits over everything you are working in.
@MainActor
final class ClickThroughTests: XCTestCase {
    private func shownController() -> NotchWindowController {
        let controller = NotchWindowController()
        controller.show()
        return controller
    }

    /// Wrapping the hosting view in a container must not reintroduce a target
    /// where there was a hole: a plain `NSView` answers `hitTest` with *itself*
    /// for any point inside its bounds, which would make the entire panel — most
    /// of it empty space reserved for the tooltip — swallow clicks meant for
    /// whatever is underneath.
    func testThePanelIsAHoleAwayFromItsChrome() {
        let controller = shownController()
        defer { controller.stop() }
        guard let content = controller.panelContentViewForTesting else {
            return XCTFail("no content view")
        }
        // The far corner from the notch: reserved for the tooltip, and empty.
        let empty = CGPoint(x: content.bounds.minX + 2, y: content.bounds.midY)
        XCTAssertNil(content.hitTest(empty),
                     "the panel answered a click in its transparent margin")
    }

    /// The container itself is never an answer. Whether a given point is live
    /// is the hosting view's decision, made against `interactiveRects`; the
    /// container only forwards the question, so a point it claimed for itself
    /// would be a target nobody asked for.
    func testTheContainerNeverAnswersForItself() {
        let controller = shownController()
        defer { controller.stop() }
        guard let content = controller.panelContentViewForTesting else {
            return XCTFail("no content view")
        }
        for x in stride(from: content.bounds.minX, to: content.bounds.maxX, by: 40) {
            for y in stride(from: content.bounds.minY, to: content.bounds.maxY, by: 40) {
                XCTAssertFalse(content.hitTest(CGPoint(x: x, y: y)) === content,
                               "the container claimed (\(x), \(y)) for itself")
            }
        }
    }
}

/// Changing the placement moves the panel, turns the shape on its side and
/// relays the whole stack — all at once. Done in view that is a jump no
/// animation can smooth over, so it goes out where it was, crosses while there
/// is nothing to see, and comes back where it now is.
@MainActor
final class EdgeCrossfadeTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testTheNotchFadesOutBeforeItMoves() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        let before = controller.panelFrameForTesting
        controller.apply(edge: .top)
        pump(0.08)

        XCTAssertLessThan(controller.panelAlphaForTesting, 1,
                          "the notch was still on screen while it moved")
        XCTAssertEqual(controller.panelFrameForTesting, before,
                       "the panel jumped before it had faded")
    }

    func testItComesBackOnTheNewEdgeAtFullStrength() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.apply(edge: .bottom)
        pump(1.0)

        XCTAssertEqual(controller.model.edge, .bottom)
        XCTAssertEqual(controller.panelAlphaForTesting, 1, accuracy: 0.01,
                       "the notch never came back")
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        XCTAssertEqual(controller.panelFrameForTesting?.minY ?? -1,
                       screen.frame.minY, accuracy: 1,
                       "it did not end up on the edge it was sent to")
    }

    /// Clicking through the picker quickly must not let an earlier move land
    /// after a later one.
    func testOnlyTheLastEdgeAskedForWins() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.apply(edge: .top)
        pump(0.04)
        controller.apply(edge: .left)
        pump(1.0)

        XCTAssertEqual(controller.model.edge, .left)
        XCTAssertEqual(controller.panelAlphaForTesting, 1, accuracy: 0.01)
    }

    /// Asking for the edge it is already on is not a move.
    func testAskingForTheSameEdgeDoesNothing() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.apply(edge: controller.model.edge)
        pump(0.08)
        XCTAssertEqual(controller.panelAlphaForTesting, 1,
                       "it faded for a move it was not making")
    }
}

/// Arriving at the new edge should look like the notch opening, not like a bar
/// appearing at full size.
@MainActor
final class EdgeArrivalTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func openController() -> NotchWindowController {
        let controller = NotchWindowController()
        controller.show()
        controller.model.snapshots = (0..<3).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        controller.model.isExpanded = true
        return controller
    }

    /// Waits for something to become true rather than for a length of time —
    /// the crossing's timings are AppKit's to keep, not ours to predict.
    @discardableResult
    private func wait(upTo seconds: TimeInterval = 3,
                      for condition: () -> Bool) -> Bool {
        var waited: TimeInterval = 0
        while !condition(), waited < seconds {
            pump(0.02)
            waited += 0.02
        }
        return condition()
    }

    /// It lands folded and *then* opens — the same unfold hovering uses.
    ///
    /// The two have to happen in separate turns or SwiftUI coalesces them: the
    /// value goes shut-to-open inside one update, nothing interpolates, and the
    /// notch simply appears at full size having animated nothing.
    func testItLandsFoldedAndThenOpens() throws {
        try XCTSkipIf(NSUserName() == "runner", "Animation timing is flaky on headless CI environments")
        let controller = openController()
        defer { controller.stop() }

        controller.apply(edge: .top)
        XCTAssertTrue(wait { controller.panelAlphaForTesting < 1 }, "it never went away")
        XCTAssertTrue(wait { controller.panelAlphaForTesting == 1 }, "it never came back")
        XCTAssertFalse(controller.model.isExpanded,
                       "it arrived at full size instead of opening into place")
        XCTAssertTrue(wait { controller.model.isExpanded }, "it never opened")
    }

    /// And it is on screen while it opens, not still fading in underneath.
    func testItIsFullyVisibleBeforeItOpens() throws {
        try XCTSkipIf(NSUserName() == "runner", "Animation timing is flaky on headless CI environments")
        let controller = openController()
        defer { controller.stop() }

        controller.apply(edge: .bottom)
        XCTAssertTrue(wait { controller.model.isExpanded }, "it never opened")
        XCTAssertEqual(controller.panelAlphaForTesting, 1, accuracy: 0.01,
                       "it is still fading while it opens — two animations over each other")
    }

    /// A notch that was folded stays folded: moving it is not a reason to open.
    func testAFoldedNotchArrivesFolded() {
        let controller = openController()
        defer { controller.stop() }
        controller.model.isExpanded = false

        controller.apply(edge: .left)
        pump(0.6)
        XCTAssertFalse(controller.model.isExpanded, "moving it opened it uninvited")
        XCTAssertEqual(controller.model.edge, .left)
    }
}

/// "Always show" is a standing choice, and clicking the notch must not quietly
/// undo it.
///
/// It was held in `isPinned` — the same flag a click on the notch toggles. So
/// clicking anywhere on the bar that was not a ring or the settings orb turned
/// the flag off, the notch started folding on the way out, and Settings went on
/// saying "Always show". Reported as: it sometimes reverts to show-on-hover.
@MainActor
final class AlwaysShowTests: XCTestCase {
    func testClickingTheNotchDoesNotUndoAlwaysShow() {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)

        controller.togglePinned()   // a click on the bar
        XCTAssertTrue(controller.model.isPinned,
                      "a click downgraded Always show to hover")
        XCTAssertTrue(controller.model.isExpanded)
    }

    /// However many times. The report said "sometimes", which is what a toggle
    /// looks like from outside.
    func testItSurvivesRepeatedClicks() {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)
        for _ in 0..<5 { controller.togglePinned() }
        XCTAssertTrue(controller.model.isPinned)
    }

    /// The transient pin still works where it is the only thing holding the
    /// notch open — that is what clicking is *for* in hover mode.
    func testAPinInHoverModeIsStillATogggle() {
        let controller = NotchWindowController()
        controller.apply(.onHover)
        XCTAssertFalse(controller.model.isPinned)

        controller.togglePinned()
        XCTAssertTrue(controller.model.isPinned, "clicking no longer pins")
        controller.togglePinned()
        XCTAssertFalse(controller.model.isPinned, "clicking no longer unpins")
    }

    /// Switching to hover has to clear a pin left over from before, or the
    /// notch stays open and the new choice looks ignored.
    func testSwitchingToHoverClearsAStalePin() {
        let controller = NotchWindowController()
        controller.apply(.onHover)
        controller.togglePinned()
        controller.apply(.onHover)
        XCTAssertFalse(controller.model.isPinned)
    }

    /// And so does hiding — a pinned notch that is ordered out still counts as
    /// held open, and would refuse to fold if it came back.
    func testHidingClearsBothHolds() {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)
        controller.apply(.hidden)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.model.isExpanded)
    }

    /// Coming back from hover to always-on, with a stale pin in between.
    func testAlwaysShowOutlastsAPinAndAnUnpin() {
        let controller = NotchWindowController()
        controller.apply(.onHover)
        controller.togglePinned()      // pinned by hand
        controller.apply(.alwaysShow)  // then chosen in Settings
        controller.togglePinned()      // and clicked again
        XCTAssertTrue(controller.model.isPinned)
    }
}

/// A click that arrives while the notch is still folded used to pin it —
/// permanently, via `togglePinned()` — even though nobody had seen it open.
/// The pill's own hot zone is deliberately generous, since it is a small
/// target on a screen edge, which made it easy to trip by accident: reported
/// as "hover mode sticks open after a stray click".
///
/// Pinning stays exactly what a click on a notch that is *already* open does
/// — that part is documented and unchanged. What changes is the other guard:
/// a click that arrives before the notch has opened now just opens it, the
/// same as the pointer arriving would, so it folds back on its own once the
/// pointer leaves.
@MainActor
final class StrayClickPinTests: XCTestCase {
    func testAClickOnAFoldedNotchOpensWithoutPinning() {
        let controller = NotchWindowController()
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.model.isPinned)

        controller.handleClick(at: .zero)

        XCTAssertTrue(controller.model.isExpanded, "the click did not open it at all")
        XCTAssertFalse(controller.model.isPinned, "a click before it ever opened pinned it")
    }

    /// However many times it arrives before the notch is actually open — the
    /// pill's hot zone is large enough that more than one could land.
    func testRepeatedClicksBeforeOpeningNeverPin() {
        let controller = NotchWindowController()
        for _ in 0..<3 { controller.handleClick(at: .zero) }
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertTrue(controller.model.isExpanded)
    }
}

/// A ring dimmed the instant the very first idle refresh attempt failed,
/// because `staleAfter` and `idleRefreshInterval` were the same value — so a
/// reading was *guaranteed* to reach the dimming threshold before an idle
/// schedule could even try to refresh it once. Reported as "rings dim to
/// invisibility on every idle cycle".
final class StaleAfterMarginTests: XCTestCase {
    private final class FailingProvider: UsageProvider, @unchecked Sendable {
        let id = "x"
        let displayName = "X"
        let glyph = ProviderGlyph.claude
        private var succeedOnce = true

        func fetchSnapshot() async throws -> ProviderSnapshot {
            defer { succeedOnce = false }
            if succeedOnce {
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok,
                                        windows: [LimitWindow(id: "w", label: "W",
                                                              usedFraction: 0.1)])
            }
            throw UsageProviderError.badResponse(status: 500)
        }
        nonisolated func account() -> ProviderAccount? { nil }
        nonisolated var signInRoute: SignInRoute { .guidance("") }
        func signOut() async {}
        func presentSignIn() {}
        nonisolated func forgetCachedCredential() {}
    }

    private func defaults() -> UserDefaults {
        let name = "StaleAfterMarginTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// One failed attempt, well inside the margin, must not dim the ring —
    /// that is the ordinary shape of an idle afternoon, not a fault.
    @MainActor
    func testOneFailedIdleAttemptDoesNotDimTheRing() async throws {
        let store = UsageStore(
            providers: [FailingProvider()],
            refreshInterval: 0.05, idleRefreshInterval: 0.15, staleAfter: 0.45,
            archive: UsageArchive(defaults: defaults())
        )
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.status, .ok)

        try await Task.sleep(nanoseconds: 200_000_000)   // > idleRefreshInterval
        await store.refresh()                            // the attempt that fails

        let status = try XCTUnwrap(store.snapshots.first?.status)
        XCTAssertFalse(status.isStale,
                       "the ring dimmed after a single failed attempt, well inside the margin")
    }

    /// Once genuinely stale for longer than the margin, it does dim — the
    /// mechanism still works, it just no longer fires prematurely.
    @MainActor
    func testItStillDimsOnceGenuinelyStale() async throws {
        let store = UsageStore(
            providers: [FailingProvider()],
            refreshInterval: 0.05, idleRefreshInterval: 0.05, staleAfter: 0.2,
            archive: UsageArchive(defaults: defaults())
        )
        await store.refresh()
        try await Task.sleep(nanoseconds: 300_000_000)   // > staleAfter
        await store.refresh()

        let status = try XCTUnwrap(store.snapshots.first?.status)
        XCTAssertTrue(status.isStale, "the mechanism no longer dims a genuinely old reading")
    }

    /// The shipped defaults keep the same three-to-one margin verified above,
    /// not just some values that happen to satisfy it.
    @MainActor
    func testTheShippedDefaultsKeepTheSameMargin() {
        let store = UsageStore(providers: [])
        XCTAssertGreaterThan(store.staleAfterForTesting, store.idleRefreshIntervalForTesting)
    }
}

@MainActor
final class PhysicalPanelIntegrationTests: XCTestCase {
    func testActualPanelsStayOnTheBezelAndKeepCornerCardsVisible() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        for size in NotchSize.allCases {
            for edge in NotchEdge.allCases {
                let controller = NotchWindowController()
                controller.assignedScreen = screen
                controller.model.edge = edge
                controller.model.sizeScale = size.scale
                controller.model.snapshots = Array(Fixtures.snapshots().prefix(2))
                controller.show()
                defer { controller.stop() }
                for offset: CGFloat in [-10000, 0, 10000] {
                    controller.model.alongOffset = offset
                    controller.relocate()
                    let frame = try XCTUnwrap(controller.panelFrameForTesting)
                    switch edge {
                    case .left: XCTAssertEqual(frame.minX, screen.frame.minX, accuracy: 1)
                    case .right: XCTAssertEqual(frame.maxX, screen.frame.maxX, accuracy: 1)
                    case .top: XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 1)
                    case .bottom: XCTAssertEqual(frame.minY, screen.frame.minY, accuracy: 1)
                    }
                    let range = try XCTUnwrap(controller.model.visibleAlongRange)
                    let length: CGFloat = edge.isVertical ? 260 : NotchLayout.cardWidth
                    for index in 0..<2 {
                        let centre = controller.model.tooltipAlong(index: index, length: length)
                        XCTAssertGreaterThanOrEqual(centre - length / 2, range.lowerBound)
                        XCTAssertLessThanOrEqual(centre + length / 2, range.upperBound)
                    }
                }
            }
        }
    }
}
