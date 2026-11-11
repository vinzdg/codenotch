import SwiftUI

/// The motion vocabulary, in one place so the whole surface moves like one thing.
///
/// Springs rather than eased curves throughout: macOS motion reads as physical
/// because things overshoot slightly and settle, and a panel that scales without
/// any of that feels like a slideshow. The numbers are chosen to be *just* under
/// bouncy — `dampingFraction` in the high 0.7s gives a single soft settle rather
/// than a wobble.
enum NotchMotion {
    /// Folding open and shut.
    ///
    /// Heavier and looser than it was at 0.42/0.78, which read as a switch
    /// being thrown. What the notch is meant to look like is a body of liquid
    /// changing shape: slow enough to have mass, and damped just under the
    /// point where it would stop dead, so it settles rather than arrives. The
    /// small overshoot is the whole effect — take it out and no amount of
    /// duration makes it fluid.
    ///
    /// It only reads that way because `SideNotchShape` is `Animatable`: the
    /// spring carries the shape's own numbers, not just the rect it is drawn
    /// into. See its `animatableData`.
    static let unfold = Animation.spring(response: 0.62, dampingFraction: 0.72)

    /// **Letting go of the display's notch** when the notch is picked up.
    ///
    /// Short and firm, because it is the one movement that can still be running
    /// when the drag starts arriving underneath it: the hand goes down and moves
    /// at once. Anything eased while the drag steps is eased on a different
    /// clock from the drag, and for however long that lasts the two can draw
    /// out of step. Settled in about a quarter of a second, with no overshoot to
    /// come back from.
    static let lift = Animation.spring(response: 0.26, dampingFraction: 0.92)

    /// Contents arriving after the shape has started opening. Kept a little
    /// quicker than `unfold` so the readings catch up with the black rather
    /// than dragging behind it.
    static let contents = Animation.spring(response: 0.48, dampingFraction: 0.8)

    /// The tooltip travelling between cells. Slower and more damped than the
    /// fold: it is a bigger object moving a longer way, and the same spring that
    /// feels crisp on a 10pt pill feels abrupt on a 226pt card.
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)

    /// Contents changing inside something that is already moving. Short, and an
    /// ease rather than a spring — a spring on a crossfade has nothing to
    /// overshoot and just arrives late.
    static let crossfade = Animation.easeInOut(duration: 0.16)

    /// A percentage changing under you. Slower on purpose: a ring that snaps to a
    /// new value reads as a glitch, one that sweeps reads as a measurement.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)

    /// The settings arc being taken back into the notch.
    ///
    /// Quicker than `unfold` and with no delay, which is the whole point: on
    /// the staggered spring the arc lagged the fold, so the notch began closing
    /// first and the arc appeared to leave with the screen edge instead of
    /// being absorbed. It has to be inside the black while there is still black
    /// to be inside. Eased *in* because a thing being drawn into a mass
    /// accelerates as it goes.
    static let merge = Animation.easeIn(duration: 0.2)

    /// Each cell trails the one above it, so the stack unfurls rather than
    /// appearing all at once. Capped so a long list never feels sluggish.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// Everything above, unless the system has been asked for less movement.
    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}
