import SwiftUI

/// The motion vocabulary, in one place so the whole surface moves like one thing.
///
/// Springs rather than eased curves throughout: macOS motion reads as physical
/// because things overshoot slightly and settle, and a panel that scales without
/// any of that feels like a slideshow. The numbers are chosen to be *just* under
/// bouncy — `dampingFraction` in the high 0.7s gives a single soft settle rather
/// than a wobble.
enum NotchMotion {
    /// Folding open and shut. Long enough to read as a movement, short enough
    /// that it never delays you.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// Contents arriving after the shape has started opening.
    static let contents = Animation.spring(response: 0.36, dampingFraction: 0.82)

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

    // MARK: Timing (AppKit side and delays, where an `Animation` does not fit)

    /// A percentage's cell following the pointer onto it. Quicker than any
    /// spring here — it is a highlight, not a movement.
    static let pop = Animation.spring(response: 0.18, dampingFraction: 0.85)

    /// How long the pointer may leave the tooltip before it is dismissed.
    /// Hover out waits, because the pointer has to cross the gap between the
    /// notch and the card without the card vanishing under it.
    static let hoverGrace: TimeInterval = 0.25

    /// How long the pointer may stray before an open notch folds shut. Longer
    /// than the hover grace: folding is a bigger movement than dismissing a
    /// tooltip, and doing it the instant the pointer strays feels twitchy.
    static let foldGrace: TimeInterval = 0.45

    /// The bare duration behind `crossfade`, for the places that crossfade in
    /// AppKit — an `NSAnimationContext` takes seconds, not an `Animation`.
    static let crossfadeDuration: TimeInterval = 0.16

    /// How long contents wait before arriving on an edge change, so the shape
    /// is already moving when they show up.
    static let arrivalBeat: TimeInterval = 0.05
}
