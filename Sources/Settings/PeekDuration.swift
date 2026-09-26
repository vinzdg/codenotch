import Foundation

/// How long the notch stays open when it opens by itself.
///
/// A fixed set rather than a free number: the useful range is narrow, and the
/// values outside it are worse than they look. Below a second or two the notch
/// is gone before a glance can land on it; much beyond ten it stops reading as
/// an announcement and starts being a thing parked on the screen edge that has
/// to be waited out.
///
/// `untilSeen` is the exception, and the default: a stopped session's card
/// stays until it is clicked or its app comes to the front.
enum PeekDuration: String, CaseIterable, Identifiable {
    case untilSeen
    case brief
    case standard
    case long

    var id: String { rawValue }

    /// Nil for `untilSeen`, which has no clock.
    var seconds: TimeInterval? {
        switch self {
        case .untilSeen: return nil
        case .brief:    return 3
        case .standard: return 5
        case .long:     return 10
        }
    }

    var title: String {
        switch self {
        case .untilSeen: return L10n.t("Until I look")
        case .brief:    return L10n.t("3 seconds")
        case .standard: return L10n.t("5 seconds")
        case .long:     return L10n.t("10 seconds")
        }
    }

    var explanation: String {
        switch self {
        case .untilSeen:
            return L10n.t("Stays until you click it or switch to the session's app. Several wait in line.")
        case .brief:
            return L10n.t("Long enough to notice, short enough to ignore.")
        case .standard:
            return L10n.t("Long enough to read the session's name and reach for it.")
        case .long:
            return L10n.t("Stays until you have had a chance to look up.")
        }
    }
}
