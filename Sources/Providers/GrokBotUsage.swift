import Foundation

/// Turns Grok Bot's cached weekly reading into windows.
///
/// The ring is the weekly allowance — the bar Grok Bot itself labels "Weekly
/// usage". A spend cap, when the account has one, rides along as a second row.
/// Its reset is unknown: the weekly payload carries no timestamp for it, and
/// the monthly summary that would is never written to disk.
enum GrokBotUsage {
    static func windows(from reading: GrokBotReading) -> [LimitWindow] {
        var windows = [LimitWindow(
            id: "weekly",
            label: L10n.t("Weekly usage"),
            usedFraction: reading.percentUsed / 100,
            resetsAt: reading.resetsAt,
            duration: 7 * 86400
        )]
        if let onDemand = reading.onDemand, onDemand.limitCents > 0 {
            windows.append(LimitWindow(
                id: "on_demand",
                label: L10n.t("On demand"),
                usedFraction: onDemand.usedCents / onDemand.limitCents
            ))
        }
        return windows
    }
}
