import SwiftUI

/// How a usage ring or bar moves from the ample colour to the critical one.
///
/// Raw values are persistence keys, not display copy. The default is `.hardStep` because a
/// visual change to every existing user's notch must be something they opt into, not something
/// that reaches them unannounced the next time the app updates.
enum ColorTransitionStyle: String, CaseIterable, Identifiable {
    /// The original behaviour: ample, watch and critical are each one flat colour, and the
    /// reading jumps between them at the watch and critical limits.
    case hardStep
    /// `UsageBand.rampColor` — a continuous blend across the whole 0–100% range, turning the
    /// palette's exact yellow at the watch limit on its way from ample to critical.
    case ramp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardStep: return L10n.t("Hard step")
        case .ramp: return L10n.t("Colour ramp")
        }
    }

    var explanation: String {
        switch self {
        case .hardStep:
            return L10n.t("Ample, watch and critical each stay one flat colour, jumping between them at the limits below.")
        case .ramp:
            return L10n.t("The colour blends continuously from ample to critical across the full range, turning yellow at the watch limit below.")
        }
    }
}

private struct ColorTransitionStyleKey: EnvironmentKey {
    static let defaultValue = ColorTransitionStyle.hardStep
}

extension EnvironmentValues {
    var colorTransitionStyle: ColorTransitionStyle {
        get { self[ColorTransitionStyleKey.self] }
        set { self[ColorTransitionStyleKey.self] = newValue }
    }
}
