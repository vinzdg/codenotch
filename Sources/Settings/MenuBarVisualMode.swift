import Foundation

/// How the menu bar item presents each chosen provider's five-hour limit:
/// the current text figures, compact status markers, or short usage bars.
///
/// Width is the menu bar's scarce resource, and visual indicators offer a
/// fast, scannable state representation at a glance without opening the menu
/// or notch.
///
/// Raw values are persistence keys, not display copy. `.text` is the default
/// because it preserves the original textual mark, percentage and countdown.
enum MenuBarVisualMode: String, CaseIterable, Identifiable {
    /// The current text presentation: the provider's mark, percentage and countdown.
    case text
    /// One compact status point per selected provider, coloured by usage state.
    case markers
    /// A short usage bar per selected provider, with percentage retained in tooltip and menu.
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:    return L10n.t("Text")
        case .markers: return L10n.t("Markers")
        case .bars:    return L10n.t("Bars")
        }
    }

    var explanation: String {
        switch self {
        case .text:
            return L10n.t("The current text presentation: the provider's mark, percentage and countdown.")
        case .markers:
            return L10n.t("One compact status point per selected provider, coloured by usage state.")
        case .bars:
            return L10n.t("A short usage bar per selected provider, with exact figures kept in the tooltip and menu.")
        }
    }

    /// Whether this mode displays visual graphics (markers or bars) in place of text.
    var isVisual: Bool { self != .text }
}
