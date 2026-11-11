import Foundation

/// How plan ceilings are determined across providers.
///
/// In `.hybrid` mode (the default), ceilings are auto-inferred from observed
/// peak usage, while allowing users to explicitly override with a manual ceiling.
/// In `.manual` mode, ceilings only exist when explicitly configured by the user.
/// In `.inferred` mode, ceilings are calculated strictly from observed peak usage.
public enum PlanCeilingMode: String, CaseIterable, Identifiable, Codable {
    case hybrid = "hybrid"
    case manual = "manual"
    case inferred = "inferred"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hybrid:   return L10n.t("Auto with override")
        case .manual:   return L10n.t("Manual only")
        case .inferred: return L10n.t("Auto-inferred")
        }
    }

    public var explanation: String {
        switch self {
        case .hybrid:
            return L10n.t("Infers plan ceilings from peak usage and allows a manual override.")
        case .manual:
            return L10n.t("Uses manual ceiling entries only; no inference from peak usage.")
        case .inferred:
            return L10n.t("Infers plan ceilings strictly from observed peak usage.")
        }
    }
}

/// Helper calculations for inferred plan ceilings and clean increments.
public enum PlanCeiling {
    /// Inferred ceiling from observed peak usage.
    /// Provides 25% headroom over peak, rounded to a clean increment.
    public static func infer(from peak: Int) -> Int {
        guard peak > 0 else { return 0 }
        let scaled = Double(peak) * 1.25
        return roundToCleanIncrement(scaled)
    }

    /// Rounds a target count to a clean, human-friendly number.
    public static func roundToCleanIncrement(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        if value <= 10 { return max(1, Int(ceil(value))) }
        if value <= 50 { return Int(ceil(value / 5.0) * 5) }
        if value <= 100 { return Int(ceil(value / 10.0) * 10) }
        if value <= 500 { return Int(ceil(value / 50.0) * 50) }
        if value <= 1_000 { return Int(ceil(value / 100.0) * 100) }
        if value <= 10_000 { return Int(ceil(value / 1_000.0) * 1_000) }
        if value <= 100_000 { return Int(ceil(value / 10_000.0) * 10_000) }
        if value <= 1_000_000 { return Int(ceil(value / 100_000.0) * 100_000) }
        return Int(ceil(value / 500_000.0) * 500_000)
    }

    /// Formatted display representation for a ceiling count.
    public static func compact(_ count: Int) -> String {
        LimitWindow.compact(count)
    }
}
