import Foundation

/// Parses Mistral's `/v1/billing/budget` and `/v1/billing/subscription`
/// responses into standard `LimitWindow` values and plan metadata.
enum MistralUsage {
    static let budgetEndpoint = URL(string: "https://api.mistral.ai/v1/billing/budget")!
    static let subscriptionEndpoint = URL(string: "https://api.mistral.ai/v1/billing/subscription")!
    static let thirtyDays: TimeInterval = 30 * 86_400

    private static let budgetEntries: [(field: String, id: String, label: String)] = [
        ("vibe_budget", "vibe", "Vibe Budget"),
        ("api_budget", "api", "API Budget")
    ]

    /// Parses either `{"vibe_budget": ..., "api_budget": ...}` or a flat
    /// single-budget object. Returns windows sorted by highest usage first
    /// (keeping Vibe ahead of API on ties) so `windows.first` drives the ring.
    static func parseBudgets(_ data: Data) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 200)
        }

        var windows: [LimitWindow] = []
        for entry in budgetEntries {
            if let obj = root[entry.field] as? [String: Any],
               let window = parseBudgetWindow(obj, id: entry.id, name: entry.label) {
                windows.append(window)
            }
        }
        if windows.isEmpty, let flat = parseBudgetWindow(root, id: "api", name: "API Budget") {
            windows.append(flat)
        }

        return windows.enumerated().sorted { lhs, rhs in
            let lUsed = lhs.element.usedFraction ?? 0
            let rUsed = rhs.element.usedFraction ?? 0
            if lUsed != rUsed { return lUsed > rUsed }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func parseBudgetWindow(_ object: [String: Any], id: String, name: String) -> LimitWindow? {
        guard let rawPct = doubleValue(object["usage_percentage"]),
              rawPct.isFinite, rawPct >= 0
        else { return nil }

        let used = min(max(rawPct / 100.0, 0.0), 1.0)
        let initial = doubleValue(object["initial_budget"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let currency = (object["currency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        let label: String
        if let total = initial {
            let spent = formatCurrency(used * total, code: currency)
            let budget = formatCurrency(total, code: currency)
            label = "\(name) (\(spent) / \(budget))"
        } else {
            label = name
        }

        let resetsAt = (object["reset_at"] as? String).flatMap(parseRFC3339)
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: used,
            resetsAt: resetsAt,
            duration: thirtyDays
        )
    }

    /// Formats plan metadata from `/v1/billing/subscription`, e.g. `"Pro · PAYG"` or `"EDU"`.
    static func parseSubscriptionPlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = (root["plan_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty
        else { return nil }

        let payg = (root["vibe_payg_enabled"] as? Bool ?? false)
            || (root["payg_enabled"] as? Bool ?? false)
        return payg ? "\(plan) · PAYG" : plan
    }

    static func formatCurrency(_ amount: Double, code: String?) -> String {
        let formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        switch code?.uppercased() {
        case nil, "USD": return "$\(formatted)"
        case "EUR": return "€\(formatted)"
        case "GBP": return "£\(formatted)"
        case let other?: return "\(other) \(formatted)"
        }
    }

    static func parseRFC3339(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
