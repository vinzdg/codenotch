import Foundation

/// In what order the notch draws its rings.
///
/// Manual is the arrangement dragging built. Remaining sorts by what is
/// left of the window leading each ring, most first. Burn deficit sorts by
/// quota expiring soonest first — remaining quota minus remaining time — so
/// 70% left with 23h of a week left outranks 100% with 6 days left.
///
/// One choice, not two switches: the two sorts disagree exactly in the case
/// the deficit sort exists for, so both on would be a coin toss about which
/// wins. Spent, shut and unmeasurable rings sink below usable ones under
/// either sort; only the order within usable changes.
enum RingOrder: String, CaseIterable, Identifiable {
    case manual
    case remaining
    case deficit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual:    return L10n.t("Manual")
        case .remaining: return L10n.t("Remaining")
        case .deficit:   return L10n.t("Burn deficit")
        }
    }

    var explanation: String {
        switch self {
        case .manual:
            return L10n.t("The notch draws rings in the order below. Drag one by its handle to move it.")
        case .remaining:
            return L10n.t("Most remaining first, by the window that leads each ring. A high number that cannot be spent yet sinks below usable accounts but stays above empty ones.")
        case .deficit:
            return L10n.t("Quota expiring soonest first: remaining quota minus remaining time. 70% left with 23h of a week left (about 56 to burn) outranks 100% with 6 days left (about 14 to burn).")
        }
    }
}
