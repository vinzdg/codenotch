import Foundation

/// Parses `GET https://api.apify.com/v2/users/me/limits` — the documented
/// endpoint behind the Console's Billing page, whose "Custom usage limit" bar
/// draws the same two numbers:
///
/// ```json
/// { "data": { "monthlyUsageCycle": { "startAt": "2026-09-02T00:00:00.000Z",
///                                    "endAt":   "2026-10-01T23:59:59.999Z" },
///             "limits":  { "maxMonthlyUsageUsd": 1500, … },
///             "current": { "monthlyUsageUsd": 1200.6, … } } }
/// ```
///
/// One window: this cycle's platform spend against the cap the account set for
/// itself. The other ceilings under `limits` — compute units, proxy bandwidth,
/// actor counts — are plan sizes rather than the thing that pauses the
/// account, so they stay off the ring rather than invent a second reading
/// nobody budgets by.
enum ApifyUsage {
    static let endpoint = URL(string: "https://api.apify.com/v2/users/me/limits")!
    static let headlineID = "monthly"

    static func windows(from data: Data) throws -> [LimitWindow] {
        // A string where a number should be is not a number, and a negative
        // spend is not a spend: both are the shape changing under us, and
        // "HTTP 0" in the tooltip beats a ring drawn from a guess.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let current = payload["current"] as? [String: Any],
              let used = (current["monthlyUsageUsd"] as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0
        else { throw UsageProviderError.badResponse(status: 0) }

        let cycle = payload["monthlyUsageCycle"] as? [String: Any]
        let start = date(cycle?["startAt"])
        let end = date(cycle?["endAt"])
        let duration = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
            .flatMap { $0 > 0 ? $0 : nil }

        let cap = ((payload["limits"] as? [String: Any])?["maxMonthlyUsageUsd"] as? NSNumber)?.doubleValue
        guard let cap, cap.isFinite, cap > 0 else {
            // No cap set means no share of one — a count row, not a 0% ring.
            return [LimitWindow(
                id: headlineID,
                label: L10n.t("Monthly usage"),
                usedText: money(used),
                detail: L10n.t("\(money(used)) this cycle"),
                resetsAt: end,
                duration: duration
            )]
        }

        // Deliberately not clamped at 1: the platform pauses at the cap, but
        // what Apify reports past it is still the number.
        return [LimitWindow(
            id: headlineID,
            label: L10n.t("Monthly usage"),
            usedFraction: used / cap,
            usedText: money(used),
            detail: L10n.t("\(money(used)) of \(money(cap))"),
            resetsAt: end,
            duration: duration
        )]
    }

    /// "$1,200.60", the way the Console writes it, whatever the Mac's region
    /// puts between the thousands.
    static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "$" + (formatter.string(from: NSNumber(value: value))
                      ?? String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    /// Apify writes `.999Z`; the fractional form is tried first and the plain
    /// one kept for a server that stops sending the milliseconds.
    private static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
