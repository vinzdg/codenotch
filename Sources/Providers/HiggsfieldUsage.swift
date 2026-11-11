import Foundation

/// Known monthly credit allowances for Higgsfield subscription tiers.
enum HiggsfieldPlan {
    static let allowances: [String: Double] = [
        "ultra": 3000,
        "plus": 1200,
        "pro": 1200,
        "starter": 250,
        "basic": 150,
        "free": 0
    ]

    static func allowance(for planType: String) -> Double? {
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowances[normalized]
    }
}

/// Parses Higgsfield's workspace listings or account credit responses.
///
/// Accepts:
/// 1. Array of workspace objects from `hf workspace list --json` or
///    `GET https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha/account/workspaces`:
///    ```json
///    [
///      {
///        "id": "ws_123",
///        "name": "Personal",
///        "plan_type": "ultra",
///        "credits": 2777.1,
///        "is_selected": true,
///        "user_role": "owner"
///      }
///    ]
///    ```
/// 2. Dictionary wrapping workspaces: `{ "workspaces": [ ... ] }`
/// 3. Direct account or MCP balance object:
///    `{ "credits": 2777.1, "subscription_plan_type": "ultra" }`
enum HiggsfieldUsage {
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

        let workspaces: [[String: Any]]
        if let array = json as? [[String: Any]] {
            workspaces = array
        } else if let dict = json as? [String: Any] {
            if let array = dict["workspaces"] as? [[String: Any]] {
                workspaces = array
            } else if dict["credits"] != nil || dict["plan_type"] != nil || dict["subscription_plan_type"] != nil {
                workspaces = [dict]
            } else {
                workspaces = []
            }
        } else {
            throw UsageProviderError.badResponse(status: 0)
        }

        guard !workspaces.isEmpty else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Higgsfield workspaces or credits found.")
            )
        }

        // Pick selected workspace if specified, otherwise the first
        let active = workspaces.first(where: { ($0["is_selected"] as? Bool) == true }) ?? workspaces[0]

        guard let creditsNumber = (active["credits"] as? NSNumber)?.doubleValue
                ?? (active["credits"] as? Double) else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Higgsfield credit balance reported.")
            )
        }

        let planType = (active["plan_type"] as? String)
            ?? (active["subscription_plan_type"] as? String)
            ?? (active["plan"] as? String)

        let workspaceName = active["name"] as? String

        let explicitAllowance = (active["credit_limit"] as? NSNumber)?.doubleValue
            ?? (active["allowance"] as? NSNumber)?.doubleValue
            ?? (active["monthly_credits"] as? NSNumber)?.doubleValue

        let allowance = explicitAllowance ?? planType.flatMap { HiggsfieldPlan.allowance(for: $0) }

        let resetDate = date(active["resets_at"] ?? active["reset_at"] ?? active["period_end"] ?? active["reset_date"])

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
            // Plan has no known monthly allowance or is pay-as-you-go: show balance without guessing fraction
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

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
