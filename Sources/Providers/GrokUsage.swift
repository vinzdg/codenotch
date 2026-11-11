import Foundation

/// Parses Grok CLI's billing endpoints, recorded from a live SuperGrok session:
///
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// ```json
/// { "config": {
///     "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
///                        "start": "2026-09-05T08:21:18.802818+00:00",
///                        "end":   "2026-09-12T08:21:18.802818+00:00" },
///     "creditUsagePercent": 8.0,
///     "productUsage": [{ "product": "GrokBuild", "usagePercent": 8.0 }],
///     "billingPeriodStart": "2026-09-05T08:21:18.802818+00:00",
///     "billingPeriodEnd":   "2026-09-12T08:21:18.802818+00:00" } }
/// ```
///
/// The credits payload is the ring: a weekly Grok Build allowance. Grok's own
/// account charge date is not in this response — the unformatted `/billing`
/// payload's `billingPeriodEnd` is a calendar-month usage ledger, not a bill,
/// and nothing here says which day of the month an account is actually
/// charged. Showing one would mean guessing at a fact this endpoint does not
/// state.
enum GrokUsage {
    static func windows(creditsJSON: String) throws -> [LimitWindow] {
        guard let credits = object(creditsJSON)?["config"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []

        let currentPeriod = period(credits["currentPeriod"])
        let currentEnd = date(currentPeriod?["end"])
        let creditsReset = currentEnd ?? date(credits["billingPeriodEnd"])
        let start = currentEnd == nil
            ? date(credits["billingPeriodStart"]) : date(currentPeriod?["start"])
        let duration = start.flatMap { start in creditsReset.map { $0.timeIntervalSince(start) } }

        if let fraction = percent(credits["creditUsagePercent"]) {
            windows.append(LimitWindow(
                id: "credits",
                label: productLabel(credits) ?? L10n.t("Grok Build"),
                usedFraction: fraction,
                resetsAt: creditsReset,
                duration: duration
            ))
        } else if let products = credits["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let fraction = percent(product["usagePercent"]) else { continue }
                let name = (product["product"] as? String).map(humanize) ?? L10n.t("Usage")
                // The ring is declared as `headlineID: "credits"`. Using the
                // wire product name here left a valid bar in the tooltip and
                // a dash on the cell.
                windows.append(LimitWindow(
                    id: windows.isEmpty ? "credits" : ((product["product"] as? String) ?? name),
                    label: name,
                    usedFraction: fraction,
                    resetsAt: creditsReset,
                    duration: duration
                ))
            }
        }

        // A weekly plan pool (X Premium+, SuperGrok) states its window in
        // `currentPeriod` and omits `creditUsagePercent`/`productUsage` until
        // usage lands, so the branches above find nothing on a fresh period.
        // Grok's own `/usage` still shows this as a "Weekly limit" bar at 0%
        // with the period end as the reset, so mirror it rather than reporting
        // the account as unmetered.
        if windows.isEmpty,
           let weekly = period(credits["currentPeriod"]),
           (weekly["type"] as? String).map({ $0.contains("WEEKLY") }) == true {
            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Weekly limit"),
                usedFraction: 0,
                resetsAt: date(weekly["end"]) ?? creditsReset
            ))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("Grok has nothing metered on this account yet"))
        }
        return windows
    }

    private static func productLabel(_ credits: [String: Any]) -> String? {
        guard let products = credits["productUsage"] as? [[String: Any]],
              let name = products.first?["product"] as? String
        else { return nil }
        return humanize(name)
    }

    /// "GrokBuild" → "Grok Build". The wire name is one word; the usage modal
    /// writes two.
    static func humanize(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        return number.doubleValue / 100
    }

    private static func period(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ any: Any?) -> Date? {
        GrokCredentials.date(any)
    }
}
