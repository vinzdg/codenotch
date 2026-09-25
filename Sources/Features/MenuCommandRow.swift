import AppKit

/// A menu row that runs its command and leaves the menu open.
///
/// It draws itself because a row AppKit draws cannot stay open — see
/// `StatusItemController.refreshItem()` — and a row with a view gives up
/// everything AppKit would have drawn for it, the highlight included. So what
/// it gives up is put back, measured off AppKit's own rows beside it, so that
/// it reads as one of them: the menu font at their indent and baseline, the
/// shortcut in their column and their ink, and their highlight.
final class MenuCommandRowView: NSView {
    /// Run when the row is clicked, with the menu still open.
    var onClick: (() -> Void)?
    /// The command is already running. The row says so, in a disabled row's
    /// ink and without a highlight, and a click on it does nothing until it is
    /// done.
    var isBusy = false {
        didSet { if isBusy != oldValue { restyle() } }
    }
    /// Under the pointer or the arrow keys. Told by the menu's delegate: AppKit
    /// keeps track of it for a row with a view but draws nothing for it.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { restyle() } }
    }

    private let title: String
    private let busyTitle: String
    private let keyEquivalent: String
    private let modifiers: NSEvent.ModifierFlags
    /// The system's own selection material rather than a colour picked to
    /// match it, so the highlight follows the accent colour and the appearance
    /// the way AppKit's own rows do.
    private let selection = NSVisualEffectView()
    /// The words and the shortcut. A view draws beneath its subviews, so they
    /// cannot be the row's own drawing and still sit on the highlight.
    private let ink = Ink()

    // Measured in points off AppKit's own rows in the same menu, at 2x, on
    // macOS 27: where their titles start, how tall a row is, where the
    // shortcut column sits against the trailing edge, and the highlight's
    // inset and corner. The key is centred in its column — a comma and a Q
    // share one centre, not one left edge — and the modifiers end a fixed step
    // before that centre.
    static let height: CGFloat = 24
    private static let titleInset: CGFloat = 30
    private static let keyCentreInset: CGFloat = 22.3
    private static let modifierGap: CGFloat = 6.5
    private static let selectionInset: CGFloat = 5
    private static let selectionRadius: CGFloat = 7

    init(title: String, busyTitle: String, keyEquivalent: String,
         modifiers: NSEvent.ModifierFlags) {
        self.title = title
        self.busyTitle = busyTitle
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        // Narrow on purpose: the menu takes its width from its widest item,
        // and this one follows whatever that is.
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: Self.height))
        autoresizingMask = .width

        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.maskImage = Self.roundedMask(radius: Self.selectionRadius)
        selection.frame = bounds.insetBy(dx: Self.selectionInset, dy: 0)
        selection.autoresizingMask = .width
        selection.isHidden = true
        addSubview(selection)

        ink.frame = bounds
        ink.autoresizingMask = [.width, .height]
        ink.draws = { [unowned self] in self.drawInk() }
        addSubview(ink)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var showsSelection: Bool { isHighlighted && !isBusy }

    private func restyle() {
        selection.isHidden = !showsSelection
        ink.needsDisplay = true
    }

    private func drawInk() {
        let font = NSFont.menuFont(ofSize: 0)
        let titleInk: NSColor
        let shortcutInk: NSColor
        if isBusy {
            (titleInk, shortcutInk) = (.disabledControlTextColor, .disabledControlTextColor)
        } else if showsSelection {
            (titleInk, shortcutInk) = (.selectedMenuItemTextColor, .selectedMenuItemTextColor)
        } else {
            (titleInk, shortcutInk) = (.labelColor, .tertiaryLabelColor)
        }

        // The line box, a whole number of points tall, centred on the row and
        // its baseline put on a device pixel — where AppKit puts its own.
        let scale = window?.backingScaleFactor ?? 2
        let lineHeight = (font.ascender - font.descender).rounded(.up)
        let baseline = ((bounds.height - lineHeight) / 2 + font.ascender) * scale
        let top = baseline.rounded() / scale - font.ascender

        let text = NSAttributedString(string: isBusy ? busyTitle : title,
                                      attributes: [.font: font, .foregroundColor: titleInk])
        text.draw(at: NSPoint(x: Self.titleInset, y: top))

        guard !keyEquivalent.isEmpty else { return }
        let key = NSAttributedString(string: keyEquivalent.uppercased(),
                                     attributes: [.font: font, .foregroundColor: shortcutInk])
        let keyCentre = bounds.maxX - Self.keyCentreInset
        key.draw(at: NSPoint(x: keyCentre - key.size().width / 2, y: top))

        let glyphs = NSAttributedString(string: Self.symbols(for: modifiers),
                                        attributes: [.font: font, .foregroundColor: shortcutInk])
        glyphs.draw(at: NSPoint(x: keyCentre - Self.modifierGap - glyphs.size().width, y: top))
    }

    /// The modifiers as a menu prints them, in the order it prints them.
    private static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
    }

    /// A rounded rectangle that stretches between its corners, for the
    /// material to show through.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }

    /// Draws what it is told to, in the row's own coordinates.
    private final class Ink: NSView {
        var draws: (() -> Void)?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { draws?() }
    }

    // The whole row is one target: neither the highlight nor the words lying
    // over it may be the view a click lands on.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // Taken here, so the menu never sees the click and never closes on it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard !isBusy, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    // Return on a row with a view is handed to the view rather than acted on,
    // and only to a view that takes first responder: left alone, reaching the
    // row with the arrow keys and pressing Return did nothing at all. It is
    // answered the way a click is, menu left open.
    //
    // Only while highlighted. A row that always took first responder was
    // given the keyboard as the menu opened, and drew itself highlighted with
    // nothing under the pointer.
    override var acceptsFirstResponder: Bool { isHighlighted }

    override func keyDown(with event: NSEvent) {
        // A key the menu leaves to the row is the row's to answer — Return
        // is — and Escape must still close the menu if it is one of them.
        if event.keyCode == Self.escapeKey {
            enclosingMenuItem?.menu?.cancelTracking()
            return
        }
        guard Self.chooseKeys.contains(event.keyCode), isHighlighted else {
            return super.keyDown(with: event)
        }
        if !isBusy { onClick?() }
    }

    /// Return and the keypad's Enter.
    private static let chooseKeys: Set<UInt16> = [36, 76]
    private static let escapeKey: UInt16 = 53
}
