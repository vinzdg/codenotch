import SwiftUI

/// The colour a ring or bar takes at a given level of use.
///
/// The thresholds come from the mockup, which shows 21% green, 52% yellow and
/// 73% orange. (The prose table in the design spec says 50–79 is yellow, which
/// would make 73% yellow and contradict the frame it claims to describe — the
/// frame wins.)
enum UsageBand: String, Codable, Equatable {
    case ample       // under half
    case watch       // getting close
    case critical    // nearly out
    case exhausted   // limit hit, waiting for the reset

    static func band(for usedFraction: Double, watchLimit: Double = 0.50, criticalLimit: Double = 0.70) -> UsageBand {
        switch usedFraction {
        case ..<watchLimit: return .ample
        case ..<criticalLimit: return .watch
        case ..<1.0: return .critical
        default:      return .exhausted
        }
    }

    /// `accent` only ever stands in for the ample state's colour — the
    /// warning bands stay fixed regardless of the chosen accent, since their
    /// whole job is to interrupt whatever else is on screen and a
    /// customisable warning colour could be tuned into invisibility.
    func color(accent: Color = Palette.ample) -> Color {
        switch self {
        case .ample:                 return accent
        case .watch:                 return Palette.watch
        case .critical, .exhausted:  return Palette.critical
        }
    }

    /// A continuous alternative to `color(accent:)`, spanning the *whole* 0–100% range rather
    /// than only the watch-to-critical band. `watchLimit` is the one interior anchor — the ramp
    /// passes through the palette's exact yellow there — and the two ends are the palette's
    /// exact green and exact red. The second half deliberately runs all the way to 100% instead
    /// of stopping at `criticalLimit`: a ramp confined to the narrow default watch-critical band
    /// (20 points) moves through yellow into orange almost as abruptly as the hard steps it
    /// replaces, which is what sent this back for a second pass.
    ///
    /// One consequence worth being explicit about: `criticalLimit` no longer pins pure red the
    /// way it does for `band(for:)`. Past the watch limit, colour is purely a function of how
    /// far `usedFraction` is from 100%, not of where the critical slider sits. The slider still
    /// does its other job — `band(for:)` and everything that reads `.critical`/`.exhausted` off
    /// it are untouched — it just no longer doubles as a colour knee once the ramp is on.
    ///
    /// A customised accent is not carried into the ramp itself, unlike `color(accent:)`'s ample
    /// case: blending a caller-supplied `Color` per-appearance the way `Palette.ramp` blends its
    /// own hex pairs would need a new resolution path this change did not add. `accent` is kept
    /// as the fallback for a degenerate `watchLimit`, so the parameter still means something.
    static func rampColor(
        for usedFraction: Double,
        watchLimit: Double = 0.50,
        accent: Color = Palette.ample
    ) -> Color {
        let f = min(max(usedFraction, 0), 1)
        guard watchLimit > 0, watchLimit < 1 else { return f < 1 ? accent : Palette.critical }
        if f < watchLimit {
            return Palette.ramp(from: Palette.amplePair, to: Palette.watchPair, fraction: f / watchLimit)
        }
        return Palette.ramp(from: Palette.watchPair, to: Palette.criticalPair, fraction: (f - watchLimit) / (1 - watchLimit))
    }
}

private struct UsageWatchLimitKey: EnvironmentKey {
    static let defaultValue: Double = 0.50
}

private struct UsageCriticalLimitKey: EnvironmentKey {
    static let defaultValue: Double = 0.70
}

extension EnvironmentValues {
    var usageWatchLimit: Double {
        get { self[UsageWatchLimitKey.self] }
        set { self[UsageWatchLimitKey.self] = newValue }
    }

    var usageCriticalLimit: Double {
        get { self[UsageCriticalLimitKey.self] }
        set { self[UsageCriticalLimitKey.self] = newValue }
    }
}
