import Foundation
import SQLite3

/// kiro-cli's local state and the `GetUsageLimits` CREDIT row.
///
/// The CLI owns the token and its refresh, so the SQLite store is opened
/// read-only and never written. `currentUsageWithPrecision` is the total
/// including overage, so plan usage is that total minus `currentOverages` —
/// feeding the total into the plan gauge would read over 100% and double-count
/// the same spend.
enum KiroLimits {
    struct CreditLimits: Equatable {
        var planUsed: Double
        var planLimit: Double
        var overageUsed: Double
        var overageCap: Double?
        var overageEnabled: Bool?
        var overageCharges: Double?
        var resetAt: Date?
        var hasUnseparatedBonus: Bool
    }

    /// macOS default is `~/Library/Application Support/kiro-cli/data.sqlite3`
    /// or `~/.local/share/kiro-cli/data.sqlite3`.
    /// `KIRO_DATA_DIR` replaces that directory when it is set.
    static func stateDatabaseURL(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = cleanedPath(environment["KIRO_DATA_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("data.sqlite3")
        }
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3"),
            home.appendingPathComponent(".local/share/kiro-cli/data.sqlite3"),
            home.appendingPathComponent(".config/kiro-cli/data.sqlite3")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? candidates[0]
    }

    static func loadAccessToken(from database: URL) -> String? {
        let keys = [
            "kirocli:odic:token",
            "kirocli:social:token",
            "kirocli:external-idp:token"
        ]
        let fields = ["access_token", "accessToken", "token"]
        for key in keys {
            if let token = jsonValue(
                from: database,
                table: "auth_kv",
                key: key,
                fields: fields
            ) {
                return token
            }
        }
        return nil
    }

    static func loadProfileARN(from database: URL) -> String? {
        jsonValue(
            from: database,
            table: "state",
            key: "api.codewhisperer.profile",
            fields: ["arn"]
        )
    }

    /// US East talks to CodeWhisperer; Frankfurt talks to Q. Any other region,
    /// or an ARN that is not `arn:aws:codewhisperer:<region>:<acct>:profile/<name>`,
    /// has no endpoint we can call.
    static func endpoint(forARN arn: String) -> URL? {
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts[0] == "arn",
              parts[1] == "aws",
              parts[2] == "codewhisperer",
              !parts[4].isEmpty,
              parts[5].hasPrefix("profile/"),
              parts[5].count > "profile/".count,
              arn.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        switch parts[3] {
        case "us-east-1":
            return URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")
        case "eu-central-1":
            return URL(string: "https://q.eu-central-1.amazonaws.com/")
        default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> CreditLimits {
        let response: UsageLimitsResponse
        do {
            response = try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        let credits = response.usageBreakdownList.filter { $0.resourceType == "CREDIT" }
        guard let credit = credits.first else {
            throw UsageProviderError.badResponse(status: 0)
        }
        // Two CREDIT rows leave no single authoritative ceiling.
        guard credits.count == 1 else {
            throw UsageProviderError.badResponse(status: 0)
        }

        guard let planLimitRaw = firstNumber(
            credit.usageLimitWithPrecision, credit.usageLimit
        ), let totalRaw = firstNumber(
            credit.currentUsageWithPrecision, credit.currentUsage
        ) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let planLimit = try usable(planLimitRaw)
        let totalUsed = try usable(totalRaw)
        // Prefer the precise overage; the integer field is what some
        // payloads send alone. Defaulting a missing overage to 0 would
        // count overage spend as plan spend.
        let overageUsed = try usable(
            firstNumber(credit.currentOveragesWithPrecision, credit.currentOverages) ?? 0
        )
        guard totalUsed >= overageUsed else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let planUsed = totalUsed - overageUsed
        let hasUnseparatedBonus = !(credit.bonuses ?? []).isEmpty
        // Bonus spend is folded into currentUsage, so planUsed can exceed the plan ceiling.
        if !hasUnseparatedBonus {
            guard planUsed <= planLimit else {
                throw UsageProviderError.badResponse(status: 0)
            }
        }

        let availability = overageAvailability(response.overageConfiguration?.overageStatus)
        let overageCap: Double?
        if availability == true,
           let cap = firstNumber(credit.overageCapWithPrecision, credit.overageCap) {
            overageCap = try usable(cap)
        } else {
            overageCap = nil
        }
        // ENABLED without a cap is incomplete, not disabled.
        let overageEnabled: Bool? = (availability == true && overageCap == nil)
            ? nil
            : availability

        return CreditLimits(
            planUsed: planUsed,
            planLimit: planLimit,
            overageUsed: overageUsed,
            overageCap: overageCap,
            overageEnabled: overageEnabled,
            overageCharges: credit.overageCharges.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            resetAt: resetDate(credit.nextDateReset ?? response.nextDateReset),
            hasUnseparatedBonus: hasUnseparatedBonus
        )
    }

    // MARK: - SQLite

    private static func jsonValue(
        from database: URL,
        table: String,
        key: String,
        fields: [String]
    ) -> String? {
        // `?` / `#` in a URI open would let the path rewrite SQLite's mode=
        // query and take the file read-write — including a token refresh
        // write-back this must never do.
        let path = database.path
        guard path.hasPrefix("/"),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: "?#")) == nil
        else { return nil }
        guard table == "auth_kv" || table == "state" else { return nil }
        guard let db = SQLiteStore.open(database) else { return nil }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, nil) == 1 else { return nil }
        sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        guard let json = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM \(table) WHERE key = ?",
            bind: key
        ).first else { return nil }
        return jsonString(in: json, keys: fields)
    }

    private static func jsonString(in json: String, keys: [String]) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func cleanedPath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    // MARK: - Parse helpers

    private static func overageAvailability(_ status: String?) -> Bool? {
        guard let status, !status.isEmpty else { return nil }
        switch status.uppercased() {
        case "ENABLED": return true
        case "DISABLED": return false
        default: return nil
        }
    }

    private static func firstNumber(_ values: Double?...) -> Double? {
        for value in values {
            if let value { return value }
        }
        return nil
    }

    private static func usable(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return value
    }

    /// Plausible Unix seconds: 2001-09-09 through 2100-01-01. A value outside
    /// this range is a unit change, not a date — milliseconds would land far
    /// beyond any real reset.
    private static let resetRange: ClosedRange<Double> = 1_000_000_000...4_102_444_800

    private static func resetDate(_ value: Double?) -> Date? {
        guard let value, value.isFinite, resetRange.contains(value) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private struct UsageLimitsResponse: Decodable {
        let usageBreakdownList: [UsageBreakdown]
        let overageConfiguration: OverageConfiguration?
        let nextDateReset: Double?
    }

    private struct UsageBreakdown: Decodable {
        let resourceType: String?
        let currentUsageWithPrecision: Double?
        let currentUsage: Double?
        let usageLimitWithPrecision: Double?
        let usageLimit: Double?
        let currentOveragesWithPrecision: Double?
        let currentOverages: Double?
        let overageCapWithPrecision: Double?
        let overageCap: Double?
        let overageCharges: Double?
        let nextDateReset: Double?
        let bonuses: [BonusEntry]?

        struct BonusEntry: Decodable {}
    }

    private struct OverageConfiguration: Decodable {
        let overageStatus: String?
    }
}
