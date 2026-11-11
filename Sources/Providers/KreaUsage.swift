import Foundation

/// Known compute unit / credit allowances for Krea AI subscription tiers.
enum KreaPlan {
    static let allowances: [String: Double] = [
        "business": 80_000,
        "max": 60_000,
        "pro": 20_000,
        "basic": 5_000,
        "free": 100
    ]

    static func allowance(for planType: String) -> Double? {
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowances[normalized]
    }
}

/// Parses Krea AI compute unit quotas, plan balances, and workspace usage.
///
/// Handles:
/// 1. Official `@krea-ai/cli` (`krea balance --json`) and MCP (`get_balance`) output:
///    ```json
///    {
///      "plan": {
///        "id": "pro",
///        "name": "Pro",
///        "tier": "pro",
///        "billing_period": "monthly",
///        "is_paid": true,
///        "monthly_compute_units": 20000
///      },
///      "compute_units": {
///        "total": 15400,
///        "plan": 15000,
///        "purchased": 400,
///        "free": 0
///      }
///    }
///    ```
/// 2. MCP JSON-RPC envelope (`tools/call` `get_balance`):
///    `{ "jsonrpc": "2.0", "result": { "content": [{ "type": "text", "text": "..." }] }, "id": 1 }`
/// 3. Legacy/workspace array or flat balance object.
enum KreaUsage {
    struct Result {
        let windows: [LimitWindow]
        let headlineID: String?
        let planName: String?
        let workspaceName: String?
    }

    static func parse(_ jsonString: String) throws -> Result {
        guard let data = jsonString.data(using: .utf8) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageProviderError.badResponse(status: 0)
        }

        if let dict = json as? [String: Any] {
            // Unpack MCP JSON-RPC content wrapper if present
            if dict["jsonrpc"] != nil,
               let resultObj = dict["result"] as? [String: Any],
               let content = resultObj["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String,
               let innerData = text.data(using: .utf8) {
                return try parse(innerData)
            }

            // 1. Official schema: { "plan": { ... }, "compute_units": { ... } }
            if let computeUnitsDict = dict["compute_units"] as? [String: Any],
               let totalNumber = number(in: computeUnitsDict, keys: ["total", "compute_units", "remaining"]) {
                return parseOfficialSchema(dict: dict, computeUnitsDict: computeUnitsDict, totalNumber: totalNumber)
            }
        }

        // 2. Legacy / workspace list or flat object
        let workspaces: [[String: Any]]
        if let array = json as? [[String: Any]] {
            workspaces = array
        } else if let dict = json as? [String: Any] {
            if let array = dict["workspaces"] as? [[String: Any]] {
                workspaces = array
            } else if let inner = dict["data"] as? [String: Any] {
                workspaces = [inner]
            } else if hasBalanceFields(dict) {
                workspaces = [dict]
            } else {
                workspaces = []
            }
        } else {
            throw UsageProviderError.badResponse(status: 0)
        }

        guard !workspaces.isEmpty else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Krea workspaces or credits found.")
            )
        }

        let active = workspaces.first(where: { ($0["is_selected"] as? Bool) == true }) ?? workspaces[0]

        // If active workspace contains the nested compute_units object, parse it
        if let computeUnitsDict = active["compute_units"] as? [String: Any],
           let totalNumber = number(in: computeUnitsDict, keys: ["total", "compute_units", "remaining"]) {
            return parseOfficialSchema(dict: active, computeUnitsDict: computeUnitsDict, totalNumber: totalNumber)
        }

        guard let creditsNumber = number(in: active, keys: [
            "compute_units", "computeUnits", "remaining_compute_units", "remainingComputeUnits",
            "credits", "remaining_credits", "remainingCredits", "remaining", "balance", "total"
        ]) else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Krea credit balance reported.")
            )
        }

        let planType = (active["plan_type"] as? String)
            ?? (active["planType"] as? String)
            ?? (active["subscription_plan_type"] as? String)
            ?? (active["subscriptionPlanType"] as? String)
            ?? (active["plan"] as? String)
            ?? (active["tier"] as? String)

        let workspaceName = (active["name"] as? String)
            ?? (active["workspace_name"] as? String)
            ?? (active["workspaceName"] as? String)

        let explicitAllowance = number(in: active, keys: [
            "compute_limit", "computeLimit", "compute_units_limit", "computeUnitsLimit",
            "credit_limit", "creditLimit", "allowance", "monthly_compute_units",
            "monthly_credits", "limit", "total"
        ])

        let allowance = explicitAllowance ?? planType.flatMap { KreaPlan.allowance(for: $0) }

        let resetDate = date(
            active["resets_at"]
            ?? active["resetsAt"]
            ?? active["reset_at"]
            ?? active["resetAt"]
            ?? active["period_end"]
            ?? active["periodEnd"]
            ?? active["reset_date"]
            ?? active["next_reset_at"]
        )

        let roundedCredits = Int(creditsNumber.rounded())
        var windows: [LimitWindow] = []

        if let allowance, allowance > 0 {
            let roundedAllowance = Int(allowance.rounded())
            let usedCredits = max(0, allowance - creditsNumber)
            let usedFraction = min(max(usedCredits / allowance, 0), 1)
            let roundedUsed = max(0, roundedAllowance - roundedCredits)
            let extraCredits = max(0, creditsNumber - allowance)

            let detail: String
            if extraCredits > 0 {
                let roundedExtra = Int(extraCredits.rounded())
                detail = L10n.t("\(roundedCredits) of \(roundedAllowance) · +\(roundedExtra) extra")
            } else {
                detail = L10n.t("\(roundedCredits) of \(roundedAllowance) left")
            }

            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Credits"),
                usedFraction: usedFraction,
                remaining: roundedCredits,
                used: roundedUsed,
                detail: detail,
                resetsAt: resetDate
            ))

            if extraCredits > 0 {
                let roundedExtra = Int(extraCredits.rounded())
                windows.append(LimitWindow(
                    id: "extra_credits",
                    label: L10n.t("Extra credits"),
                    used: roundedExtra,
                    detail: "\(roundedExtra)",
                    resetsAt: resetDate
                ))
            }
        } else {
            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Credits"),
                remaining: roundedCredits,
                detail: L10n.t("\(roundedCredits) credits left"),
                resetsAt: resetDate
            ))
        }

        return Result(
            windows: windows,
            headlineID: "credits",
            planName: planType?.capitalized,
            workspaceName: workspaceName
        )
    }

    private static func parseOfficialSchema(
        dict: [String: Any],
        computeUnitsDict: [String: Any],
        totalNumber: Double
    ) -> Result {
        let planDict = dict["plan"] as? [String: Any]
        let planName = (planDict?["name"] as? String)
            ?? (planDict?["tier"] as? String)?.capitalized
            ?? (planDict?["id"] as? String)?.capitalized
            ?? (dict["plan"] as? String)?.capitalized

        let planRemaining = number(in: computeUnitsDict, keys: ["plan"]) ?? totalNumber
        let purchased = number(in: computeUnitsDict, keys: ["purchased"]) ?? 0

        let explicitAllowance = number(in: planDict ?? [:], keys: ["monthly_compute_units", "allowance", "limit"])
            ?? planName.flatMap { KreaPlan.allowance(for: $0) }

        let resetDate = date(
            dict["resets_at"]
            ?? dict["resetsAt"]
            ?? planDict?["resets_at"]
            ?? planDict?["period_end"]
        )

        let roundedTotal = Int(totalNumber.rounded())
        var windows: [LimitWindow] = []

        if let allowance = explicitAllowance, allowance > 0 {
            let roundedAllowance = Int(allowance.rounded())
            let usedCredits = max(0, allowance - planRemaining)
            let usedFraction = min(max(usedCredits / allowance, 0), 1)
            let roundedUsed = max(0, roundedAllowance - Int(planRemaining.rounded()))

            let detail: String
            let roundedPurchased = Int(purchased.rounded())
            if roundedPurchased > 0 {
                detail = L10n.t("\(roundedTotal) of \(roundedAllowance) · +\(roundedPurchased) extra")
            } else {
                detail = L10n.t("\(roundedTotal) of \(roundedAllowance) left")
            }

            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Credits"),
                usedFraction: usedFraction,
                remaining: roundedTotal,
                used: roundedUsed,
                detail: detail,
                resetsAt: resetDate
            ))

            if roundedPurchased > 0 {
                windows.append(LimitWindow(
                    id: "extra_credits",
                    label: L10n.t("Extra credits"),
                    used: roundedPurchased,
                    detail: "\(roundedPurchased)",
                    resetsAt: resetDate
                ))
            }
        } else {
            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Credits"),
                remaining: roundedTotal,
                detail: L10n.t("\(roundedTotal) credits left"),
                resetsAt: resetDate
            ))
        }

        let workspaceName = (dict["name"] as? String)
            ?? (dict["workspace_name"] as? String)

        return Result(
            windows: windows,
            headlineID: "credits",
            planName: planName,
            workspaceName: workspaceName
        )
    }

    private static func hasBalanceFields(_ dict: [String: Any]) -> Bool {
        let keys = [
            "compute_units", "computeUnits", "remaining_compute_units", "remainingComputeUnits",
            "credits", "remaining_credits", "remainingCredits", "remaining", "balance",
            "plan_type", "planType", "subscription_plan_type", "subscriptionPlanType", "plan", "tier"
        ]
        return keys.contains { dict[$0] != nil }
    }

    private static func number(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let num = (dict[key] as? NSNumber)?.doubleValue ?? (dict[key] as? Double),
               num.isFinite {
                return num
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
