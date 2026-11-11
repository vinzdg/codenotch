import SwiftUI

/// Sizes are derived from cap heights measured in the design frame, so they
/// track `Design.scale` along with everything else.
enum Typography {
    /// The percent under each provider ring. Cap height 27px in the frame.
    static let percent = Font.system(size: Design.fontSize(capPixels: 27), weight: .semibold)

    /// "30%/70%": the 5h and weekly readings together, a step smaller so the
    /// pair fits roughly the width one reading used to.
    static let percentPair = Font.system(size: Design.fontSize(capPixels: 22), weight: .semibold)

    /// The one ring's percentage on the other side of the Mac's notch, where it
    /// has the whole depth to itself rather than a line under the ring: sized
    /// against the ring beside it, its capitals 40% of the ring's 117px.
    static let percentAcrossSize = Design.fontSize(capPixels: 47)
    static let percentAcross = Font.system(size: percentAcrossSize, weight: .semibold)

    /// The pair there, a step smaller as under the ring, so it fits the side.
    static let percentPairAcrossSize = Design.fontSize(capPixels: 38)
    static let percentPairAcross = Font.system(size: percentPairAcrossSize, weight: .semibold)

    /// "Claude Usage". Cap height 26px.
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .semibold)

    /// "Current session", "73% Used", "Resets in 51 min". Cap height 18px.
    static let cardBody = Font.system(size: Design.fontSize(capPixels: 18), weight: .regular)
}
