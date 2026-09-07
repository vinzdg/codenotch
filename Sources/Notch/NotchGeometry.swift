import AppKit

/// The display's *own* notch — the camera housing on a MacBook, not ours.
///
/// Worth naming, because it is the one piece of the screen that is not a screen:
/// pixels drawn there are behind a hole, not merely covered.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat
}

/// Everything the geometry maths needs from a screen, so it can be faked in tests.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
}

extension ScreenDescribing {
    /// Most displays have none, and most tests do not care.
    var hardwareNotch: HardwareNotch? { nil }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Measured from the two menu-bar strips *either side* of the notch, which
    /// is the only thing AppKit describes directly. `safeAreaInsets.top` gives
    /// the height; a display without a notch reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return nil
        }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

enum NotchGeometry {
    /// The panel hugs the chosen edge and is centred along it.
    ///
    /// **Which edge it hugs is `visibleFrame`'s, not `frame`'s.** That is what
    /// keeps a bottom notch resting on top of the Dock and a top one below the
    /// menu bar rather than behind them, and it is why the notch moves when the
    /// Dock hides — `visibleFrame` gives the space back and the notch takes it.
    ///
    /// **Centring, though, stays on `frame`.** A Dock at the bottom is nowhere
    /// near a right-edge notch, and centring on the visible area would shift
    /// that notch up and down the screen every time the Dock hid itself, for no
    /// reason anyone could see.
    ///
    /// The rect is rounded out to whole points on purpose. AppKit rounds window
    /// frames anyway, and if it does the rounding the panel ends up a fraction
    /// larger than asked for — which leaves the content, laid out at its exact
    /// size, stopping short of the screen edge. A hairline of wallpaper along
    /// that edge is all it takes for the notch to read as floating rather than
    /// welded to the bezel.
    static func panelFrame(
        for screen: ScreenDescribing,
        panelSize: CGSize,
        edge: NotchEdge = .right,
        // A user-chosen nudge along the edge, from `NotchViewModel.alongOffset`
        // — zero is the centred default this file always drew before the nudge
        // existed. Vertical edges read it as AppKit's y running *down* the
        // screen (dragging the pill down increases it); horizontal edges read
        // it as x running right, which needs no such flip.
        alongOffset: CGFloat = 0,
        // The padding `panelSize` carries on *each* end beyond the visible
        // pill, reserved for a hover card that is not there right now —
        // `NotchViewModel.slack`. Clamping the offset by the padded size
        // would have left the pill only a sliver of room to move in on most
        // screens, since that padding is sized for the tallest possible card
        // and can be most of the panel. Clamping by the pill's own extent
        // instead — `panelSize` shrunk by this on each end — lets it travel
        // almost the full edge; the padding is free to run past the bezel,
        // since nothing is drawn there until a card actually opens.
        slack: CGFloat = 0
    ) -> CGRect {
        let full = screen.frameValue
        let usable = screen.visibleFrameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack, max: full.maxY - height + slack)
            origin = CGPoint(x: usable.maxX - width, y: y)
        case .left:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack, max: full.maxY - height + slack)
            origin = CGPoint(x: usable.minX, y: y)
        case .top:
            // AppKit's y grows upward, so the top edge is `maxY`.
            //
            // On a Mac with a notch of its own, this one goes all the way up to
            // meet it — past the menu bar — so the two read as a single shape
            // rather than as a bar parked underneath the hardware. Where there
            // is nothing to merge with, covering the menu bar buys nothing, so
            // it stays below it.
            let top = screen.hardwareNotch == nil ? usable.maxY : full.maxY
            let x = clamp(full.midX - width / 2 + alongOffset,
                          min: full.minX - slack, max: full.maxX - width + slack)
            origin = CGPoint(x: x, y: top - height)
        case .bottom:
            let x = clamp(full.midX - width / 2 + alongOffset,
                          min: full.minX - slack, max: full.maxX - width + slack)
            origin = CGPoint(x: x, y: usable.minY)
        }

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width,
            height: height
        )
    }

    /// Keeps a dragged offset from pushing the visible pill off the screen it
    /// is on. A plain `ClosedRange` clamp would trap if the pill were ever
    /// taller or wider than the screen, which a very small display could
    /// make true.
    private static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard lo <= hi else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }

    /// The notch follows the screen with the menu bar.
    static func preferredScreen(from screens: [NSScreen]) -> NSScreen? {
        NSScreen.main ?? screens.first
    }
}
