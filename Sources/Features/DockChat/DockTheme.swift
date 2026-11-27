import AppKit
import SwiftUI

/// How Codedock is painted, and the ink that reads on it.
enum DockTheme: String, CaseIterable, Identifiable {
    case dark, dock, black, white

    var id: String { rawValue }

    static var current: DockTheme {
        DockTheme(rawValue: UserDefaults.standard.string(forKey: Preferences.codedockLookKey) ?? "") ?? .dark
    }

    var title: String {
        switch self {
        case .dark: return L10n.t("Dark")
        case .dock: return L10n.t("Match the Dock")
        case .black: return L10n.t("Flat Black")
        case .white: return L10n.t("Flat White")
        }
    }

    /// Text and marks: white on every look but the white one.
    var ink: Color { self == .white ? .black : .white }
    var nsInk: NSColor { self == .white ? .black : .white }

    /// What it is doing, while it works: Claude's orange where it stands out,
    /// the plain ink where orange would sink into the glass or the white.
    var working: Color {
        switch self {
        case .dark, .black: return ClaudeSpinner.orange
        case .dock: return .white
        case .white: return .black
        }
    }

    /// The pill's fill.
    @ViewBuilder
    func fill<S: Shape>(_ shape: S) -> some View {
        switch self {
        case .dark:
            shape.fill(LinearGradient(colors: [Color.black.opacity(0.92), Color.black.opacity(0.55)],
                                      startPoint: .leading, endPoint: .trailing))
        case .dock:
            shape.fill(Color.black.opacity(0.22))
        case .black:
            shape.fill(Color.black)
        case .white:
            shape.fill(Color.white)
        }
    }

    /// Glass behind the fill — only the looks that are glass.
    var isGlass: Bool { self == .dark || self == .dock }

    var edge: Color {
        switch self {
        case .dark, .black: return .white.opacity(0.12)
        case .dock: return .white.opacity(0.22)
        case .white: return .black.opacity(0.1)
        }
    }
}
