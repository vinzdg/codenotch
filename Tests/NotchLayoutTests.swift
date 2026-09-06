import XCTest
@testable import Codenotch

/// The layout is a scaled copy of `docs/design/frame-124-hover-tooltip.png`.
/// These pin the ratios the frame fixes, so a change to `Design.scale` resizes
/// everything without silently reshaping it.
final class NotchLayoutTests: XCTestCase {
    func testRingIsTheSpecAnchor() {
        XCTAssertEqual(NotchLayout.ringDiameter, 44, accuracy: 0.001)
    }

    func testProportionsMatchTheFrame() {
        // 186px body against a 117px ring.
        XCTAssertEqual(NotchLayout.bodyDepth(for: .right) / NotchLayout.ringDiameter, 186.0 / 117.0, accuracy: 0.001)
        // Cell centre to cell centre is 275px in the frame. Looser, because
        // the pitch includes a real font's line box rather than a measured
        // cap height, and SF's metrics are not the frame's to the pixel.
        XCTAssertEqual(NotchLayout.cellPitch(for: .right) / NotchLayout.ringDiameter, 275.0 / 117.0, accuracy: 0.05)
        // The card is 600px wide.
        XCTAssertEqual(NotchLayout.cardWidth / NotchLayout.ringDiameter, 600.0 / 117.0, accuracy: 0.001)
    }

    func testShapeGrowsOneCellAtATime() {
        let cell = NotchLayout.cellExtent
        let one = NotchLayout.shapeLength(cellCount: 1)
        let two = NotchLayout.shapeLength(cellCount: 2)
        XCTAssertEqual(two - one, cell + NotchLayout.cellSpacing, accuracy: 0.001)
    }

    func testRingCentresAreEvenlySpacedInsideTheBody() {
        let first = NotchLayout.ringCenter(index: 0)
        XCTAssertEqual(
            first,
            NotchLayout.curlRadius + NotchLayout.padTop + NotchLayout.ringDiameter / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchLayout.ringCenter(index: 2) - NotchLayout.ringCenter(index: 1),
            NotchLayout.cellPitch(for: .right),
            accuracy: 0.001
        )
    }

    /// The session list is extra card, so the hover region has to grow with it
    /// or the pointer falls out of the bottom of a card it is still over.
    func testCardGrowsWithTheSessionList() {
        let bare = NotchLayout.cardHeight(windowCount: 2)
        let one = NotchLayout.cardHeight(windowCount: 2, sessionCount: 1)
        let two = NotchLayout.cardHeight(windowCount: 2, sessionCount: 2)
        XCTAssertGreaterThan(one, bare)
        XCTAssertEqual(
            two - one,
            2 * NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap + NotchLayout.blockSpacing,
            accuracy: 0.001
        )
    }

    /// The activity indicator lives in the gap between the glyph and the inside
    /// edge of the track, and must not touch either.
    func testActivityRingClearsTheGlyphAndTheTrack() {
        let outerEdge = NotchLayout.activityDiameter / 2 + NotchLayout.activityStroke / 2
        let innerEdge = NotchLayout.activityDiameter / 2 - NotchLayout.activityStroke / 2
        let trackInnerEdge = NotchLayout.ringDiameter / 2 - NotchLayout.trackStroke
        XCTAssertLessThan(outerEdge, trackInnerEdge)
        XCTAssertGreaterThan(innerEdge, NotchLayout.glyphSize / 2)
    }

    /// Every cell's tooltip has to fit inside the panel, or the card would be
    /// clipped for the first and last providers.
    func testTooltipFitsThePanelForEveryCell() {
        let cells = 3
        let cardHalf = NotchLayout.cardHeight(windowCount: 2) / 2
        let panelHeight = NotchLayout.shapeLength(cellCount: cells)
            + 2 * NotchLayout.slack(for: .right)
        for index in 0..<cells {
            let centre = NotchLayout.slack(for: .right) + NotchLayout.ringCenter(index: index)
            XCTAssertGreaterThanOrEqual(centre - cardHalf, 0)
            XCTAssertLessThanOrEqual(centre + cardHalf, panelHeight)
        }
    }
}

/// The panel has to be sized for the provider list that caused the change, not
/// the one the model still holds.
///
/// `@Published` notifies subscribers in `willSet`, so a sink that reacts to
/// `snapshots` changing and then reads `model.snapshots` back sees the *previous*
/// array. That is how the panel ended up sized for zero cells while one was on
/// screen — and a panel too short for its shape clips the bottom flare, which is
/// visible as the notch looking cut off instead of curving into the bezel.
@MainActor
final class PanelSizingTests: XCTestCase {
    func testPanelGrowsWithTheProviderCount() {
        let model = NotchViewModel()
        let empty = model.panelSize(cellCount: 0).height
        let one = model.panelSize(cellCount: 1).height
        let two = model.panelSize(cellCount: 2).height
        XCTAssertGreaterThan(one, empty)
        XCTAssertGreaterThan(two, one)
    }

    /// Sizing must not depend on what `snapshots` happens to hold right now.
    func testSizingIgnoresTheModelsCurrentList() {
        let model = NotchViewModel()
        XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertEqual(
            model.panelSize(cellCount: 1).height,
            model.shapeLength(cellCount: 1) + 2 * NotchLayout.slack(for: .right),
            accuracy: 0.001
        )
    }

    /// Whatever the count, the panel always has room for the whole shape —
    /// flares included — or the ends get cut off.
    func testThePanelAlwaysFitsTheWholeShape() {
        let model = NotchViewModel()
        for count in 0...5 {
            let panel = model.panelSize(cellCount: count).height
            let shape = model.shapeLength(cellCount: count)
            XCTAssertGreaterThanOrEqual(panel, shape, "\(count) cells: panel \(panel) < shape \(shape)")
        }
    }
}

/// The notch folds away to a pill so it stops being in the way, and unfolds on
/// contact. These pin the geometry that makes that bearable to live with.
@MainActor
final class FoldedNotchTests: XCTestCase {
    private func model(cells: Int) -> NotchViewModel {
        let model = NotchViewModel()
        model.snapshots = (0..<cells).map {
            ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        return model
    }

    func testFoldedIsFarSmallerThanOpen() {
        let m = model(cells: 3)
        m.isExpanded = false
        let folded = m.notchSize
        m.isExpanded = true
        let open = m.notchSize
        XCTAssertLessThan(folded.width, open.width / 2)
        XCTAssertLessThan(folded.height, open.height / 2)
    }

    /// Both states share a centre line, so folding does not slide the notch up
    /// the screen as it shrinks — it contracts in place.
    func testFoldingKeepsTheCentreLine() {
        let m = model(cells: 3)
        m.isExpanded = true
        let openCentre = m.notchLeadingInset + m.notchSize.height / 2
        m.isExpanded = false
        let foldedCentre = m.notchLeadingInset + m.notchSize.height / 2
        XCTAssertEqual(openCentre, foldedCentre, accuracy: 0.001)
    }

    /// The panel never resizes for the fold: animating a window frame is jerky,
    /// and the reserved space is transparent anyway.
    func testThePanelIsTheSameSizeEitherWay() {
        let m = model(cells: 3)
        m.isExpanded = true
        let open = m.panelSize
        m.isExpanded = false
        XCTAssertEqual(open, m.panelSize)
    }

    /// A 10pt target on a screen edge is fiddly, so the region that wakes it is
    /// deliberately bigger than the pill it surrounds.
    func testTheWakeRegionIsLargerThanThePill() {
        XCTAssertGreaterThan(NotchLayout.pillHotZone, NotchLayout.pillWidth)
    }
}

/// Motion is a vocabulary, not a pile of magic numbers.
final class NotchMotionTests: XCTestCase {
    func testTheStaggerIsBounded() {
        XCTAssertEqual(NotchMotion.stagger(index: 0), NotchMotion.contents.delay(0))
        XCTAssertEqual(NotchMotion.stagger(index: 99), NotchMotion.contents.delay(0.18))
    }

    /// Reduce Motion means no animation at all, not a faster one.
    func testReduceMotionRemovesTheAnimation() {
        XCTAssertNil(NotchMotion.respectingReduceMotion(NotchMotion.unfold, true))
        XCTAssertNotNil(NotchMotion.respectingReduceMotion(NotchMotion.unfold, false))
    }

    /// The stagger is capped, so a long provider list never feels sluggish.
}

/// The shape has to stay a notch at every size it is drawn at — including the
/// pill, which is narrower than the flare radius it was designed around.
final class SideNotchShapeTests: XCTestCase {
    private func bounds(width: CGFloat, height: CGFloat) -> CGRect {
        SideNotchShape().path(in: CGRect(x: 0, y: 0, width: width, height: height)).boundingRect
    }

    /// The bug: clamping the corner by `width - curl` collapsed it to zero as
    /// soon as the flare was as wide as the body, so the folded pill came out
    /// with square corners.
    func testTheFoldedPillKeepsItsCorners() {
        let width = NotchLayout.pillWidth
        let path = SideNotchShape().path(
            in: CGRect(x: 0, y: 0, width: width, height: NotchLayout.pillHeight)
        )
        // A square-cornered pill touches its own top-left corner; a rounded one
        // never does.
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)),
                       "the pill's top-left corner is square")
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: NotchLayout.pillHeight - 0.5)),
                       "the pill's bottom-left corner is square")
    }

    /// Fixing the pill must not reshape the notch the design frame was measured
    /// from: at full width the flare is wider than half the body and must stay so.
    func testTheOpenNotchIsUnchanged() {
        let width = NotchLayout.bodyDepth(for: .right)
        let path = SideNotchShape().path(in: CGRect(x: 0, y: 0, width: width, height: 400))
        XCTAssertEqual(path.boundingRect.width, width, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.height, 400, accuracy: 0.5)

        // The flare: near the top the shape is a sliver hugging the edge, and by
        // mid-height it is the full body. Sampled rather than probed at a single
        // point — a point 1pt down sits in a flare only hundredths of a point
        // wide, which is a fact about arcs, not about the shape being wrong.
        func filled(atY y: CGFloat) -> CGFloat {
            let hits = stride(from: CGFloat(0.25), to: width, by: 0.25)
                .filter { path.contains(CGPoint(x: $0, y: y)) }
            return hits.isEmpty ? 0 : width - hits.min()!
        }
        XCTAssertLessThan(filled(atY: 4), width / 3, "no flare at the top")
        XCTAssertEqual(filled(atY: 200), width, accuracy: 1, "not full width in the body")
        XCTAssertLessThan(filled(atY: 396), width / 3, "no flare at the bottom")
    }

    /// It is drawn at every size in between while folding, so none of them may
    /// produce a degenerate path.
    func testEveryIntermediateSizeIsDrawable() {
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let w = NotchLayout.pillWidth + (NotchLayout.bodyDepth(for: .right) - NotchLayout.pillWidth) * t
            let h = NotchLayout.pillHeight + (400 - NotchLayout.pillHeight) * t
            let box = bounds(width: w, height: h)
            XCTAssertFalse(box.isEmpty, "degenerate path at \(w) x \(h)")
            XCTAssertEqual(box.width, w, accuracy: 1)
        }
    }
}

/// The tooltip resizes when you move between providers, because they do not all
/// report the same number of windows. Its height is computed rather than left to
/// SwiftUI so the hover region matches — and these pin that it really does vary.
final class TooltipResizeTests: XCTestCase {
    func testHeightVariesWithTheNumberOfWindows() {
        let one = NotchLayout.cardHeight(windowCount: 1)
        let two = NotchLayout.cardHeight(windowCount: 2)
        XCTAssertGreaterThan(two, one)
    }

    /// Claude has two windows plus a session list; Codex has one and none. That
    /// difference is the exact case where unclipped contents used to hang
    /// outside a shorter background while the height was still animating.
    func testTheExtremesDifferEnoughToBeVisible() {
        let smallest = NotchLayout.cardHeight(windowCount: 1)
        let largest = NotchLayout.cardHeight(windowCount: 2, sessionCount: 2)
        XCTAssertGreaterThan(largest - smallest, 40,
                             "the resize is big enough that overflow would show")
    }

    func testAWindowlessCardStillHasARealHeight() {
        XCTAssertGreaterThan(NotchLayout.cardHeight(windowCount: 0), NotchLayout.cardPadding * 2)
    }
}

/// The tooltip is one object: a card with a tail welded to its side. What breaks
/// that illusion is the two halves moving on different schedules.
@MainActor
final class TooltipCohesionTests: XCTestCase {
    private func snapshot(windows: Int) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "p", displayName: "P", glyph: .claude, fidelity: .official, status: .ok,
            windows: (0..<windows).map {
                LimitWindow(id: "w\($0)", label: "W", usedFraction: 0.5, resetsAt: Date())
            }
        )
    }

    /// The card's drawn height and its hover region come from the same call, so
    /// what you can see and what you can reach cannot drift apart.
    func testDrawnHeightMatchesTheHoverRegion() {
        for windows in 0...3 {
            let s = snapshot(windows: windows)
            XCTAssertEqual(
                NotchLayout.cardHeight(windowCount: s.windows.count),
                NotchLayout.cardHeight(windowCount: windows),
                accuracy: 0.001
            )
        }
    }

    /// The tail is centred on the card's height, so a height that jumps takes
    /// the tail with it. Every step between two providers has to be a real
    /// number for that travel to be smooth.
    func testHeightIsContinuousAcrossProviderShapes() {
        let heights = (0...3).map { NotchLayout.cardHeight(windowCount: $0) }
        for height in heights {
            XCTAssertTrue(height.isFinite && height > 0)
        }
        XCTAssertEqual(Set(heights).count, heights.count, "each shape has its own height")
    }

    /// The tail never changes size, whatever the card is doing — it is a fixed
    /// piece of the silhouette, not something that scales with the contents.
    func testTheTailIsAFixedSize() {
        XCTAssertGreaterThan(NotchLayout.tailHeight, 0)
        XCTAssertGreaterThan(NotchLayout.tailLength, 0)
        XCTAssertLessThan(NotchLayout.tailHeight, NotchLayout.cardHeight(windowCount: 1),
                          "the tail must fit inside the shortest card it can point from")
    }
}

/// The rings are buttons — clicking one refetches that provider — so the cursor
/// should say so, and only there.
@MainActor
final class PointerStateTests: XCTestCase {
    func testACellShowsThePointingHand() {
        XCTAssertTrue(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: 0))
        XCTAssertTrue(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: 2))
    }

    /// The gap around the cells is not a button.
    func testTheRestOfTheNotchDoesNot() {
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: nil))
    }

    /// Folded, the pill is a handle you hover rather than a button you aim at,
    /// and a pointer that flashes on the way past is noise.
    func testTheFoldedPillDoesNot() {
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: false, cellIndex: 0))
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: false, cellIndex: nil))
    }
}

/// The settings orb sits in the corner the notch's bottom flare makes, and its
/// resting arc follows that curve rather than merely sitting near it.
@MainActor
final class SettingsOrbTests: XCTestCase {
    private func centre(_ count: Int) -> CGFloat {
        NotchLayout.orbCenterAlong(cellCount: count)
    }

    private func shapeBottom(_ count: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: count)
    }

    /// The whole point: the orb shares the flare's centre of curvature, so the
    /// two arcs are concentric and the resting stroke parallels the edge. Centre
    /// it anywhere else — on the body's axis, say — and it stops following the
    /// contour, which is exactly what went wrong first time.
    func testItSharesTheFlaresCentreOfCurvature() {
        XCTAssertEqual(NotchLayout.orbInsetFromEdge, NotchLayout.curlRadius, accuracy: 0.001)
        for count in 1...4 {
            XCTAssertEqual(centre(count), shapeBottom(count), accuracy: 0.001,
                           "\(count): the orb's centre must be the flare's centre")
        }
    }

    /// Inside the flare, with a real gap — touching it would read as a smudge on
    /// the notch rather than as a separate control.
    func testTheArcSitsInsideTheFlareWithAGap() {
        XCTAssertLessThan(NotchLayout.orbArcRadius, NotchLayout.curlRadius)
        let gap = NotchLayout.curlRadius - NotchLayout.orbArcRadius
        XCTAssertGreaterThan(gap, NotchLayout.orbStroke / 2,
                             "the stroke would touch the flare")
    }

    /// The filled disc goes inside the arc, so hovering does not push past it.
    func testTheDiscFitsWithinTheArc() {
        XCTAssertLessThan(NotchLayout.orbDiameter / 2, NotchLayout.orbArcRadius)
    }

    /// The notch itself must not grow for it — the orb is not part of the shape.
    func testTheNotchDoesNotGrowForIt() {
        let cells = NotchLayout.cellExtent
        let body = NotchLayout.bodyLength(cellCount: 2)
        let bare = NotchLayout.padTop + 2 * cells + NotchLayout.cellSpacing + NotchLayout.padBottom
        XCTAssertEqual(body, bare, accuracy: 0.001)
    }

    /// The panel has to reserve room below the shape or the orb is clipped away.
    func testThePanelHasRoomBelowTheNotch() {
        let overhang = NotchLayout.orbArcRadius + NotchLayout.orbStroke
        XCTAssertLessThanOrEqual(overhang, NotchLayout.slack(for: .right))
    }

    /// Like the pill's, the region you can hit is larger than what is drawn.
    func testTheHitRegionIsLargerThanTheOrb() {
        XCTAssertGreaterThan(NotchLayout.orbHotZone, NotchLayout.orbDiameter)
    }
}

/// Hiding a provider is stored as the hidden set, so one added in a later
/// version shows up by default rather than silently staying dark.
@MainActor
final class PreferencesTests: XCTestCase {
    private func preferences() -> Preferences {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    func testTheFirstLaunchIsAnnouncedExactlyOnce() {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        XCTAssertTrue(Preferences(defaults: defaults).isFirstLaunch)
        XCTAssertFalse(Preferences(defaults: defaults).isFirstLaunch,
                       "a returning user would be introduced to the app again")
    }

    func testEverythingIsConnectedByDefault() {
        let p = preferences()
        XCTAssertTrue(p.isConnected("claude"))
        XCTAssertTrue(p.isConnected("a-provider-that-does-not-exist-yet"))
    }

    func testConnectingAndDisconnectingRoundTrips() {
        let p = preferences()
        p.setConnected(false, for: "cursor")
        XCTAssertFalse(p.isConnected("cursor"))
        XCTAssertTrue(p.isConnected("claude"))
        p.setConnected(true, for: "cursor")
        XCTAssertTrue(p.isConnected("cursor"))
    }

    func testChoicesSurviveARestart() {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        Preferences(defaults: defaults).setConnected(false, for: "codex")
        XCTAssertFalse(Preferences(defaults: defaults).isConnected("codex"))
    }

    /// The key is deliberately unchanged across the rename, so choices made
    /// before it survive.
    func testItReadsChoicesStoredUnderTheOldName() {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(["cursor"], forKey: "hiddenProviders")

        XCTAssertFalse(Preferences(defaults: defaults).isConnected("cursor"))
    }
}

/// Settings shows whose account each reading comes from. Not decoration: the app
/// borrows credentials it does not own, so the account it reads can quietly be a
/// different one from the account you are using — which is exactly what happened
/// with Cursor during development.
final class ProviderAccountTests: XCTestCase {
    func testSummaryReadsAsASentence() {
        let account = ProviderAccount(
            label: "someone@example.com", plan: "free", source: "Cursor", manageURL: nil
        )
        XCTAssertEqual(account.summary, "someone@example.com · Free · via Cursor")
    }

    /// Claude's credential carries no address, so the row still has to say
    /// something useful rather than collapsing to an empty line.
    func testSummarySurvivesAMissingLabel() {
        let account = ProviderAccount(label: nil, plan: "pro", source: "Claude Code", manageURL: nil)
        XCTAssertEqual(account.summary, "Pro · via Claude Code")
    }

    func testSummarySurvivesAMissingPlan() {
        let account = ProviderAccount(label: "a@b.c", plan: nil, source: "Codex", manageURL: nil)
        XCTAssertEqual(account.summary, "a@b.c · via Codex")
    }

    /// The identity lives in the id token's claims. Decoding is base64url with
    /// the padding stripped, which plain base64 refuses.
    func testCodexClaimsDecodeFromABase64URLPayload() throws {
        let payload = #"{"email":"a@b.c","x":"-_"}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let claims = try XCTUnwrap(CodexCredentials.claims(inJWT: "header.\(encoded).signature"))
        XCTAssertEqual(claims["email"] as? String, "a@b.c")
    }

    func testMalformedTokensAreRefusedRatherThanCrashing() {
        XCTAssertNil(CodexCredentials.claims(inJWT: "nonsense"))
        XCTAssertNil(CodexCredentials.claims(inJWT: "only.two"))
        XCTAssertNil(CodexCredentials.claims(inJWT: "a.!!!!.c"))
    }

    func testAMissingAuthFileIsNotAnAccount() {
        let missing = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).json")
        XCTAssertNil(CodexCredentials.account(from: missing))
    }
}

/// `account()` is a protocol *requirement*, not just an extension default.
///
/// A method that exists only in a protocol extension is dispatched statically,
/// so calling it through `any UsageProvider` lands on the default and never on
/// the implementation. It fails silently — every account simply reports as
/// absent — which is what shipped for one build.
final class ProviderAccountDispatchTests: XCTestCase {
    private struct Silent: UsageProvider {
        let id = "silent"
        let displayName = "Silent"
        let glyph = ProviderGlyph.claude
        func fetchSnapshot() async throws -> ProviderSnapshot {
            throw UsageProviderError.needsAuth
        }
    }

    private struct Speaking: UsageProvider {
        let id = "speaking"
        let displayName = "Speaking"
        let glyph = ProviderGlyph.claude
        func fetchSnapshot() async throws -> ProviderSnapshot {
            throw UsageProviderError.needsAuth
        }
        func account() -> ProviderAccount? {
            ProviderAccount(label: "a@b.c", plan: "pro", source: "Test", manageURL: nil)
        }
    }

    /// Through the existential — the way the store actually calls it.
    func testAnImplementationIsFoundThroughTheProtocol() {
        let providers: [any UsageProvider] = [Silent(), Speaking()]
        XCTAssertNil(providers[0].account())
        XCTAssertEqual(providers[1].account()?.label, "a@b.c",
                       "the concrete implementation was skipped — static dispatch")
    }

    func testTheDefaultStillAppliesToProvidersWithoutOne() {
        XCTAssertNil((Silent() as any UsageProvider).account())
    }
}

/// Antigravity's mark is flattened from its own SVG, so what is asserted is
/// that it survived flattening: one closed loop, inside the unit box, filling
/// it. The Gemini spark it replaced was generated, and its geometry could be
/// checked exactly; this one comes from artwork and can only be checked for
/// sanity.
final class ProviderGlyphTests: XCTestCase {
    private var loop: [CGPoint] { GlyphOutline.antigravity[0] }

    func testItIsOneClosedLoopInTheUnitBox() {
        XCTAssertEqual(GlyphOutline.antigravity.count, 1)
        XCTAssertGreaterThan(loop.count, 50, "the curves were not flattened into enough points")
        for p in loop {
            XCTAssertTrue((0...1).contains(p.x), "x outside the unit box: \(p.x)")
            XCTAssertTrue((0...1).contains(p.y), "y outside the unit box: \(p.y)")
        }
    }

    /// Normalisation should fill the box on its longer axis, or the mark would
    /// render smaller than every other glyph for no reason.
    func testItFillsTheBox() {
        let xs = loop.map(\.x), ys = loop.map(\.y)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        XCTAssertEqual(span, 1, accuracy: 0.01)
    }

    func testEveryGlyphResolvesAnOutline() {
        for glyph in [ProviderGlyph.claude, .openai, .third, .cursor, .antigravity, .glm, .grok] {
            XCTAssertFalse(glyph.outline.isEmpty, "\(glyph) draws nothing")
        }
    }

    /// The raw value is what archived readings were written under.
    func testTheRawValueSurvivesTheRename() {
        XCTAssertEqual(ProviderGlyph.antigravity.rawValue, "gemini")
    }
}


/// The notch's own visibility. Its default matters more than the other two
/// settings here: get it wrong and a fresh install shows nothing at all, which
/// is indistinguishable from the app failing to start.
final class NotchVisibilityTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "NotchVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    func testItDefaultsToHoverRatherThanHidden() {
        XCTAssertEqual(Preferences(defaults: defaults()).notchVisibility, .onHover)
    }

    @MainActor
    func testTheChoiceSurvivesARestart() {
        let defaults = defaults()
        Preferences(defaults: defaults).notchVisibility = .alwaysShow
        XCTAssertEqual(Preferences(defaults: defaults).notchVisibility, .alwaysShow)
    }

    /// A value written by a future version, or corrupted, must not hide the
    /// notch — it falls back to the visible default.
    @MainActor
    func testAnUnknownStoredValueFallsBackToVisible() {
        let defaults = defaults()
        defaults.set("teleport", forKey: "notchVisibility")
        XCTAssertEqual(Preferences(defaults: defaults).notchVisibility, .onHover)
    }

    /// Hiding removes every other way back into the app, so the option itself
    /// has to say where the door is.
    func testHidingExplainsHowToGetBack() {
        XCTAssertTrue(NotchVisibility.hidden.explanation.contains("Applications"))
    }

    func testEveryModeIsOfferedAndNamed() {
        XCTAssertEqual(NotchVisibility.allCases.count, 3)
        for mode in NotchVisibility.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }
}

/// Renaming the app renames its defaults domain, so every setting moves to a
/// new empty one unless it is carried across.
final class RenameMigrationTests: XCTestCase {
    private func suite() -> (UserDefaults, String) {
        let name = "RenameMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// A source domain of our own, so the tests never read the real one — the
    /// first version of this did exactly that, and copied live settings into a
    /// scratch suite.
    private func oldDomain(_ contents: [String: Any]) -> String {
        let name = "RenameMigrationTests.old.\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain(contents, forName: name)
        return name
    }

    @MainActor
    func testItCarriesSettingsAcrossTheRename() {
        let (defaults, _) = suite()
        let old = oldDomain(["hiddenProviders": ["cursor"], "notchVisibility": "alwaysShow"])
        defer { UserDefaults.standard.removePersistentDomain(forName: old) }

        Preferences.migrateFromPreviousName(into: defaults, from: old)

        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.isConnected("cursor"))
        XCTAssertEqual(preferences.notchVisibility, .alwaysShow)
    }

    /// The guard that matters: a domain already in use is never overwritten, or
    /// a later launch would undo whatever the user changed after the rename.
    @MainActor
    func testItLeavesAnAlreadyUsedDomainAlone() {
        let (defaults, _) = suite()
        _ = Preferences(defaults: defaults)          // stamps hasLaunchedBefore
        defaults.set(["codex"], forKey: "hiddenProviders")
        let old = oldDomain(["hiddenProviders": ["cursor"]])
        defer { UserDefaults.standard.removePersistentDomain(forName: old) }

        Preferences.migrateFromPreviousName(into: defaults, from: old)

        XCTAssertEqual(defaults.stringArray(forKey: "hiddenProviders"), ["codex"])
    }

    @MainActor
    func testMigratingWithNothingToMigrateIsHarmless() {
        let (defaults, _) = suite()
        Preferences.migrateFromPreviousName(into: defaults, from: "does.not.exist")
        XCTAssertTrue(Preferences(defaults: defaults).isConnected("claude"))
    }
}

/// The card's height is budgeted, not measured, and the panel reaches inward by
/// the budget. A card taller than that is not scrolled or grown — it is
/// clipped, and the clipping takes the *title* off the top. Six sessions did
/// exactly that.
final class TooltipOverflowTests: XCTestCase {
    /// Whatever cap is in force, the card it produces has to fit the budget
    /// that same cap sized the panel from.
    func testACardNeverExceedsTheBudgetItsCapImplies() {
        for cap in 0...NotchLayout.sessionCeiling {
            let budget = NotchLayout.maxCardHeight(sessionCap: cap)
            for sessions in 0...40 {
                for windows in 0...NotchLayout.maxWindowCount {
                    let height = NotchLayout.cardHeight(windowCount: windows,
                                                        sessionCount: sessions,
                                                        sessionCap: cap)
                    XCTAssertLessThanOrEqual(
                        height, budget,
                        "cap \(cap): \(windows) windows and \(sessions) sessions overflow"
                    )
                }
            }
        }
    }

    /// Beyond the cap the height stops growing — that is what makes the bound
    /// hold however many sessions are running.
    func testHeightStopsGrowingPastTheCap() {
        let cap = NotchLayout.defaultSessionCap
        let atCap = NotchLayout.cardHeight(windowCount: 3, sessionCount: cap,
                                           sessionCap: cap)
        let overCap = NotchLayout.cardHeight(windowCount: 3, sessionCount: cap + 5,
                                             sessionCap: cap)
        let farOver = NotchLayout.cardHeight(windowCount: 3, sessionCount: 40,
                                             sessionCap: cap)
        XCTAssertEqual(overCap, farOver, "the height still grows with hidden sessions")
        XCTAssertGreaterThan(overCap, atCap, "no room was left for the 'and N more' line")
    }
}

/// Hiding sessions behind "and N more" is a cost, not a feature: the point of
/// the readout is that nothing needs opening. So the cap is solved for the
/// display rather than fixed — a laptop that cannot hold ten rows summarises,
/// a desk display that can does not.
final class SessionCapTests: XCTestCase {
    func testWhatFitsAlwaysFitsTheBudgetItWasSolvedFor() {
        for budget in stride(from: CGFloat(150), through: 1200, by: 37) {
            let n = NotchLayout.sessionsFitting(cardBudget: budget,
                                                windowCount: NotchLayout.maxWindowCount)
            guard n > 0 else { continue }
            XCTAssertLessThanOrEqual(
                NotchLayout.maxCardHeight(sessionCap: n), budget,
                "\(n) rows were admitted into \(budget)pt but do not fit"
            )
        }
    }

    /// The row after the last admitted one has to be one that genuinely does
    /// not fit, or the search stopped early and hid a session for nothing.
    func testNothingIsHiddenThatWouldHaveFitted() {
        for budget in stride(from: CGFloat(150), through: 1200, by: 37) {
            let n = NotchLayout.sessionsFitting(cardBudget: budget,
                                                windowCount: NotchLayout.maxWindowCount)
            guard n < NotchLayout.sessionCeiling else { continue }
            XCTAssertGreaterThan(
                NotchLayout.maxCardHeight(sessionCap: n + 1), budget,
                "\(n + 1) rows would have fitted in \(budget)pt and were hidden anyway"
            )
        }
    }

    func testMoreRoomNeverListsFewer() {
        var last = 0
        for budget in stride(from: CGFloat(100), through: 1400, by: 11) {
            let n = NotchLayout.sessionsFitting(cardBudget: budget,
                                                windowCount: NotchLayout.maxWindowCount)
            XCTAssertGreaterThanOrEqual(n, last, "a bigger screen listed fewer sessions")
            last = n
        }
    }

    /// Past a dozen the list has stopped being glanceable, and no amount of
    /// screen should turn the tooltip into a scrolling log.
    func testTheListStaysGlanceableOnAnyDisplay() {
        XCTAssertEqual(NotchLayout.sessionsFitting(cardBudget: 100_000,
                                                   windowCount: 0),
                       NotchLayout.sessionCeiling)
    }

    /// The reported case: six sessions, on the display it was reported from.
    /// Under the shipped cap of four, two of them were hidden on a screen with
    /// room to spare.
    @MainActor func testTheReportedCaseIsListedInFull() {
        let model = NotchViewModel()
        model.edge = .right
        model.screenSize = CGSize(width: 1800, height: 1169)
        XCTAssertGreaterThanOrEqual(model.sessionCap(cellCount: 4), 6)
    }

    /// Even the shortest display Macs ship with lists at least what the fixed
    /// cap used to, so solving for the screen never costs anyone a row.
    @MainActor func testTheSmallestLaptopIsNoWorseOffThanTheFixedCap() {
        let model = NotchViewModel()
        model.edge = .right
        model.screenSize = CGSize(width: 1470, height: 956)   // 13-inch Air
        XCTAssertGreaterThanOrEqual(model.sessionCap(cellCount: 4),
                                    NotchLayout.defaultSessionCap)
    }

    /// And the panel it implies still has to land on the screen.
    ///
    /// From 900pt up, which is the shortest display any Mac ships with. Below
    /// that the four limit windows alone are taller than the screen can hold,
    /// and no session cap — not even zero — can buy that back.
    @MainActor func testThePanelStillFitsTheScreenItWasSolvedFor() {
        for height in stride(from: CGFloat(900), through: 2000, by: 23) {
            let model = NotchViewModel()
            model.edge = .right
            model.screenSize = CGSize(width: 1512, height: height)
            model.screenUsableSize = CGSize(width: 1512, height: height - 37)
            XCTAssertLessThanOrEqual(
                model.panelSize(cellCount: 4).height, height,
                "the panel runs off a \(height)pt screen"
            )
        }
    }

    /// A top or bottom notch spends the card's height reaching inward instead,
    /// against the usable screen — it starts below the menu bar, so the menu
    /// bar is room it never had.
    @MainActor func testAHorizontalNotchStaysWithinTheUsableScreen() {
        for height in stride(from: CGFloat(900), through: 2000, by: 23) {
            for edge in [NotchEdge.top, .bottom] {
                let model = NotchViewModel()
                model.edge = edge
                model.screenSize = CGSize(width: 1512, height: height)
                model.screenUsableSize = CGSize(width: 1512, height: height - 37)
                XCTAssertLessThanOrEqual(
                    model.panelSize(cellCount: 4).height, height - 37,
                    "\(edge): the panel runs off a \(height)pt screen"
                )
            }
        }
    }

    /// Before the controller has said which screen it is on, the figure that
    /// shipped is what holds — never a panel sized for a display we have not
    /// been told about.
    @MainActor func testAnUnknownScreenKeepsTheShippedCap() {
        let model = NotchViewModel()
        XCTAssertEqual(model.sessionCap(cellCount: 4), NotchLayout.defaultSessionCap)
    }
}

/// A tooltip is centred on the cell it belongs to, so the first and last
/// providers throw half a card past the end of the stack. Both orientations
/// need room for it — a side edge was assumed exempt because the card sits
/// beside the stack, but it sits beside it *horizontally* while being centred
/// on it *vertically*, and the title was clipped off the top.
final class TooltipEndroomTests: XCTestCase {
    func testEveryEdgeLeavesRoomForHalfACard() {
        for edge in NotchEdge.allCases {
            let needed = (edge.isVertical ? NotchLayout.defaultMaxCardHeight
                                          : NotchLayout.cardWidth) / 2
            XCTAssertGreaterThanOrEqual(
                NotchLayout.slack(for: edge), needed,
                "\(edge): the first provider's tooltip is clipped by the panel"
            )
        }
    }

    /// The dimension that crosses the ends differs by orientation — height
    /// along a side edge, width along a horizontal one. Using the wrong one is
    /// what made this look sufficient.
    func testTheRelevantDimensionDiffersByOrientation() {
        XCTAssertGreaterThanOrEqual(NotchLayout.slack(for: .right),
                                    NotchLayout.defaultMaxCardHeight / 2)
        XCTAssertGreaterThanOrEqual(NotchLayout.slack(for: .top),
                                    NotchLayout.cardWidth / 2)
    }
}

/// A card with no readings shows a status message instead, and the budget used
/// to reserve one line for it whatever it said. The longest of them takes
/// three, so the card came up short and clipped the part that says what to do —
/// on the one ring a user is looking at because something is wrong.
final class StatusMessageHeightTests: XCTestCase {
    /// Every message the app can actually produce, against the budget the card
    /// is built to.
    private var everyStatusCard: [(name: String, snapshot: ProviderSnapshot)] {
        let states: [(String, ProviderStatus)] = [
            ("needsAuth", .needsAuth),
            ("accessDenied", .accessDenied),
            ("unsupported", .unsupported("The free plan has nothing for Cursor to meter yet")),
            ("error", .error("HTTP 500")),
            ("stale", .stale(since: .distantPast)),
            ("ok", .ok)
        ]
        return [("claude", "Claude"), ("claude-work", "Claude (work)"), ("cursor", "Cursor"),
                ("codex", "Codex"), ("gemini", "Antigravity")].flatMap { id, name in
            states.map { state in
                ("\(id)/\(state.0)",
                 ProviderSnapshot(id: id, displayName: name, glyph: .claude,
                                  fidelity: .official, status: state.1, windows: []))
            }
        }
    }

    func testTheBudgetHoldsEveryMessageTheAppCanShow() {
        for (name, snapshot) in everyStatusCard {
            guard let message = snapshot.statusMessage else { continue }
            let budgeted = NotchLayout.cardHeight(windowCount: 0,
                                                  statusMessage: message)
            let bare = NotchLayout.cardHeight(windowCount: 0, statusMessage: "")
            let needed = NotchLayout.bodyTextHeight(message)
            XCTAssertGreaterThanOrEqual(
                budgeted, bare - NotchLayout.cardBodyLineHeight + needed,
                "\(name): \"\(message)\" is clipped"
            )
        }
    }

    /// The message that found this: three lines where one was reserved.
    func testARefusalMessageIsGivenItsRealHeight() {
        let refused = ProviderSnapshot(id: "gemini", displayName: "Antigravity",
                                       glyph: .antigravity, fidelity: .official,
                                       status: .accessDenied, windows: [])
        let message = try! XCTUnwrap(refused.statusMessage)
        XCTAssertGreaterThan(NotchLayout.bodyTextHeight(message),
                             2 * NotchLayout.cardBodyLineHeight,
                             "the message that motivated this now fits on one line")
        XCTAssertGreaterThan(
            NotchLayout.cardHeight(windowCount: 0, statusMessage: message),
            NotchLayout.cardHeight(windowCount: 0, statusMessage: "Signed out"),
            "a message that wraps is given no more room than one that does not"
        )
    }

    /// Whole lines, so the last one never straddles the clip.
    func testHeightIsAWholeNumberOfLines() {
        for text in ["", "short", String(repeating: "a long message ", count: 12)] {
            let height = NotchLayout.bodyTextHeight(text)
            let lines = height / NotchLayout.cardBodyLineHeight
            XCTAssertEqual(lines, lines.rounded(), accuracy: 0.0001, "\(text.prefix(20))")
        }
    }

    /// A status card still has to fit the panel that was sized without knowing
    /// what it would say.
    func testAStatusCardStillFitsTheBudgetedPanel() {
        for (name, snapshot) in everyStatusCard {
            let height = NotchLayout.cardHeight(
                windowCount: 0,
                sessionCount: NotchLayout.sessionCeiling,
                sessionCap: NotchLayout.sessionCeiling,
                statusMessage: snapshot.statusMessage
            )
            XCTAssertLessThanOrEqual(
                height, NotchLayout.maxCardHeight(sessionCap: NotchLayout.sessionCeiling),
                "\(name): a status card overflows the panel"
            )
        }
    }
}
