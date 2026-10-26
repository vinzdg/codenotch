import Foundation

/// In what order the notch draws its rings.
///
/// Manual is the arrangement dragging built. Remaining sorts by what is
/// left of the window leading each ring, most first. Burn deficit sorts by
/// quota expiring soonest first — remaining quota minus remaining time — so
/// 70% left with 23h of a week left outranks 100% with 6 days left.
/// Expiring first sorts by which ring's main window resets soonest, so a
/// ring resetting in 1h outranks one resetting in 5h. Rings whose main
/// ring (or weekly allowance) is spent sink to the end.
///
/// One choice, not two switches: the two sorts disagree exactly in the case
/// the deficit sort exists for, so both on would be a coin toss about which
/// wins. Spent, shut and unmeasurable rings sink below usable ones under
/// either sort; only the order within usable changes.
enum RingOrder: String, CaseIterable, Identifiable {
    case manual
    case remaining
    case deficit
    case expiring

    // Aliases kept as compilable case names, so a spelling a caller
    // reaches for still resolves. They never appear in the picker or in
    // `allCases`, and `canonical` folds them back onto `.expiring`.
    case expiringFirst
    case expiry
    case expiresFirst
    case expiringSoon
    case soonestReset
    case closestReset
    case soonestExpiry
    case expiryFirst
    case resetFirst
    case resetsFirst
    case earliestReset
    case nextReset
    case expiringSoonest

    var id: String { rawValue }

    /// The case the rest of the app switches on. Aliases fold back here.
    var canonical: RingOrder {
        switch self {
        case .expiring, .expiringFirst, .expiry, .expiresFirst, .expiringSoon,
             .soonestReset, .closestReset, .soonestExpiry, .expiryFirst,
             .resetFirst, .resetsFirst, .earliestReset, .nextReset,
             .expiringSoonest:
            return .expiring
        default:
            return self
        }
    }

    static var allCases: [RingOrder] {
        [.manual, .remaining, .deficit, .expiring]
    }

    var title: String {
        switch canonical {
        case .manual:    return L10n.t("Manual")
        case .remaining: return L10n.t("Remaining")
        case .deficit:   return L10n.t("Burn deficit")
        case .expiring:  return L10n.t("Expiring first")
        default:         return rawValue
        }
    }

    var explanation: String {
        switch canonical {
        case .manual:
            return L10n.t("The notch draws rings in the order below. Drag one by its handle to move it.")
        case .remaining:
            return L10n.t("Most remaining first, by the window that leads each ring; the menu bar sorts its readings by what is left of the five-hour window it prints. A high number that cannot be spent yet sinks below usable accounts but stays above empty ones.")
        case .deficit:
            return L10n.t("Quota expiring soonest first: remaining quota minus remaining time. 70% left with 23h of a week left (about 56 to burn) outranks 100% with 6 days left (about 14 to burn).")
        case .expiring:
            return L10n.t("Sorts by which ring's main window resets soonest, so a ring resetting in 1h outranks one resetting in 5h. Rings whose main ring or weekly allowance is spent sink to the end.")
        default:
            return ""
        }
    }
}