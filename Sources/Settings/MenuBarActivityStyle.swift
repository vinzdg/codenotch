import Foundation

/// How the menu bar item shows that one of a provider's agents is working
/// right now.
///
/// The notch has its own answer to this question — `BusyIndicatorStyle` — and
/// the two deliberately do not share an enum: an arc turning inside a ring and
/// a breathing disc are drawn against a ring that the bar does not have. What
/// they do share is the question, and the reason for asking it. Movement in
/// the menu bar is harder to ignore than movement on the screen edge, and
/// until now the only way to stop it was to turn Reduce Motion on for the
/// whole of macOS.
///
/// Raw values are persistence keys, not display copy. `.pulse` is the default
/// because it is what the item has always done; Reduce Motion still overrides
/// it with the still dot, as it always has.
///
/// The working indication only. A session waiting on a reply keeps its red dot
/// whichever of these is chosen: that dot is not movement, and it is the one
/// state on the bar that is asking for somebody.
enum MenuBarActivityStyle: String, CaseIterable, Identifiable {
    /// Each working provider's mark dims and comes back, on a slow loop.
    case pulse
    /// A still dot on each working provider's mark, and no animation at all —
    /// what Reduce Motion has always given the item.
    case dot
    /// Nothing. The bar is its figures, and work is visible in the notch, the
    /// menu and the tooltip as before.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulse: return L10n.t("Pulse")
        case .dot:   return L10n.t("Still dot")
        case .off:   return L10n.t("None")
        }
    }

    var explanation: String {
        switch self {
        case .pulse:
            return L10n.t("Each working provider's mark dims and comes back, and blinks a few times as its work ends. With Reduce Motion on, the still dot is used instead.")
        case .dot:
            return L10n.t("A dot on each working provider's mark, and nothing moves.")
        case .off:
            return L10n.t("The bar shows the limits alone. Work is still in the notch, the menu and the tooltip.")
        }
    }

    /// Whether the item animates: the pulse itself, and the blinks that mark a
    /// wait beginning or work ending. Reduce Motion answers no to all of it.
    func animates(reducesMotion: Bool) -> Bool { self == .pulse && !reducesMotion }

    /// Whether a working mark gets the still badge — chosen outright, or
    /// standing in for the pulse under Reduce Motion.
    func showsStillBadge(reducesMotion: Bool) -> Bool {
        self == .dot || (self == .pulse && reducesMotion)
    }
}
