import AppKit
import SwiftUI

/// The working indicator: a soft disc in the provider's brand colour that
/// breathes under the glyph.
///
/// The brand colour cannot be mistaken for the usage scale: it is a fill at
/// the glyph's radius, not a stroke on the ring, and the scale only ever
/// speaks in `ample` / `watch` / `critical`.
///
/// Bounded by `outerRadius`, the old spinner's outer edge, so the disc never
/// reaches the usage ring and the gap `NotchLayoutTests` pins still holds.
struct BusyWave: NSViewRepresentable {
    let color: Color
    let outerRadius: CGFloat
    let animates: Bool
    /// Requests are waiting behind the running one.
    let queued: Bool

    func makeNSView(context: Context) -> BusyWaveView { BusyWaveView() }

    func updateNSView(_ view: BusyWaveView, context: Context) {
        view.configure(color: NSColor(color), outerRadius: outerRadius,
                       animates: animates, queued: queued)
    }
}

/// Core Animation rather than a SwiftUI `repeatForever`: a SwiftUI animation
/// re-runs layout for the whole notch, which is one hosting view, on every
/// frame. While any session was working that alone kept the app near 4% of a
/// core, which is most of the time for anyone who leaves an agent running. A
/// layer animation runs in the render server and costs nothing between frames.
final class BusyWaveView: NSView {
    static let animationKey = "wave"

    /// A backed-up model breathes faster rather than growing the dotted ring
    /// the spinner used: a dotted stroke on top of the disc fought the fill.
    static func breathDuration(queued: Bool) -> CFTimeInterval {
        queued ? 0.55 : 1.1
    }

    let disc = CAShapeLayer()
    private var color: NSColor = .white
    private var outerRadius: CGFloat = 0
    private var animates = true
    private var queued = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.strokeColor = nil
        layer?.addSublayer(disc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: clicks belong to the ring and the notch beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, outerRadius: CGFloat, animates: Bool, queued: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.color = color
        self.outerRadius = outerRadius
        // `updateAnimation` only adds a missing animation, so a running one
        // with the old tempo, or one Reduce Motion has just stilled, has to go
        // first.
        if queued != self.queued || animates != self.animates {
            self.queued = queued
            self.animates = animates
            disc.removeAnimation(forKey: Self.animationKey)
        }
        applyColor()
        rebuildPath()
        CATransaction.commit()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildPath()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    /// The layer spans the view's bounds so its default anchor point is the
    /// ring's centre, and `transform.scale` breathes from the middle outward.
    private func rebuildPath() {
        disc.frame = bounds
        let radius = max(0, outerRadius)
        disc.path = CGPath(ellipseIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius,
                                             width: 2 * radius, height: 2 * radius), transform: nil)
    }

    /// Resolved inside the view's appearance because the monochrome brands
    /// fall back to `Palette.textPrimary`, which differs between light and
    /// dark. Under Reduce Motion the disc is fainter, so a still cell reads as
    /// busy without claiming the strength of the breath's peak.
    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            disc.fillColor = color.withAlphaComponent(animates ? 0.32 : 0.18).cgColor
        }
    }

    /// Re-added whenever it has gone missing: AppKit drops layer animations
    /// when a window leaves the screen, and the notch's panel does.
    private func updateAnimation() {
        guard animates, window != nil else {
            disc.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard disc.animation(forKey: Self.animationKey) == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.88
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1.0
        let breath = CAAnimationGroup()
        breath.animations = [grow, fade]
        breath.duration = Self.breathDuration(queued: queued)
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.isRemovedOnCompletion = false
        disc.add(breath, forKey: Self.animationKey)
    }
}
