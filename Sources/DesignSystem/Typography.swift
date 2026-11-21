import SwiftUI

/// Sizes are derived from cap heights measured in the design frame, so they
/// track `Design.scale` along with everything else.
enum Typography {
    /// Computes scaled font point size from cap-height pixels and a typography scale factor.
    static func fontSize(capPixels: CGFloat, scale: CGFloat = 1.0) -> CGFloat {
        (Design.fontSize(capPixels: capPixels) * scale).rounded(.toNearestOrAwayFromZero)
    }

    /// The percent under each provider ring. Cap height 27px in the frame.
    static func percent(scale: CGFloat = 1.0) -> Font {
        Font.system(size: fontSize(capPixels: 27, scale: scale), weight: .semibold)
    }

    /// "30%/70%": the 5h and weekly readings together, a step smaller so the
    /// pair fits roughly the width one reading used to.
    static func percentPair(scale: CGFloat = 1.0) -> Font {
        Font.system(size: fontSize(capPixels: 22, scale: scale), weight: .semibold)
    }

    /// The one ring's percentage on the other side of the Mac's notch, where it
    /// has the whole depth to itself rather than a line under the ring: sized
    /// against the ring beside it, its capitals 40% of the ring's 117px.
    static func percentAcrossSize(scale: CGFloat = 1.0) -> CGFloat {
        fontSize(capPixels: 47, scale: scale)
    }

    static func percentAcross(scale: CGFloat = 1.0) -> Font {
        Font.system(size: percentAcrossSize(scale: scale), weight: .semibold)
    }

    /// The pair there, a step smaller as under the ring, so it fits the side.
    static func percentPairAcrossSize(scale: CGFloat = 1.0) -> CGFloat {
        fontSize(capPixels: 38, scale: scale)
    }

    static func percentPairAcross(scale: CGFloat = 1.0) -> Font {
        Font.system(size: percentPairAcrossSize(scale: scale), weight: .semibold)
    }

    /// "Claude Usage". Cap height 26px.
    static func cardTitle(scale: CGFloat = 1.0) -> Font {
        Font.system(size: fontSize(capPixels: 26, scale: scale), weight: .semibold)
    }

    /// "Current session", "73% Used", "Resets in 51 min". Cap height 18px.
    static func cardBody(scale: CGFloat = 1.0) -> Font {
        Font.system(size: fontSize(capPixels: 18, scale: scale), weight: .regular)
    }

    // Static presets at 1:1 default design scale for convenience and backward compatibility
    static let percent = percent(scale: 1.0)
    static let percentPair = percentPair(scale: 1.0)
    static let percentAcrossSize = percentAcrossSize(scale: 1.0)
    static let percentAcross = percentAcross(scale: 1.0)
    static let percentPairAcrossSize = percentPairAcrossSize(scale: 1.0)
    static let percentPairAcross = percentPairAcross(scale: 1.0)
    static let cardTitle = cardTitle(scale: 1.0)
    static let cardBody = cardBody(scale: 1.0)
}
