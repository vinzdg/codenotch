import Foundation

/// How DeepSeek usage is displayed in the notch and menu bar indicators.
public enum DeepSeekDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Shows current remaining credit balance directly (e.g. "¥100.00 left")
    /// without deriving a percentage or depletion color from historical lifetime spend.
    case balance = "balance"
    /// Shows spent percentage of total funded credits across account history (spent / (spent + balance)).
    case lifetimeSpend = "lifetimeSpend"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balance:       return L10n.t("Remaining balance")
        case .lifetimeSpend: return L10n.t("Lifetime spend")
        }
    }

    public var explanation: String {
        switch self {
        case .balance:
            return L10n.t("Shows usable credit left directly (for example, ¥100.00 left) without basing the indicator on historical spending.")
        case .lifetimeSpend:
            return L10n.t("Shows spent share of total funded credits across the account's lifetime.")
        }
    }
}
