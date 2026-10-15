import AppKit
import QuartzCore

/// Dims the marks of the providers that are working and brings them back, on
/// a slow loop, without changing how the menu bar item is drawn.
///
/// A mask on the status button's own layer rather than marks drawn a second
/// time on top: AppKit goes on tinting the item exactly as it tints any
/// template — light and dark bars, a wallpaper-tinted one, the dimmer bar of a
/// display that is not active — and only the mask's alpha moves. The open
/// menu's highlight is drawn outside the button's layer, so it is untouched.
///
/// Core Animation moves the alpha in the render server, the way the notch's
/// spinning arc is turned: nothing here runs between frames, and with nothing
/// working there is no mask and no animation at all.
///
/// Each mark's hole is a column the full height of the item. Nothing else is
/// drawn above or below a mark, so it never needs to know which way up the
/// button's layer is.
@MainActor
final class StatusItemPulse {
    /// One breath: full, down to `dimmest`, and back. Slow enough to read as
    /// "still going" rather than as an alert.
    ///
    /// Deep enough to be seen out of the corner of an eye. A dip to 62% on a
    /// mark the size of a menu bar glyph read as a flicker you had to be
    /// looking at to catch; at a fifth the mark all but goes and comes back,
    /// which is what makes "working" visible from across the screen. The
    /// period is longer than the shallow breath's for the same reason the
    /// amplitude is larger: a deep dip at the old pace read as blinking.
    static let period: CFTimeInterval = 1.8
    static let dimmest: Float = 0.2
    static let animationKey = "activity-pulse"
    /// How long a mark takes to come back to full once its provider stops.
    static let settleDuration: CFTimeInterval = 0.3
    private static let settleKey = "activity-settle"

    private weak var view: NSView?
    /// The layer the mask was put on, so a replaced layer does not keep it.
    private weak var maskedLayer: CALayer?
    private var imageSize: NSSize = .zero
    /// Where each entry's mark is, in the image's coordinates.
    private var glyphs: [String: NSRect] = [:]
    private let mask = CALayer()
    /// Everything but the marks' columns, fully opaque.
    private let rest = CAShapeLayer()
    /// One per mark that is pulsing or settling back.
    private var marks: [String: CALayer] = [:]
    /// Marks on their way back to full, and when they started.
    private var settling: [String: Date] = [:]

    init() {
        rest.fillRule = .evenOdd
        rest.fillColor = NSColor.black.cgColor
        mask.addSublayer(rest)
    }

    /// The providers whose marks pulse — empty when none should.
    var pulsing: Set<String> { Set(marks.keys).subtracting(settling.keys) }

    /// Called whenever the item is redrawn. `glyphs` are every entry's mark,
    /// `working` the ones to pulse.
    func update(view: NSView, imageSize: NSSize, glyphs: [String: NSRect], working: Set<String>) {
        self.view = view
        self.imageSize = imageSize
        self.glyphs = glyphs
        purgeSettled()
        for (id, mark) in marks where !working.contains(id) {
            // Still on the bar: ease back to full, then go. Gone from it: go.
            if glyphs[id] != nil { settle(id, mark) } else { remove(id) }
        }
        for id in working where glyphs[id] != nil {
            let mark = marks[id] ?? makeMark(id)
            if settling.removeValue(forKey: id) != nil { mark.removeAnimation(forKey: Self.settleKey) }
            addPulse(to: mark)
        }
        layout()
    }

    /// Re-fit the mask after the button changed size: the item is laid out
    /// after its image changes, not at the same moment.
    func relayout() { layout() }

    /// Put back anything AppKit took away while the item was off screen.
    func ensureRunning() {
        guard !marks.isEmpty else { return }
        layout()
        for id in pulsing { if let mark = marks[id] { addPulse(to: mark) } }
    }

    func clear() {
        for id in Array(marks.keys) { remove(id) }
        layout()
    }

    private func makeMark(_ id: String) -> CALayer {
        let mark = CALayer()
        mark.backgroundColor = NSColor.black.cgColor
        mask.addSublayer(mark)
        marks[id] = mark
        return mark
    }

    private func addPulse(to mark: CALayer) {
        guard mark.animation(forKey: Self.animationKey) == nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = Self.dimmest
        breath.duration = Self.period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // An explicit layer-local start makes phase continuity observable and
        // ensures routine artwork redraws do not silently restart the breath.
        breath.beginTime = mark.convertTime(CACurrentMediaTime(), from: nil)
        breath.isRemovedOnCompletion = false
        mark.add(breath, forKey: Self.animationKey)
    }

    /// From wherever the breath had got to back to full, rather than a jump.
    private func settle(_ id: String, _ mark: CALayer) {
        guard settling[id] == nil else { return }
        settling[id] = Date()
        let current = mark.presentation()?.opacity ?? mark.opacity
        mark.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 1
        CATransaction.commit()
        guard current < 1 else { return remove(id, relayout: true) }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settling[id] != nil else { return }
                self.remove(id, relayout: true)
            }
        }
        let back = CABasicAnimation(keyPath: "opacity")
        back.fromValue = current
        back.toValue = 1
        back.duration = Self.settleDuration
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mark.add(back, forKey: Self.settleKey)
        CATransaction.commit()
    }

    /// A settle whose completion never came — the item was off screen while
    /// it ran — is over all the same.
    private func purgeSettled() {
        let now = Date()
        for (id, since) in settling where now.timeIntervalSince(since) > Self.settleDuration + 0.5 {
            remove(id)
        }
    }

    private func remove(_ id: String, relayout: Bool = false) {
        settling.removeValue(forKey: id)
        marks.removeValue(forKey: id)?.removeFromSuperlayer()
        if relayout { layout() }
    }

    private func layout() {
        guard let layer = view?.layer, !marks.isEmpty else {
            maskedLayer?.mask = nil
            maskedLayer = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit centres the image in the button.
        let offset = ((layer.bounds.width - imageSize.width) / 2).rounded()
        // Far past the button on every side: a mask that stopped short of a
        // button still growing into its new width would hide whatever it had
        // not yet reached.
        let path = CGMutablePath()
        path.addRect(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        for (id, mark) in marks {
            guard let glyph = glyphs[id] else { continue }
            // A point of slack either side: the image may land half a point
            // from where it was asked to at 1x, and the gap to the next
            // figure is several points wide.
            let column = CGRect(x: glyph.minX + offset - 1, y: -100,
                                width: glyph.width + 2, height: layer.bounds.height + 200)
            mark.frame = column
            path.addRect(column)
        }
        rest.path = path
        mask.frame = layer.bounds
        rest.frame = mask.bounds
        if maskedLayer !== layer {
            maskedLayer?.mask = nil
            layer.mask = mask
            maskedLayer = layer
        } else if layer.mask !== mask {
            layer.mask = mask
        }
        CATransaction.commit()
    }
}
