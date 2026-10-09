import Foundation

/// When the notch folds away automatically.
///
/// Three modes:
/// - `.never`: The notch stays on screen even when full-screen apps or windows overlap it.
/// - `.onFullscreen`: The notch folds away while a full-screen app is active on the display.
/// - `.onOverlap`: The notch folds away when a full-screen app or active window overlaps its frame.
enum AutoHideMode: String, CaseIterable, Identifiable {
    case never
    case onFullscreen
    case onOverlap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never:        return L10n.t("Never")
        case .onFullscreen: return L10n.t("On full-screen")
        case .onOverlap:    return L10n.t("On overlap")
        }
    }

    var explanation: String {
        switch self {
        case .never:
            return L10n.t("The notch stays in place even over full-screen apps or overlapping windows.")
        case .onFullscreen:
            return L10n.t("The notch folds away while a full-screen app is frontmost, and returns when you leave it.")
        case .onOverlap:
            return L10n.t("The notch folds away when a full-screen app or active window overlaps its frame.")
        }
    }
}
