import Foundation

/// What a plain click on the menu bar item does.
///
/// The menu is the item's reason for existing as much as the readings are:
/// with the app out of the Dock it is the only way to Settings and to Quit.
/// So it is never further than a right-click away, whatever is chosen here,
/// and the default leaves it exactly where it has always been.
///
/// The two alternatives are the two things people were opening the menu in
/// order to do. Asking for a fresh reading took a click, a look down the
/// menu and a second click; so did opening Activity.
///
/// Raw values are persistence keys, not display copy.
enum MenuBarClickAction: String, CaseIterable, Identifiable {
    /// The menu, as ever.
    case menu
    /// Re-read every provider, the way the menu's own row does.
    case refresh
    /// The Activity window.
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu:     return L10n.t("Menu")
        case .refresh:  return L10n.t("Refresh all")
        case .activity: return L10n.t("Activity")
        }
    }

    var explanation: String {
        switch self {
        case .menu:
            return L10n.t("A click opens the menu: every account's card, Refresh all, Activity and Settings.")
        case .refresh:
            return L10n.t("A click asks every provider for a fresh reading. The menu is a right-click away, or a ⌃-click.")
        case .activity:
            return L10n.t("A click opens the Activity window. The menu is a right-click away, or a ⌃-click.")
        }
    }

    /// Whether the item hands its clicks to AppKit's own menu tracking.
    ///
    /// True is the untouched path: `NSStatusItem.menu` is set and nothing
    /// else is involved, exactly as before this setting existed. The others
    /// take the clicks and put the menu back for the ones that ask for it.
    var opensMenuOnItsOwn: Bool { self == .menu }
}
