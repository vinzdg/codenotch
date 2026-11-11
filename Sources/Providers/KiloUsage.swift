import Foundation

/// Parses Kilo's cloud answers: the coding-plan usage tRPC procedure, and the
/// REST `/api/profile/balance` next to it. Both are the endpoints the Kilo CLI
/// itself asks, so the numbers are the dashboard's own.
enum KiloUsage {
    /// The tRPC procedures, under `https://api.kilo.ai/api/trpc/`.
    static let subscriptionsProcedure = "codingPlans.listSubscriptions"
    static let usageProcedure = "codingPlans.getUsage"
    static let balancePath = "api/profile/balance"

    /// A tRPC GET answers `{"result":{"data":{"json":…}}}` — the envelope the
    /// CLI unwraps before validating. Errors arrive as `{"error":…}` with an
    /// HTTP 200, which must not be read as data.
    static func unwrap(json: String) throws -> Any {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }
        if root["error"] != nil { throw UsageProviderError.apiError(L10n.t("Kilo Cloud rejected the request")) }
        guard let result = root["result"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }
        if let data = result["data"] as? [String: Any], let payload = data["json"] {
            return payload
        }
        // Older tRPC answers put the payload straight under `data`.
        if let payload = result["data"] { return payload }
        throw UsageProviderError.badResponse(status: 0)
    }

    // MARK: Subscriptions

    struct Subscription {
        let id: String
        let planName: String
        let providerName: String
        /// Active and past-due plans meter; a cancelled one has stopped.
        let meters: Bool
    }

    static func subscriptions(fromJSON json: String) throws -> [Subscription] {
        let payload = try unwrap(json: json)
        guard let list = payload as? [[String: Any]] else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String,
                  let planName = item["planName"] as? String
            else { return nil }
            let status = item["status"] as? String
            return Subscription(
                id: id,
                planName: planName,
                providerName: (item["providerName"] as? String) ?? "Kilo",
                meters: status == "active" || status == "past_due"
            )
        }
    }

    // MARK: Usage windows

    /// The windows of one plan's quota answer.
    ///
    /// `remainingPercent` is what is *left* — the inverse of what a ring
    /// draws — so every window comes out inverted, and `resetsAt` carries the
    /// ISO stamp with milliseconds the plain formatter refuses. The period
    /// gives the bar's exact length without any guessing from the id, which
    /// the backend keeps as an opaque slug.
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        let payload = try unwrap(json: json)
        guard let body = payload as? [String: Any],
              let subscription = body["subscription"] as? [String: Any],
              let entries = subscription["windows"] as? [[String: Any]]
        else { throw UsageProviderError.badResponse(status: 0) }

        let out = entries.compactMap { entry -> LimitWindow? in
            guard let id = entry["id"] as? String,
                  let remaining = (entry["remainingPercent"] as? NSNumber)?.doubleValue
            else { return nil }
            let resetsAt = (entry["resetsAt"] as? String).flatMap(date(from:))
            let fraction = 1 - remaining / 100
            // The headline ring means the shortest window — the one a coding
            // session runs into first — and the id is opaque, so the period is
            // what orders them.
            let hours = periodHours(entry["period"] as? [String: Any])
            return LimitWindow(
                id: id,
                label: label(for: entry, hours: hours),
                usedFraction: min(max(fraction, 0), 1),
                resetsAt: resetsAt,
                duration: hours.map { $0 * 3600 }
            )
        }
        guard !out.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return out.sorted { ($0.duration ?? .greatestFiniteMagnitude) < ($1.duration ?? .greatestFiniteMagnitude) }
    }

    /// `headlineID` names the shortest window in `windows(fromJSON:)`'s order.
    static func headlineID(in windows: [LimitWindow]) -> String? {
        windows.first?.id
    }

    /// A five-hour coding window reads "5h limit", a month "Monthly quota" —
    /// the same words the Kilo dashboard prints, from the period the server
    /// sent rather than from a guessed unit.
    private static func label(for entry: [String: Any], hours: Double?) -> String {
        switch hours {
        case 1:      return L10n.t("Hourly limit")
        case 24:     return L10n.t("Daily limit")
        case 168:    return L10n.t("Weekly limit")
        case 720:    return L10n.t("Monthly limit")
        case .some(let h) where h > 0:
            return L10n.t("\(Int(h))h limit")
        default:
            return L10n.t("Plan limit")
        }
    }

    private static func periodHours(_ period: [String: Any]?) -> Double? {
        guard let period,
              let value = (period["value"] as? NSNumber)?.doubleValue, value > 0
        else { return nil }
        switch period["unit"] as? String {
        case "hour":  return value
        case "day":   return value * 24
        case "week":  return value * 7 * 24
        case "month": return value * 30 * 24
        default:      return nil
        }
    }

    private static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }

    // MARK: Balance

    /// `GET /api/profile/balance` answers `{"balance": 14.28…}` — the account's
    /// unspent credit in dollars. A pay-as-you-go account has no plan windows,
    /// so this count-up row is its whole reading. A zero balance is no
    /// reading either: an account with no plan and no credit has nothing to
    /// show only when the endpoint omits a balance; a measured zero remains a
    /// real reading and is rendered as "$0.00".
    static func balanceWindow(fromJSON json: String) -> LimitWindow? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = (root["balance"] as? NSNumber)?.doubleValue
        else { return nil }
        let formatted = String(format: "$%.2f", balance)
        return LimitWindow(
            id: "balance",
            label: L10n.t("Credit balance"),
            used: 0,
            usedText: formatted,
            detail: L10n.t("\(formatted) left"),
            prefersUsedText: true
        )
    }
}
