import Foundation

/// Parses Xiaomi MiMo Code (`MimoCode`) API responses, Token Plan quotas, and CLI balance outputs.
enum MimoCodeUsage {
    struct Result: Equatable {
        let windows: [LimitWindow]
        let headlineID: String?
        let planName: String?
        let accountName: String?
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
            return try parseDictionary(dict)
        } else if let array = json as? [[String: Any]], let first = array.first {
            return try parseDictionary(first)
        }

        throw UsageProviderError.badResponse(status: 0)
    }

    private static func parseDictionary(_ dict: [String: Any]) throws -> Result {
        // 1. Check for official Platform Balance response
        // { "object": "balance", "is_available": true, "balance_infos": [ ... ] }
        if let balanceInfos = dict["balance_infos"] as? [[String: Any]], let primary = balanceInfos.first {
            return try parseBalanceInfo(primary, parent: dict)
        }

        // 2. Direct balance dictionary: contains "total_available" or "cash_balance" or "balance_infos"
        if dict["total_available"] != nil || dict["cash_balance"] != nil || dict["balance"] != nil {
            return try parseBalanceInfo(dict, parent: dict)
        }

        // 3. Credits / Token Plan schema
        if let result = tryParseCreditsPlan(dict) {
            return result
        }

        // 4. Nested under "data" or "result"
        if let nested = dict["data"] as? [String: Any] {
            return try parseDictionary(nested)
        }
        if let nested = dict["result"] as? [String: Any] {
            return try parseDictionary(nested)
        }

        throw UsageProviderError.badResponse(status: 0)
    }

    private static func parseBalanceInfo(_ info: [String: Any], parent: [String: Any]) throws -> Result {
        let currency = (info["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "CNY"
        let cash = doubleValue(in: info, keys: ["cash_balance", "cash"]) ?? 0
        let gift = doubleValue(in: info, keys: ["gift_balance", "gift", "bonus_balance", "bonus"]) ?? 0
        let creditLimit = doubleValue(in: info, keys: ["credit_limit", "creditLimit"]) ?? 0
        let creditAvailable = doubleValue(in: info, keys: ["credit_available", "creditAvailable"]) ?? 0

        var totalAvailable = doubleValue(in: info, keys: ["total_available", "totalAvailable", "balance", "available_balance"])
        if totalAvailable == nil {
            let sum = cash + gift + creditAvailable
            if sum > 0 || (cash == 0 && gift == 0 && creditAvailable == 0 && (info["cash_balance"] != nil || info["total_available"] != nil)) {
                totalAvailable = sum
            }
        }

        guard let remaining = totalAvailable else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let creditSpent = max(0, creditLimit - creditAvailable)
        let spent = creditSpent
        let funded = remaining + spent

        let usedFraction: Double
        if funded > 0 {
            usedFraction = min(max(spent / funded, 0), 1)
        } else {
            usedFraction = 0
        }

        let breakdown = UsageMoneyBreakdown(
            currency: currency,
            spent: spent,
            remaining: remaining
        )

        var windows: [LimitWindow] = [
            LimitWindow(
                id: "mimocode-balance",
                label: L10n.t("Balance"),
                usedFraction: usedFraction,
                money: breakdown
            )
        ]

        let symbol = currencySymbol(for: currency)
        if creditLimit > 0 {
            windows.append(LimitWindow(
                id: "mimocode-credit",
                label: L10n.t("Credit limit"),
                detail: "\(symbol)\(formatMoney(creditAvailable)) / \(symbol)\(formatMoney(creditLimit))"
            ))
        }

        if gift > 0 {
            windows.append(LimitWindow(
                id: "mimocode-bonus",
                label: L10n.t("Bonus balance"),
                detail: "\(symbol)\(formatMoney(gift))"
            ))
        }

        let planName = (parent["plan"] as? String)
            ?? (info["plan"] as? String)
            ?? (info["plan_name"] as? String)
        let accountName = (parent["user"] as? String)
            ?? (parent["username"] as? String)
            ?? (parent["account"] as? String)
            ?? (info["user"] as? String)

        return Result(
            windows: windows,
            headlineID: "mimocode-balance",
            planName: planName,
            accountName: accountName
        )
    }

    private static func tryParseCreditsPlan(_ dict: [String: Any]) -> Result? {
        // Look for credits / token counts
        let creditsDict = (dict["credits"] as? [String: Any])
            ?? (dict["token_plan"] as? [String: Any])
            ?? dict

        guard let total = doubleValue(in: creditsDict, keys: ["total_credits", "total", "quota", "allowance"]),
              total > 0 else {
            return nil
        }

        let remaining = doubleValue(in: creditsDict, keys: ["remaining_credits", "remaining", "available"])
        let used = doubleValue(in: creditsDict, keys: ["used_credits", "used", "consumed"])

        let effectiveUsed: Double
        let effectiveRemaining: Double

        if let u = used {
            effectiveUsed = u
            effectiveRemaining = remaining ?? max(0, total - u)
        } else if let r = remaining {
            effectiveRemaining = r
            effectiveUsed = max(0, total - r)
        } else {
            return nil
        }

        let usedFraction = min(max(effectiveUsed / total, 0), 1)

        let window = LimitWindow(
            id: "mimocode-credits",
            label: L10n.t("Credits"),
            usedFraction: usedFraction,
            remaining: Int(effectiveRemaining),
            used: Int(effectiveUsed),
            usedText: "\(Int(effectiveUsed).formatted()) / \(Int(total).formatted())",
            prefersUsedText: true
        )

        let planName = (dict["plan"] as? String)
            ?? (dict["plan_name"] as? String)
            ?? "Token Plan"
        let accountName = (dict["user"] as? String)
            ?? (dict["username"] as? String)

        return Result(
            windows: [window],
            headlineID: "mimocode-credits",
            planName: planName,
            accountName: accountName
        )
    }

    private static func doubleValue(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let val = dict[key] {
                if let num = val as? NSNumber {
                    return num.doubleValue
                }
                if let str = val as? String {
                    let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: ",", with: "")
                    if let d = Double(cleaned) {
                        return d
                    }
                }
            }
        }
        return nil
    }

    private static func currencySymbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return "\(currency) "
        }
    }

    private static func formatMoney(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}
