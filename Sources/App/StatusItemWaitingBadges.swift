import AppKit

/// The red dot on the mark of a provider that is waiting for a reply.
///
/// Waiting is the one activity state that is asking for something: the agent
/// has stopped and will not go on until somebody answers it. So it is said in
/// the one colour on an otherwise monochrome bar, and it holds still — a wait
/// can last minutes, and something moving for all of them is a nuisance. The
/// moment it starts gets a brief nudge of its own; see `StatusItemPulse.nudge`.
///
/// Drawn as views over the status button rather than into its image. The
/// image is a template, which AppKit tints whole — light bar, dark bar, a
/// wallpaper-tinted one — and a red dot inside it would come out black or
/// white like everything else. The artwork leaves a clear disc where the dot
/// goes (`StatusItemArtwork.waitingBadgeProviderIDs`), so the dot keeps a
/// ring of the bar's own colour around it whatever that colour is.
@MainActor
final class StatusItemWaitingBadges {
    private weak var view: NSView?
    private var imageSize: NSSize = .zero
    /// Where each dot goes, in the image's coordinates.
    private var frames: [String: NSRect] = [:]
    private var dots: [String: NSView] = [:]

    /// The providers showing a dot.
    var showing: Set<String> { Set(dots.keys) }

    /// Called whenever the item is redrawn, with the dots the artwork made
    /// room for — empty when nothing is waiting.
    func update(view: NSView, imageSize: NSSize, badges: [String: NSRect]) {
        self.view = view
        self.imageSize = imageSize
        frames = badges
        for (id, dot) in dots where badges[id] == nil {
            dot.removeFromSuperview()
            dots[id] = nil
        }
        for id in badges.keys where dots[id] == nil {
            let dot = Dot()
            view.addSubview(dot)
            dots[id] = dot
        }
        layout()
    }

    /// Re-fit after the button changed size: it is laid out after its image
    /// changes, not at the same moment.
    func relayout() { layout() }

    func clear() {
        for dot in dots.values { dot.removeFromSuperview() }
        dots = [:]
        frames = [:]
    }

    /// The dot's frame in the button's coordinates, for a test to check it
    /// against the hole the artwork left.
    func frame(for providerID: String) -> NSRect? { dots[providerID]?.frame }

    private func layout() {
        guard let view else { return }
        // AppKit centres the image in the button, as `StatusItemPulse` assumes.
        let dx = ((view.bounds.width - imageSize.width) / 2).rounded()
        let dy = ((view.bounds.height - imageSize.height) / 2).rounded()
        for (id, dot) in dots {
            guard let rect = frames[id] else { continue }
            // The image's origin is its lower left; a view's is wherever its
            // superview says.
            let y = view.isFlipped ? view.bounds.height - dy - rect.maxY : dy + rect.minY
            dot.frame = NSRect(x: dx + rect.minX, y: y, width: rect.width, height: rect.height)
        }
    }

    private final class Dot: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            // Resolved here, so the dot takes the red of whichever appearance
            // the bar is in.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.systemRed.cgColor
            }
            layer?.cornerRadius = bounds.height / 2
        }

        override func layout() {
            super.layout()
            needsDisplay = true
        }

        /// A dot is not a control: clicks belong to the button under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
