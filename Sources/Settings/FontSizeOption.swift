import Foundation
import SwiftUI

/// Configurable font size and typography scaling for legibility on small or high-DPI displays.
enum FontSizeOption: String, CaseIterable, Identifiable {
    case small
    case standard
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    /// Multiplier applied to typography cap-heights.
    var scale: CGFloat {
        switch self {
        case .small:      return 0.85
        case .standard:   return 1.0
        case .medium:     return 1.15
        case .large:      return 1.30
        case .extraLarge: return 1.50
        }
    }

    var title: String {
        switch self {
        case .small:      return L10n.t("Small (85%)")
        case .standard:   return L10n.t("Standard (100%)")
        case .medium:     return L10n.t("Medium (115%)")
        case .large:      return L10n.t("Large (130%)")
        case .extraLarge: return L10n.t("Extra Large (150%)")
        }
    }

    var explanation: String {
        switch self {
        case .small:
            return L10n.t("Compact font size for tight layouts.")
        case .standard:
            return L10n.t("Default design proportions.")
        case .medium:
            return L10n.t("Slightly larger type for improved legibility.")
        case .large:
            return L10n.t("Easier to read on high-resolution and high-DPI displays.")
        case .extraLarge:
            return L10n.t("Maximum legibility for small screens or distant viewing.")
        }
    }
}

private struct TypographyScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var typographyScale: CGFloat {
        get { self[TypographyScaleKey.self] }
        set { self[TypographyScaleKey.self] = newValue }
    }
}
