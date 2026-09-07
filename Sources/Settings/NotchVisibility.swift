import Foundation

/// How much of itself the notch shows when you are not using it.
///
/// Three states rather than the two that get asked for, because the default is
/// neither: at rest the notch is already a small pill that opens on contact.
/// Offering only "always" and "hidden" would quietly delete the behaviour the
/// app was designed around.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open. The readings are always on screen.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it. The default.
    case onHover
    /// Nothing on screen at all.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover:    return "Show on hover"
        case .hidden:     return "Hide"
        }
    }

    var explanation: String {
        switch self {
        case .alwaysShow:
            return "The notch stays open with every reading visible."
        case .onHover:
            return "A small pill at the screen edge that opens when you reach it."
        case .hidden:
            // Said here because a hidden notch is also a hidden way back in.
            // Names the menu bar route: with the notch off screen the readings
            // live in the menu bar menu instead, so Hide plus App icon "Menu
            // bar" is a working setup rather than a one-way door.
            return "Nothing on screen. The readings stay in the menu bar menu "
                 + "when App icon is Menu bar. Otherwise, open Codenotch again "
                 + "from Applications to bring these settings back."
        }
    }
}
