import AppKit

/// Every measurement is quoted in design-frame pixels so it can be checked
/// against `docs/design/frame-124-hover-tooltip.png` directly.
enum NotchLayout {
    // The notch body
    /// The depth the design frame fixes: a 44pt ring with an even margin
    /// either side of it.
    static let sideBodyDepth = Design.px(186)

    /// How deep the notch is, which is **not** the same on every edge.
    ///
    /// Turning the stack is more than a rotation. The percent label sits below
    /// its ring, so on a side edge it spends the stack's *length* — the ring
    /// leads the cell and the label follows it down. Turn the stack horizontal
    /// and the label has nowhere to go but into the notch's *depth*, and 70pt
    /// no longer fits a ring, a gap and a line of type. So a horizontal notch
    /// is deeper, and it keeps the frame's margin around the ring to stay
    /// recognisably the same object.
    static func bodyDepth(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? sideBodyDepth : 2 * sideRingMargin + cellExtent
    }

    /// Clear space between the ring and the bezel, from the design frame.
    private static var sideRingMargin: CGFloat { (sideBodyDepth - ringDiameter) / 2 }

    /// The same margin on every edge — on a horizontal one it is the gap above
    /// the ring rather than beside it, but it is the same distance.
    static func ringMargin(for edge: NotchEdge) -> CGFloat { sideRingMargin }

    static let curlRadius   = Design.px(103)
    /// The small inverse corner where a flush bar meets the screen's frame.
    ///
    /// The hardware notch is moulded into the bezel rather than cut out of it,
    /// and a bar that meets the frame with a raw square edge does not read that
    /// way. Deliberately a fraction of `curlRadius`: enough to round the join,
    /// nowhere near enough to taper the bar the way a full flare would.
    static let bezelFillet  = Design.px(28)
    static let cornerRadius = Design.px(78.8)
    static let padTop       = Design.px(69.5)   // body top -> first ring
    static let padBottom    = Design.px(50.1)   // last label -> body bottom
    static let cellSpacing  = Design.px(83.5)   // label bottom -> next ring top

    // The resting pill. Not in the design frame — it is the notch folded away,
    // sized to read as a deliberate handle rather than a sliver of chrome.
    static let pillWidth  = Design.px(26)

    static let pillHeight = Design.px(210)
    /// The pill is small, so the region that wakes it is deliberately larger.
    static let pillHotZone = Design.px(90)

    // A provider cell
    static let ringDiameter  = Design.px(117)   // 44pt, the design spec's anchor

    /// Clearance between a ring and the hardware, when the rings sit in the
    /// strips either side of the hole. Small on purpose: the strip is the menu
    /// bar's height and every point of it is contested.
    static let splitRingMargin: CGFloat = 4

    /// The smallest the reading under a ring may be drawn before it stops
    /// being worth drawing, in points.
    ///
    /// Beside the hardware the strip is the cutout's depth, which one ring
    /// already fills — a percentage there would be a few points tall and set
    /// into the bezel. It is carried only once the size setting has deepened
    /// the bar enough for it to be read, and is a hover away in the card
    /// otherwise.
    static let splitReadingFloor: CGFloat = 10

    /// The corner the bar turns where it meets the bezel, beside the hardware.
    /// Derived from the hardware's own height rather than fixed — see
    /// `splitCornerFraction`.
    static let splitCornerRadius: CGFloat = 12

    /// Clear space between the hardware notch and the nearest ring.
    ///
    /// The cutout's own corners are rounded, so a ring pressed flush against
    /// its edge sits under the curve however exactly the gap matches the
    /// reported width — the reported width is the widest part. This is the
    /// margin either side that keeps a ring out from under it.
    static let splitHoleClearance: CGFloat = 12

    /// The bottom corner of an ear beside the hardware notch.
    ///
    /// The corner the ear turns at its foot, as a fraction of the notch's
    /// height, so it turns at the cutout's rate at every size.
    ///
    /// The cutout's own corner measures 0.35 — a circular arc of radius
    /// 31.2px on a 90px-deep notch, fitted over the whole sweep. (Read the
    /// radius off the bottom row instead and you get 26.6, which is 15% out:
    /// down there the boundary is horizontal, so a fraction of a row of error
    /// throws the reading by several pixels. That is the mistake behind two of
    /// the wrong numbers this constant has held.)
    ///
    /// Smaller than that here, because an ear is not the cutout. The cutout
    /// turns once, at its foot, and that corner is all of its character. An
    /// ear already turns through most of its depth sweeping out to the
    /// screen's edge — see `splitFilletFraction` — so a corner sized to carry
    /// a silhouette on its own makes the end read as blunt. This one only has
    /// to finish the sweep.
    static let splitCornerFraction: CGFloat = 0.35

    /// The curve where each ear meets the side of the screen, as a fraction of
    /// the notch's height.
    ///
    /// The join into the bezel. The ear carries on past the cutout, so unlike
    /// the cutout it has to meet the screen's own edge somewhere, and it does
    /// it with a curve rather than a step.
    ///
    /// A circular arc, like the corner at the foot — see
    /// `SideNotchShape.circleReach` for why nothing cleverer belongs here.
    ///
    /// Nearly two thirds of the notch's depth, which is a lot for a join. It
    /// has to be: this curve's sharpness is 1/radius, and at 0.28 it read as a
    /// flick rather than a sweep — the bar barely left the straight before it
    /// had met the bezel. It also loses its first couple of points behind the
    /// bezel, where an arc moves fastest, so a small one arrives on screen
    /// already half spent.
    ///
    /// Wider still now that the corner at the foot is smaller: between them
    /// they take all but a couple of points of the depth either way, and the
    /// depth freed by the smaller corner goes here.
    ///
    /// At this size it very nearly meets the corner at the foot: the two
    /// curves take all but a couple of points of the depth between them, so
    /// the ear's end reads as one continuous sweep from the screen's edge
    /// round to its underside rather than as two corners with a side between.
    /// The remaining sliver of straight is deliberate — `SideNotchShape`
    /// claims the corner first and gives this whatever depth is left, so
    /// letting them meet exactly would make the join, not the corner, the
    /// thing that shrinks when the corner grows.
    /// How deep the sweep into the screen's border reaches, as a fraction of
    /// the notch's height.
    static let splitFilletFraction: CGFloat = 0.42

    /// How much further that sweep runs *along* the bar than it reaches down
    /// into it — which is to say how flat it is.
    ///
    /// At 1 it is a quarter circle. The depth is all but spoken for at 0.78,
    /// so there is no room left to gentle the curve by growing it; stretching
    /// it lengthways instead is what is left, and length is the one thing an
    /// ear has plenty of. At 1.6 the sweep leaves the bezel at a little over
    /// 30 degrees from the horizontal where a circle leaves it at 45.
    static let splitFilletWidth: CGFloat = 1.2



    /// How much of the sweep is spent ramping its bend in and out — see
    /// `SideNotchShape.fluidTurn`.
    ///
    /// The whole of it. The join into the border is where every "stiff" report
    /// has landed, and every time the cause was the bend arriving all at once
    /// rather than the outline being the wrong shape. At 0.5 the sweep leaves
    /// the border with no bend at all and gathers it as it goes.
    static let splitFilletRamp: CGFloat = 0.5

    /// Gap between rings in a strip, as a fraction of the ring.
    static let splitSpacingRatio: CGFloat = 0.4
    static let trackStroke   = Design.px(15.5)
    static let progressStroke = Design.px(8)
    /// A fraction of the circle, not a pixel length. Below it the arc's two
    /// round caps (each `progressStroke / 2`) overlap and the context reading
    /// collapses into a dot that looks like a status light. At 0.06 the arc
    /// path (radius `(ringDiameter - progressStroke) / 2`) draws roughly 20px
    /// of body plus caps — clearly an arc. It only floors a known reading;
    /// `nil` still draws the full ring.
    static let localArcMinimumSweep: CGFloat = 0.06
    static let glyphSize     = Design.px(46)
    static let ringLabelGap  = Design.px(26.9)

    // The activity indicator. Not in the design frame — sized to sit in the gap
    // between the glyph (46px across) and the inside edge of the track (86px),
    // so it never crowds either.
    static let activityDiameter = Design.px(72)
    static let activityStroke   = Design.px(5.5)

    // The weekly ring. Not in the design frame — the frame draws one ring per
    // provider — so these are placed against what is already there rather than
    // quoted from it, and the tests state the clearances rather than the
    // numbers.
    //
    // Thinner than the headline arc on purpose: same kind of fact, lesser
    // claim on the eye. Two arcs of equal weight in a 44pt circle read as one
    // confused reading rather than as two limits.
    static let weeklyRingStroke = Design.px(5)
    /// Inside: centred in the gap between the glyph and the working
    /// indicator's own arc, which is the only clear band left in there.
    static let weeklyInsideRadius = Design.px(28)
    /// Outside: past the track, into the margin the notch keeps between a ring
    /// and its bezel. Far enough out not to crowd the track, far enough in that
    /// the bezel is never touched — `NotchLayoutTests` pins both.
    static let weeklyOutsideRadius = Design.px(65)

    // The settings orb: it lives *below* the notch, not inside it. At rest only
    // an arc of its edge is drawn, tucked into the corner the bottom flare
    // makes; on hover the same circle fills in and takes a gear. One circle,
    // two states — which is why the arc has to be a segment of it rather than a
    // decorative stroke that happens to sit nearby.
    // Measured off the reference frames, which are 2px per point — the notch
    // body is the familiar 70pt in both, and that fixes the scale.
    //
    // The important find: the resting arc is **concentric with the notch's own
    // bottom flare**, one radius inside it. That is what makes it follow the
    // contour of the edge instead of merely sitting near it, and it is why the
    // orb is centred on the flare's centre rather than on the body's axis.
    //
    //   flare : centre (edge - curlRadius, shapeBottom)   radius 38.5pt
    //   arc   : same centre                                radius 28.5pt
    //   disc  : same centre                                diameter 46.5pt
    static let orbDiameter = Design.px(124)
    static let orbStroke   = Design.px(18)
    /// Distance from the flare's curve in to the resting arc.
    static let orbGap      = Design.px(27)
    /// Radius of the resting arc: the flare's radius, less the gap.
    static var orbArcRadius: CGFloat { curlRadius - orbGap }
    /// The resting arc's circle when it traces a *convex* corner: outside the
    /// corner by the same gap it keeps inside a flare. Takes the corner the
    /// shape actually draws, which is not always `cornerRadius` — a bar drawn
    /// as the hardware notch caps it at the hardware's own rounding.
    ///
    /// `scale` shrinks the orb itself — the gap and the disc — without touching
    /// the corner it hugs, which is the hardware's and not ours to resize.
    static func orbConvexArcRadius(corner: CGFloat, scale: CGFloat = 1) -> CGFloat {
        corner + orbGap * scale
    }

    /// How far off a convex corner the orb hangs, on each axis.
    ///
    /// A flush bar has no flare, so no pocket for the orb to nestle into: its
    /// far corner is convex, and an orb centred on that corner sits *inside*
    /// the black. It hangs off it instead — clear of the corner by the same
    /// `orbGap` the flared version uses, plus its own radius so the disc never
    /// overlaps the bar. Taken diagonally, so it reads as belonging to the
    /// corner rather than to one edge or the other.
    static func orbCornerOffset(corner: CGFloat, scale: CGFloat = 1) -> CGFloat {
        (corner + (orbGap + orbDiameter / 2) * scale) / 2.0.squareRoot()
    }
    static let orbGlyph    = Design.px(56)
    /// What the arc scales to as it hides.
    ///
    /// The arc is concentric with the bottom flare, `orbGap` inside it, so
    /// growing its radius carries it outward along the normal and *into* the
    /// notch's black. Landing exactly on the flare is not enough — sitting on
    /// the boundary it is still half visible. It goes a full stroke past, so
    /// the line is genuinely buried and stops being drawable rather than
    /// merely becoming faint.
    ///
    /// Shrinking it instead pulled it toward its own centre, away from the
    /// notch, which is what read as flying off.
    static var orbMergeScale: CGFloat { (curlRadius + orbStroke) / orbArcRadius }
    /// Generous, like the pill's — it is a small target on a screen edge.
    static let orbHotZone  = Design.px(152)

    // The hover tooltip
    static let cardWidth     = Design.px(600)
    static let cardCorner    = Design.px(49.5)
    static let cardPadding   = Design.px(32)
    static let tailLength    = Design.px(75)
    static let tailHeight    = Design.px(87)
    static let tailGap       = Design.px(28)    // tail tip -> notch body edge
    static let barHeight     = Design.px(10.5)
    static let headerGap     = Design.px(17)    // glyph -> title
    static let headerToBlock = Design.px(21)
    static let labelToBar    = Design.px(16.8)
    static let barToUsed     = Design.px(17.8)
    static let blockSpacing  = Design.px(20)
    static let moneyBarHeight = Design.px(12)
    static let moneyBarToStats = Design.px(14)
    static let moneyStatGap = Design.px(4)
    static let usageDetailIdentityGap = Design.px(4)
    static let usageDetailBarHeight = Design.px(10.5)
    static let usageDetailLabelToBar = Design.px(12)
    static let usageDetailBarToStats = Design.px(10)
    static let usageDetailChartHeight = Design.px(96)
    static let usageDetailChartGap = Design.px(18)
    static let usageDetailBarGap = Design.px(5)
    static let sessionRowGap = Design.px(10)   // the two lines of one session
    /// The spinner beside a session's status. Sized against the body text's cap
    /// (18px) rather than picked by eye, so it reads as part of the word rather
    /// than a bullet pinned near it.
    static let statusDot       = Design.px(17)
    static let statusDotStroke = Design.px(3.4)
    static let statusDotGap    = Design.px(11)
    static let hairline      = Design.px(2.5)  // rule above the session list

    // Codex account activity
    static let codexUsageTop   = Design.px(20)
    static let codexMetricTop  = Design.px(14)
    static let codexMetricRowGap = Design.px(8)
    static let codexMetricRowHeight = Design.px(40)
    static let codexMetricHeight = 5 * codexMetricRowHeight + 4 * codexMetricRowGap
    static let codexMetricBottom = Design.px(14)
    static let codexUsageRowGap = Design.px(12)
    static let codexChartTop   = Design.px(15)
    static let codexChartHeight = Design.px(115)
    /// Title, count, and expiry. The third line is reserved so a missing
    /// expiry cannot shrink the hover region under the card.
    static var codexResetCreditsHeight: CGFloat {
        blockSpacing + 3 * cardBodyLineHeight + 2 * codexUsageRowGap
    }

    /// The percent label's line box. Fixed rather than intrinsic so the panel
    /// geometry can be worked out in AppKit before SwiftUI lays anything out.
    static let percentLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 27), weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    static let cardTitleLineHeight: CGFloat = lineHeight(
        NSFont.systemFont(ofSize: Design.fontSize(capPixels: 26), weight: .semibold)
    )
    /// The card's body face. Held rather than rebuilt at each use: the line
    /// height below and the wrap measurement in `bodyTextHeight` have to be
    /// measuring the same font, or the budget and the text disagree.
    static let cardBodyFont = NSFont.systemFont(
        ofSize: Design.fontSize(capPixels: 18), weight: .regular
    )
    static let cardBodyLineHeight: CGFloat = lineHeight(cardBodyFont)

    /// How wide a line of body text is inside the card.
    static var cardTextWidth: CGFloat { cardWidth - 2 * cardPadding }

    /// How tall a run of body text is once it has wrapped to that column.
    ///
    /// Measured, because a status message is the one piece of card text whose
    /// length is not known here. The budget assumed a single line, and the
    /// longest of them — "Codenotch was refused access to …'s saved login.
    /// Click this ring to ask again, and choose Always Allow." — takes three:
    /// 33pt against 12pt reserved. The card came up 21pt short and clipped the
    /// two lines that said what to do about it, on the one ring a user looks at
    /// precisely because something is wrong.
    ///
    /// Rounded up to whole lines: the card's height is a stack of line boxes,
    /// and half a line of budget leaves the last one straddling the clip.
    ///
    /// `width` is the column the text actually wraps to. The notch's card is
    /// the default and the only one the panel geometry is solved against; the
    /// Detail panel passes its own, so a name that fits one line there is not
    /// given two lines of room.
    static func bodyTextHeight(_ text: String, width: CGFloat = cardTextWidth) -> CGFloat {
        guard !text.isEmpty else { return cardBodyLineHeight }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: cardBodyFont]
        )
        let lines = max(1, Int((bounds.height / cardBodyLineHeight).rounded(.up)))
        return CGFloat(lines) * cardBodyLineHeight
    }

    /// Whether a label and the value opposite it both fit on one row of
    /// `width`, with the gap `SplitRow` keeps between them and a little room
    /// to spare.
    ///
    /// Measured in the card's own body face, because this decides whether a
    /// row may carry a longer string at all — a row that cannot is given the
    /// short one rather than left to truncate.
    ///
    /// The slack is not padding for its own sake. `NSString`'s metrics come in
    /// a point or two under what SwiftUI's `Text` asks for the same string in
    /// the same face, so a row measured to fit exactly was still truncated on
    /// screen — and a row that fits to the last point reads as crowded even
    /// when it does not truncate. Both are answered by refusing the last few
    /// points.
    static func splitRowFits(leading: String, trailing: String, width: CGFloat) -> Bool {
        let attributes: [NSAttributedString.Key: Any] = [.font: cardBodyFont]
        let leadingWidth = (leading as NSString).size(withAttributes: attributes).width
        let trailingWidth = (trailing as NSString).size(withAttributes: attributes).width
        return leadingWidth + splitRowGap + trailingWidth + splitRowSlack <= width
    }

    /// The least `SplitRow` leaves between a label and its value.
    static let splitRowGap = Design.px(20)
    /// What `splitRowFits` keeps back — see its note.
    static let splitRowSlack = Design.px(24)

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Ring plus its percent label.
    static var cellExtent: CGFloat { ringDiameter + ringLabelGap + percentLineHeight }

    /// What one cell claims along the stack.
    ///
    /// Down a side edge, the ring *and the label underneath it*: both are on
    /// this axis. Across a horizontal one the label has moved into the depth,
    /// so the cell is the ring alone. Giving the horizontal case the vertical
    /// figure leaves 27pt of nothing between every pair of rings, on top of the
    /// spacing the frame already puts there — which is what made the top and
    /// bottom bars read as far too spread out.
    static func cellAlong(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? cellExtent : ringDiameter
    }

    /// Ring centre to ring centre.
    static func cellPitch(for edge: NotchEdge) -> CGFloat {
        cellAlong(for: edge) + cellSpacing
    }

    /// Padding at the start and the end of the stack.
    ///
    /// Down a side edge these are the frame's own two numbers, and they should
    /// stay different: `padTop` measures the body's top to the first *ring*,
    /// `padBottom` measures the last *label* to the body's foot. They pad
    /// different things, so they are not the same size.
    ///
    /// Across a horizontal edge the label has moved off this axis and both ends
    /// are padding the same thing — a cell. Carrying the difference over there
    /// only pushes the stack off centre: with four rings it reads as a slightly
    /// heavy left end, and with one it is a ring visibly not in the middle of
    /// its own notch. So the two become one number, their mean, which leaves
    /// the bar exactly as long as it would have been.
    static func padStart(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padTop : (padTop + padBottom) / 2
    }

    static func padEnd(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padBottom : (padTop + padBottom) / 2
    }

    /// Distance from the start of the whole shape to cell `index`'s ring centre.
    ///
    /// The ring leads its cell on every edge — down a side one the label
    /// follows it along the stack, across a horizontal one there is nothing
    /// else on the stack at all.
    static func ringCenter(index: Int, edge: NotchEdge = .right,
                           flare: CGFloat = curlRadius,
                           spacing: CGFloat = cellSpacing,
                           cellScale: CGFloat = 1) -> CGFloat {
        let along = cellAlong(for: edge) * cellScale
        return flare + padStart(for: edge) + (ringDiameter * cellScale) / 2
            + CGFloat(index) * (along + spacing)
    }

    /// Height of the notch body for a given number of provider cells.
    static func bodyLength(cellCount: Int, edge: NotchEdge = .right,
                           spacing: CGFloat = cellSpacing,
                           cellScale: CGFloat = 1) -> CGFloat {
        let start = padStart(for: edge), end = padEnd(for: edge)
        guard cellCount > 0 else { return start + end }
        return start
            + CGFloat(cellCount) * cellAlong(for: edge) * cellScale
            + CGFloat(cellCount - 1) * spacing
            + end
    }

    /// Centre of the settings orb: the same point the notch's bottom flare
    /// curves around, which is what makes the arc parallel that curve.
    static func orbCenterAlong(cellCount: Int, edge: NotchEdge = .right) -> CGFloat {
        shapeLength(cellCount: cellCount, edge: edge)
    }

    /// Distance in from the screen edge, matching the flare's centre.
    static var orbInsetFromEdge: CGFloat { curlRadius }

    /// Full shape length, flares included.
    ///
    /// `flare` is what the ends actually take, not what they might: a flush bar
    /// has only the small corner into the frame, and reserving a whole
    /// `curlRadius` there leaves some 56pt of dead black either side of the
    /// readings — which is exactly what made the top bar look too wide.
    static func shapeLength(cellCount: Int, edge: NotchEdge = .right,
                            flare: CGFloat = curlRadius,
                            spacing: CGFloat = cellSpacing) -> CGFloat {
        bodyLength(cellCount: cellCount, edge: edge, spacing: spacing) + 2 * flare
    }

    /// The tooltip's height for a given number of limit windows and live
    /// sessions. Worked out here rather than left to SwiftUI so the hover region
    /// can be computed before the card is ever laid out.
    static func usageDetailHeight(_ groupCount: Int, showsPricing: Bool = true) -> CGFloat {
        guard groupCount > 0 else { return 0 }
        let summary = hairline + blockSpacing + cardBodyLineHeight
            + blockSpacing + 2 * cardBodyLineHeight + moneyStatGap
        let chart = cardBodyLineHeight + usageDetailLabelToBar + usageDetailChartHeight
        let usageDivider = blockSpacing + hairline
        let pricing = showsPricing
            ? blockSpacing + 2 * cardBodyLineHeight + usageDetailIdentityGap
            : 0
        let chartDivider = blockSpacing + hairline
        return blockSpacing + summary + (showsPricing ? usageDivider : 0) + pricing + chartDivider
            + blockSpacing + 2 * chart + usageDetailChartGap
    }

    static func cardHeight(windowCount: Int, groupCount: Int = 0,
                           moneyWindowCount: Int = 0, usageDetailGroupCount: Int = 0,
                           sessionCount: Int = 0,
                           sessionCap: Int = defaultSessionCap,
                           statusMessage: String? = nil,
                           blockMessage: String? = nil,
                           hasTokenUsage: Bool = false,
                           hasPlan: Bool = false,
                           hasResetCredits: Bool = false,
                           localModelName: String? = nil, showsLocalPerformance: Bool = false,
                           localLedgerRows: Int = 0,
                           compactRowCount: Int = 0,
                           showsDeepSeekPricing: Bool = true) -> CGFloat {
        let header = max(glyphSize, cardTitleLineHeight)
            + (hasPlan ? cardBodyLineHeight : 0)
        var height = 2 * cardPadding + header

        // The blocked line sits under the header, above everything else — it
        // is the reading that stops you working, so it leads.
        if let blockMessage {
            height += headerToBlock + bodyTextHeight(blockMessage)
        }

        if let localModelName {
            // Match RuntimeModelDetails so the panel and hover region fit all
            // rows: the runtime's own, the speed pair, and a logged runtime's
            // ledger lines.
            let rows: CGFloat = (showsLocalPerformance ? 7 : 4) + CGFloat(max(0, localLedgerRows))
            height += headerToBlock + modelNameHeight(localModelName)
                + blockSpacing + rows * cardBodyLineHeight + (rows - 1) * sessionRowGap
        } else if windowCount > 0 {
            let moneyCount = min(max(0, moneyWindowCount), windowCount)
            let fullCount = windowCount - compactRowCount - moneyCount
            // A full window row: label + bar + summary.
            let fullBlock = 2 * cardBodyLineHeight + labelToBar + barHeight + barToUsed
            let moneyBlock = cardBodyLineHeight + labelToBar + moneyBarHeight
                + moneyBarToStats + 2 * cardBodyLineHeight + moneyStatGap
            // A compact (count-only) row: a single SplitRow line.
            let compactBlock = cardBodyLineHeight
            height += headerToBlock
                + CGFloat(fullCount) * fullBlock
                + CGFloat(moneyCount) * moneyBlock
                + CGFloat(compactRowCount) * compactBlock
                + CGFloat(windowCount - 1) * blockSpacing
            if groupCount > 0 {
                // Each group adds a title line, spacing (12), and 16px vertical padding inside the box
                let groupExtra = cardBodyLineHeight + Design.px(12) + 2 * Design.px(16)
                height += CGFloat(groupCount) * groupExtra

                if groupCount > 1 {
                    // We use 28px between groups instead of the default 20px (blockSpacing)
                    height += CGFloat(groupCount - 1) * (Design.px(28) - blockSpacing)
                }

                // Extra padding at the very bottom
                height += Design.px(8)
            }
        } else {
            // The status message, at whatever height it actually wraps to.
            height += headerToBlock + bodyTextHeight(statusMessage ?? "")
        }

        if hasResetCredits {
            height += codexUsageTop + hairline + codexResetCreditsHeight
        }

        height += usageDetailHeight(usageDetailGroupCount,
                                    showsPricing: showsDeepSeekPricing)

        if hasTokenUsage {
            height += codexUsageTop + hairline + blockSpacing
                + codexMetricTop + codexMetricHeight + codexMetricBottom
                + hairline
                + 2 * cardBodyLineHeight
                + codexUsageRowGap
                + codexChartTop + codexChartHeight
        }

        if sessionCount > 0 {
            let shown = min(sessionCount, max(0, sessionCap))
            let row = 2 * cardBodyLineHeight + sessionRowGap
            height += blockSpacing + hairline + blockSpacing
                + CGFloat(shown) * row
                + CGFloat(max(0, shown - 1)) * blockSpacing
            // The "and N more" line, which only exists when something is hidden.
            if sessionCount > shown {
                height += blockSpacing + cardBodyLineHeight
            }
        }
        return height
    }

    static func modelNameHeight(_ name: String, width: CGFloat = cardTextWidth) -> CGFloat {
        min(2 * cardBodyLineHeight, bodyTextHeight(name, width: width))
    }


    /// Room at each end of the stack: enough for the settings orb to hang past
    /// the foot of the shape, and enough for a tooltip anchored to the first or
    /// last cell to still have somewhere to sit.
    ///
    /// Both orientations need half a card past each end, and for the same
    /// reason: the card is centred on the cell it belongs to, so hovering the
    /// first or last provider throws half the card past the stack.
    ///
    /// A side edge was assumed exempt — the card sits *beside* the stack, so
    /// it looked like it needed no room at the ends. It sits beside it
    /// horizontally and is centred on it *vertically*, so half its height still
    /// has to fit. With the tallest card at ~474pt against 71pt of slack, the
    /// first provider's tooltip lost its title off the top of the panel.
    ///
    /// Which dimension crosses the ends is what differs: the card's height
    /// along a vertical edge, its width along a horizontal one.
    /// `notchScale` applies to the notch's own margin and to nothing else. The
    /// card half that this takes the maximum of is the card's real size on
    /// screen, and the card is drawn at one size whatever the notch is set to —
    /// scaling both halves would reserve room for a card that is never that
    /// big, and at the small end would reserve less than the card needs.
    static func slack(for edge: NotchEdge,
                      maxCardHeight: CGFloat = defaultMaxCardHeight,
                      notchScale: CGFloat = 1) -> CGFloat {
        edge.isVertical
            ? max(endSlack * notchScale, maxCardHeight / 2 + cardCorner)
            : max(endSlack * notchScale, cardWidth / 2 + cardCorner)
    }

    private static let endSlack = Design.px(190)

    /// The busiest provider that occurs — Claude, with four limit windows.
    /// The tallest card is sized for it, since the panel is sized once for the
    /// whole stack and has to hold whichever card is worst.
    static let maxWindowCount = 4

    /// How many sessions a tooltip lists before summarising the rest.
    ///
    /// Not a fixed number, because the honest answer depends on the display.
    /// The card's height is budgeted rather than measured, and the budget is
    /// what decides how far the panel reaches — so a card taller than the panel
    /// is not scrolled or grown, it is *clipped*, at the top, where the title
    /// is. But a cap low enough to be safe on a laptop hides sessions on a
    /// desk display that had room for all of them, and a hidden session is the
    /// one thing a glanceable readout must not do.
    ///
    /// So the cap is solved for the screen: as many rows as fit, and the
    /// summary line only when the display genuinely cannot hold the rest.
    ///
    /// Solved by walking up rather than by inverting `cardHeight` — the height
    /// is a sum of a dozen named parts, and an inverted copy of it would have
    /// to be kept in step by hand. The range is short enough that the search
    /// costs nothing.
    static func sessionsFitting(cardBudget: CGFloat, windowCount: Int,
                                groupCount: Int = 2,
                                hasTokenUsage: Bool = false,
                                hasPlan: Bool = false,
                                hasResetCredits: Bool = false) -> Int {
        var fits = 0
        for n in 1...sessionCeiling {
            // Costed as though something were still hidden, so that admitting
            // the nth row can never be what pushes the summary line off the
            // bottom of the card.
            let height = cardHeight(windowCount: windowCount, groupCount: groupCount,
                                    sessionCount: n + 1, sessionCap: n,
                                    hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                                    hasResetCredits: hasResetCredits)
            guard height <= cardBudget else { break }
            fits = n
        }
        return fits
    }

    /// Past this many rows the list has stopped being glanceable, and counting
    /// the rest is the kinder answer however much room the screen has.
    static let sessionCeiling = 12

    /// What to assume before the panel knows which screen it is on. The figure
    /// that shipped, so nothing about the default placement moves.
    static let defaultSessionCap = 4

    /// The tallest card the panel must be able to show without clipping it.
    ///
    /// Being generous costs nothing, since the panel is transparent and passes
    /// clicks through everywhere the chrome is not — but it cannot be so
    /// generous that the panel runs off the screen, which is what the cap is
    /// solved for.
    static func maxCardHeight(sessionCap: Int, hasTokenUsage: Bool = false,
                              hasPlan: Bool = false,
                              hasResetCredits: Bool = false) -> CGFloat {
        cardHeight(windowCount: maxWindowCount, groupCount: 2,
                   sessionCount: sessionCap + 1, sessionCap: sessionCap,
                   hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                   hasResetCredits: hasResetCredits)
    }

    static let defaultMaxCardHeight = maxCardHeight(sessionCap: defaultSessionCap)

    /// How far the panel reaches inward from the bezel, past the notch itself,
    /// so the tooltip has somewhere to live. Beside the stack on a side edge,
    /// below or above it on a horizontal one.
    static func tooltipDepth(for edge: NotchEdge,
                             maxCardHeight: CGFloat = defaultMaxCardHeight) -> CGFloat {
        (edge.isVertical ? cardWidth : maxCardHeight) + tailLength + tailGap
    }
}
