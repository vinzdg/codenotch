import AppKit
import SwiftUI

/// **The screen's border as one line**, for an ⌥-dragged notch travelling
/// round it.
///
/// Measured clockwise from the top-left corner, in points: along the top
/// edge, down the right, back along the bottom and up the left. A notch's
/// place on it is where its middle is, so going round a corner is simply that
/// number running on past the corner's.
struct BorderTrack: Equatable {
    /// The screen, in its own top-left-origin points.
    var width: CGFloat
    var height: CGFloat

    var perimeter: CGFloat { 2 * (width + height) }

    /// Where along the border each corner is, and the edges either side of it
    /// in the order the border runs.
    enum Corner: CaseIterable {
        case topRight, bottomRight, bottomLeft, topLeft
    }

    func position(of corner: Corner) -> CGFloat {
        switch corner {
        case .topRight:    return width
        case .bottomRight: return width + height
        case .bottomLeft:  return 2 * width + height
        case .topLeft:     return 0
        }
    }

    static func edges(of corner: Corner) -> (before: NotchEdge, after: NotchEdge) {
        switch corner {
        case .topRight:    return (.top, .right)
        case .bottomRight: return (.right, .bottom)
        case .bottomLeft:  return (.bottom, .left)
        case .topLeft:     return (.left, .top)
        }
    }

    /// The border position of a point on `edge`, the point given in the
    /// screen's top-left-origin space.
    func position(on edge: NotchEdge, of point: CGPoint) -> CGFloat {
        switch edge {
        case .top:    return min(max(point.x, 0), width)
        case .right:  return width + min(max(point.y, 0), height)
        case .bottom: return 2 * width + height - min(max(point.x, 0), width)
        case .left:   return wrapped(2 * width + 2 * height - min(max(point.y, 0), height))
        }
    }

    /// The edge a border position is on, and where along it: x on a horizontal
    /// edge and y on a vertical one, top-left origin.
    func place(at position: CGFloat) -> (edge: NotchEdge, along: CGFloat) {
        let s = wrapped(position)
        if s < width { return (.top, s) }
        if s < width + height { return (.right, s - width) }
        if s < 2 * width + height { return (.bottom, 2 * width + height - s) }
        return (.left, 2 * width + 2 * height - s)
    }

    func wrapped(_ position: CGFloat) -> CGFloat {
        let r = position.truncatingRemainder(dividingBy: perimeter)
        return r < 0 ? r + perimeter : r
    }

    /// **The corner a notch `length` long, centred at `position`, reaches
    /// round**, if any — with how much of it is before the corner and how
    /// much after.
    func corner(for position: CGFloat, length: CGFloat) -> (corner: Corner, before: CGFloat, after: CGFloat)? {
        for corner in Corner.allCases {
            var d = wrapped(self.position(of: corner) - position)
            if d > perimeter / 2 { d -= perimeter }
            if abs(d) < length / 2 {
                let before = d + length / 2
                return (corner, before, length - before)
            }
        }
        return nil
    }
}

/// **The notch going round a corner of the screen**, drawn as one body that
/// wraps it.
///
/// A window cannot bend, so while the notch passes a corner it is drawn here,
/// on a surface the size of the screen: the part still on the edge it is
/// leaving, shortening, and the part on the edge it is coming onto, growing.
/// Each keeps the notch's own curved end at its far end, and its end in the
/// corner closes up square only as the other part grows, so nothing about
/// either end changes in a step.
///
/// **Liquid, not drawn.** The two parts are blurred together and cut back at
/// half strength: where they meet in the bend they run into one round body the
/// way two drops do, with no seam and no point, and everywhere else they keep
/// their own outline. A fillet drawn into the bend could only fit where both
/// parts ran straight, and a notch is nearly as deep as it is long — half way
/// round, the bend was a pinch between the two parts' curved ends.
struct CornerPassageView: View {
    var track: BorderTrack
    var corner: BorderTrack.Corner
    /// How much of the notch is before the corner and how much after, in points.
    var before: CGFloat
    var after: CGFloat
    /// The notch across, bezel band included, and the band past the bezel —
    /// on the edge before the corner, and on the one after, where it is not
    /// the same: side edges carry the notch shallower than top and bottom.
    var depth: CGFloat
    var depthAfter: CGFloat? = nil
    var bleed: CGFloat
    var cornerRadius: CGFloat
    var flare: CGFloat
    /// Where the notch's middle is on the border.
    var place: CGFloat = 0
    /// The rings it carries, and how far along the border each is from the
    /// notch's middle; how far in from the bezel their centres are, and the
    /// scale they are drawn at.
    var rings: [PassageRing] = []
    var ringInset: CGFloat = 0
    var ringScale: CGFloat = 1
    /// Not round a corner at all but along this edge: the notch whole, as it
    /// is drawn in the hand between corners.
    var straight: NotchEdge? = nil
    /// The settings and move handles' resting arcs, hung off its two ends as
    /// the notch itself hangs them — see `PassageArc`.
    var arcs: [PassageArc] = []
    /// The notch in the hand — what its settings handle's end shows. See
    /// `CarriedHandle`.
    var carry: Carry?

    /// How far the parts run on past the screen's edges, off it, so the goo
    /// has black to work with right up to the edge: stopped at the edge, the
    /// blur ate back into it and the body came away from the bezel.
    static let margin: CGFloat = 40

    /// An empty passage: nothing on the overlay while the notch is on an edge.
    static func empty(on track: BorderTrack) -> CornerPassageView {
        CornerPassageView(track: track, corner: .topLeft, before: 0, after: 0,
                          depth: 0, bleed: 0, cornerRadius: 0, flare: 0)
    }

    /// **How much the parts run together**, the blur taken before the cut.
    ///
    /// Nothing at all as the notch arrives at a corner or leaves it, growing to
    /// its full run only as it wraps the corner — so at the hand-over from the
    /// notch itself the outline here is the notch's own to the point, and the
    /// hand-over is not a softer shape arriving.
    var goo: CGFloat {
        let length = before + after
        guard length > 0 else { return 0 }
        let share = min(1, 4 * min(before, after) / length)
        return (depth - bleed) * 0.28 * share * share * (3 - 2 * share)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only round the corner, not the whole screen: the blur is worked
            // out for every point of the canvas on every step of the drag, and
            // over the whole screen that was millions of points a step — the
            // passage stuttered exactly where it should flow.
            let region = self.region
            Canvas { context, _ in
                if goo > 0.25 {
                    context.addFilter(.alphaThreshold(min: 0.5, color: Palette.notch))
                    context.addFilter(.blur(radius: goo))
                }
                context.drawLayer { layer in
                    layer.translateBy(x: -region.minX, y: -region.minY)
                    for part in parts {
                        layer.fill(part, with: .color(goo > 0.25 ? .black : Palette.notch))
                    }
                }
            }
            .frame(width: region.width, height: region.height)
            .offset(x: region.minX - Self.margin, y: region.minY - Self.margin)

            // The rings, carried round with it: along a line their own depth
            // in from the border that takes the corner in a curve, so they go
            // round it rather than stepping from one edge to the next.
            ForEach(rings) { ring in
                ring.cell
                    .scaleEffect(ringScale)
                    .position(ringPoint(track.wrapped(place + ring.offset)))
            }

            // Carried, the settings arc is the six dots that carry it — turned
            // already, on the notch itself, the moment it was picked up. A
            // turn of its own here started over from the arc as the drawing
            // took over, and the two ran into each other.
            ForEach(arcs) { arc in
                if let carry {
                    let scale = max(ringScale, 0.0001)
                    CarriedHandle(carry: carry, edge: arc.edge, trim: arc.trim,
                                  arcRadius: (arc.radius + arc.gap) / scale - NotchLayout.orbGap,
                                  gripShift: CGSize(width: arc.away.x * arc.reach,
                                                    height: arc.away.y * arc.reach))
                        .environment(\.notchSurfaceStyle, .solid)
                        .scaleEffect(ringScale)
                        .position(arc.centre)
                }
            }
        }
        .frame(width: track.width, height: track.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// A ring's centre for a place on the border: `ringInset` in from it, and
    /// round each corner on a curve rather than across it.
    func ringPoint(_ t: CGFloat) -> CGPoint {
        let d = ringInset
        let round = 1.6 * d
        let w = track.width, h = track.height
        func inset(_ t: CGFloat) -> CGPoint {
            let (edge, along) = track.place(at: t)
            switch edge {
            case .top:    return CGPoint(x: along, y: d)
            case .right:  return CGPoint(x: w - d, y: along)
            case .bottom: return CGPoint(x: along, y: h - d)
            case .left:   return CGPoint(x: d, y: along)
            }
        }
        for corner in BorderTrack.Corner.allCases {
            var off = track.wrapped(t - track.position(of: corner))
            if off > track.perimeter / 2 { off -= track.perimeter }
            guard abs(off) < round else { continue }
            // Across the corner on one cubic, from where the curve leaves the
            // line before it to where it joins the line after, each end
            // heading along its line.
            let a = inset(track.position(of: corner) - round)
            let b = inset(track.position(of: corner) + round)
            let (first, second) = BorderTrack.edges(of: corner)
            let da = Self.heading(first), db = Self.heading(second)
            let k = (round - d) * 0.8
            let u = (off + round) / (2 * round)
            let c1 = CGPoint(x: a.x + da.x * k, y: a.y + da.y * k)
            let c2 = CGPoint(x: b.x - db.x * k, y: b.y - db.y * k)
            let v = 1 - u
            let x = v * v * v * a.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * b.x
            let y = v * v * v * a.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * b.y
            return CGPoint(x: x, y: y)
        }
        return inset(t)
    }

    /// Which way the border runs along an edge, clockwise.
    static func heading(_ edge: NotchEdge) -> CGPoint {
        switch edge {
        case .top:    return CGPoint(x: 1, y: 0)
        case .right:  return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: -1, y: 0)
        case .left:   return CGPoint(x: 0, y: -1)
        }
    }

    /// The square round the corner the parts can reach, in the parts' space:
    /// from the margin off the screen past the corner to as far in along both
    /// edges as the whole notch and the goo's reach.
    var region: CGRect {
        if straight != nil {
            return parts.first?.boundingRect.insetBy(dx: -2, dy: -2) ?? .zero
        }
        let (point, inFirst, inSecond): (CGPoint, CGPoint, CGPoint) = {
            let w = track.width, h = track.height
            switch corner {
            case .topRight:    return (CGPoint(x: w, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0))
            case .bottomRight: return (CGPoint(x: w, y: h), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1))
            case .bottomLeft:  return (CGPoint(x: 0, y: h), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0))
            case .topLeft:     return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
            }
        }()
        let m = Self.margin
        let reach = before + after + max(depth, depthAfter ?? depth) + 3 * goo
        let inward = CGPoint(x: inFirst.x + inSecond.x, y: inFirst.y + inSecond.y)
        let a = CGPoint(x: point.x + m - inward.x * m, y: point.y + m - inward.y * m)
        let b = CGPoint(x: point.x + m + inward.x * reach, y: point.y + m + inward.y * reach)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The two parts, in the canvas's space — the screen's, moved in by the
    /// margin.
    var parts: [Path] {
        if let edge = straight { return [whole(on: edge)] }
        var parts: [Path] = []
        let (first, second) = BorderTrack.edges(of: corner)
        let visible = depth - bleed
        // Each part reaches right into the corner, so the two overlap in it.
        if before > 0.5 {
            parts.append(piece(on: first, length: before, cornerAtTrailing: true,
                               closing: after / max(visible, 1), past: after))
        }
        if after > 0.5 {
            parts.append(piece(on: second, length: after, cornerAtTrailing: false,
                               closing: before / max(visible, 1), past: before,
                               depth: depthAfter ?? depth))
        }
        return parts
    }

    /// The whole notch on `edge`, both its ends its own, running on past the
    /// screen's edge by the margin as the parts do.
    private func whole(on edge: NotchEdge) -> Path {
        let length = before + after
        // Just inside each end, so an end exactly on a corner is read on
        // this edge, not as the start of the next — which drew nothing.
        let a = track.place(at: place - length / 2 + 0.001).along
        let b = track.place(at: place + length / 2 - 0.001).along
        let low = min(a, b), run = max(0.001, abs(b - a))
        let m = Self.margin
        let across = depth + m
        let rect: CGRect
        switch edge {
        case .top:    rect = CGRect(x: m + low, y: -bleed, width: run, height: across)
        case .bottom: rect = CGRect(x: m + low, y: m + track.height + bleed + m - across, width: run, height: across)
        case .left:   rect = CGRect(x: -bleed, y: m + low, width: across, height: run)
        case .right:  rect = CGRect(x: m + track.width + bleed + m - across, y: m + low, width: across, height: run)
        }
        var shape = SideNotchShape(edge: edge)
        shape.cornerRadius = cornerRadius
        shape.curlRadius = flare
        shape.bezelHidden = bleed + m
        return shape.path(in: rect)
    }

    /// One part: a notch on `edge`, `length` long up to the corner, its end in
    /// the corner closed up by `closing`, running on past the screen's edge by
    /// the margin with that band kept straight — so its flare still starts on
    /// the first row on screen.
    /// The end in the corner runs on past it by as much of the notch as has
    /// gone round, up to the margin: just arrived, not at all, so it is the
    /// notch's own end there and slides on off the screen as it goes round.
    /// Run on by the whole margin at once, the end's curve and corner went in
    /// a step — a part of it pulled to the corner.
    private func piece(on edge: NotchEdge, length: CGFloat, cornerAtTrailing: Bool,
                       closing: CGFloat, past: CGFloat, depth: CGFloat? = nil) -> Path {
        let depth = depth ?? self.depth
        let corner = track.position(of: self.corner)
        let start = cornerAtTrailing ? corner - length : corner
        let end = cornerAtTrailing ? corner : corner + length
        let a = track.place(at: start + 0.001).along, b = track.place(at: end - 0.001).along
        // Along, the end in the corner runs on past it by the margin too.
        var low = min(a, b), high = max(a, b)
        let atCornerIsLow: Bool = {
            switch (edge, self.corner) {
            case (.top, .topLeft), (.left, .topLeft), (.right, .topRight), (.bottom, .bottomLeft):
                return true
            default:
                return false
            }
        }()
        let run = min(max(past, 0), Self.margin)
        if atCornerIsLow { low -= run } else { high += run }
        let m = Self.margin
        let across = depth + m
        let span = max(0.001, high - low)
        let rect: CGRect
        switch edge {
        case .top:    rect = CGRect(x: m + low, y: m - bleed - m, width: span, height: across)
        case .bottom: rect = CGRect(x: m + low, y: m + track.height + bleed + m - across, width: span, height: across)
        case .left:   rect = CGRect(x: m - bleed - m, y: m + low, width: across, height: span)
        case .right:  rect = CGRect(x: m + track.width + bleed + m - across, y: m + low, width: across, height: span)
        }
        var shape = SideNotchShape(edge: edge)
        shape.cornerRadius = cornerRadius
        shape.curlRadius = flare
        shape.bezelHidden = bleed + m
        // The shape's leading end is the one nearer the screen's top-left along
        // either axis; which of its ends is in the corner follows from that.
        let join = min(max(closing, 0), 1)
        if atCornerIsLow { shape.leadingJoin = join } else { shape.trailingJoin = join }
        return shape.path(in: rect)
    }
}

/// One of the handles' resting arcs, as the notch hangs it off an end: the
/// flare's pocket there, facing back along the notch.
struct PassageArc: Identifiable {
    let id: Int
    let centre: CGPoint
    let edge: NotchEdge
    let trim: ClosedRange<CGFloat>
    let radius: CGFloat
    let gap: CGFloat
    let stroke: CGFloat
    /// Which way, on screen, is away from the notch along its edge — where
    /// the dots beside the settings button were — and how far, in the
    /// handle's own measure.
    var away: CGPoint = .zero
    var reach: CGFloat = 0
}

/// One ring carried round a corner: its cell, and how far along the border it
/// is from the notch's middle.
struct PassageRing: Identifiable {
    let id: String
    let cell: ProviderCell
    let offset: CGFloat
}

/// The full-screen surface a corner passage is drawn on — click-through, and
/// just below the notch. Put up when a drag begins and kept up until it ends,
/// empty whenever the notch is on an edge: a window brought up at the corner
/// itself arrived late and faded in, which is what going round a corner
/// looked like.
@MainActor
final class CornerPassageOverlay {
    private var window: NSPanel?
    private var hosting: NSHostingView<CornerPassageView>?
    let screen: NSScreen

    init(screen: NSScreen) { self.screen = screen }

    var track: BorderTrack {
        BorderTrack(width: screen.frame.width, height: screen.frame.height)
    }

    func show(_ view: CornerPassageView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let frame = screen.frame
        let hostingView = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // No fade of its own in or out: it is part of the notch moving.
        panel.animationBehavior = .none
        panel.contentView = hostingView
        panel.setFrame(frame, display: false)
        panel.orderFront(nil)
        window = panel
        hosting = hostingView
    }

    /// Up and empty, ready for the first corner.
    func prepare() { show(.empty(on: track)) }

    /// Empty again, the notch back on an edge.
    func clear() { hosting?.rootView = .empty(on: track) }

    func hide() {
        window?.orderOut(nil)
        window = nil
        hosting = nil
    }

    /// A screen point, AppKit's bottom-left origin, in the overlay's own
    /// top-left-origin space.
    func localPoint(from screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - screen.frame.minX, y: screen.frame.maxY - screenPoint.y)
    }
}
