import Foundation

/// How much of each reading the menu bar item prints: the provider's mark and
/// the share of its window spent, and whether the countdown to the reset comes
/// with it.
///
/// Width is the menu bar's scarce resource, and it is scarcest on exactly the
/// Macs this app is named after: left of a hardware notch there is only so
/// much room, and macOS hides a status item that does not fit rather than
/// squeezing it — silently, with no sign that anything was dropped. The item
/// has always decided this by counting (`StatusItemSummary.fullEntryLimit`),
/// which is a fair guess and nobody's actual preference. This is the guess
/// made answerable.
///
/// Raw values are persistence keys, not display copy. `.automatic` is the
/// default because it is the rule the item has always followed.
enum MenuBarReading: String, CaseIterable, Identifiable {
    /// Two readings carry their countdowns; past two the shares stand alone.
    case automatic
    /// A mark and a percentage, however many readings there are.
    case share
    /// Every reading carries its countdown, however many there are.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic")
        case .share:     return L10n.t("Share only")
        case .full:      return L10n.t("Share and countdown")
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return L10n.t("Two readings carry their countdowns. Past two the bar keeps the shares alone and the countdowns move to the tooltip.")
        case .share:
            return L10n.t("Every reading is a mark and a percentage. The narrowest the bar gets, and the countdowns are still a hover away.")
        case .full:
            return L10n.t("Every reading carries its countdown. Past two this is a wide item, and macOS hides one that does not fit on the bar rather than squeezing it.")
        }
    }

    /// Whether the countdowns are dropped, for this many readings on the bar.
    func isCompact(entryCount: Int) -> Bool {
        switch self {
        case .automatic: return entryCount > StatusItemSummary.fullEntryLimit
        case .share:     return true
        case .full:      return false
        }
    }
}
