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
    var displayIdentifier: String? { get }
}

extension ScreenDescribing {
    /// Most displays have none, and most tests do not care.
    var hardwareNotch: HardwareNotch? { nil }
    var displayIdentifier: String? { nil }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Unlike `CGDirectDisplayID`, this UUID survives display reconfiguration
    /// and restarts, so a saved choice still names the same physical monitor.
    var displayIdentifier: String? {
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[screenNumber] as? NSNumber,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
        else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

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
        edge: NotchEdge = .right
    ) -> CGRect {
        let full = screen.frameValue
        let usable = screen.visibleFrameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: usable.maxX - width, y: full.midY - height / 2)
        case .left:
            origin = CGPoint(x: usable.minX, y: full.midY - height / 2)
        case .top:
            // AppKit's y grows upward, so the top edge is `maxY`.
            //
            // On a Mac with a notch of its own, this one goes all the way up to
            // meet it — past the menu bar — so the two read as a single shape
            // rather than as a bar parked underneath the hardware. Where there
            // is nothing to merge with, covering the menu bar buys nothing, so
            // it stays below it.
            let top = screen.hardwareNotch == nil ? usable.maxY : full.maxY
            origin = CGPoint(x: full.midX - width / 2, y: top - height)
        case .bottom:
            origin = CGPoint(x: full.midX - width / 2, y: usable.minY)
        }

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width,
            height: height
        )
    }

    static func preferredScreen(
        from screens: [NSScreen],
        preference: DisplayPreference = .followActiveWindow
    ) -> NSScreen? {
        preferredScreen(from: screens, preference: preference, activeScreen: NSScreen.main)
    }

    /// Kept generic so display selection can be proved without relying on the
    /// monitors attached to the machine running the tests.
    static func preferredScreen<Screen: ScreenDescribing>(
        from screens: [Screen],
        preference: DisplayPreference,
        activeScreen: Screen?
    ) -> Screen? {
        if case .display(let id) = preference,
           let selected = screens.first(where: { $0.displayIdentifier == id }) {
            return selected
        }
        return activeScreen ?? screens.first
    }
}
