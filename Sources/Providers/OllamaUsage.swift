import Foundation

/// Parses Ollama's `GET /api/usage` response.
///
/// **Cloud usage (totals & buckets)** — when limits are not returned:
///
/// ```json
/// { "range": "7d",
///   "scope": "self",
///   "granularity": "day",
///   "from": "2026-10-01T00:00:00Z",
///   "until": "2026-10-08T18:59:58Z",
///   "totals": {
///     "request_count": 6912,
///     "usage_usd": 0.01718,
///     "input_tokens": 106000,
///     "output_tokens": 13600
///   },
///   "buckets": [
///     { "from": "2026-10-01T00:00:00Z", "until": "2026-10-02T00:00:00Z", "request_count": 895 }
///   ] }
/// ```
///
/// **Modern plans** (Pro 20/60/100/500) return a single monthly window:
///
/// ```json
/// { "activity": {
///     "cost": "0.00000",
///     "period": { "type": "last_4_weeks",
///                 "starting_at": "2026-08-17T00:00:00Z",
///                 "ending_at": "2026-09-08T08:28:05Z" } },
///   "limits": {
///     "monthly": {
///       "usage": 0.152,
///       "models": [ { "name": "glm-5.3", "request_count": 468 }, ... ] } } }
/// ```
///
/// `usage` is a **fraction of the plan's monthly allowance** — 0.152 means
/// 15.2% — not dollars. The plan tier (20/60/100/500) sets the dollar ceiling,
/// but the fraction is the same number the ring needs regardless of tier.
///
/// **Legacy plans** return `session` and `weekly` windows instead:
///
/// ```json
/// { "limits": {
///     "session": { "usage": 0.12, "models": [...] },
///     "weekly":  { "usage": 0.41, "models": [...] } },
///   "activity": { "cost": "0.10", "period": { "type": "last_4_weeks" } } }
/// ```
///
/// Legacy responses carry no `ending_at`, so their reset date is unknown.
enum OllamaUsage {
    /// The parsed result: the windows to show and which one the ring means.
    struct Result {
        let windows: [LimitWindow]
        let headlineID: String?
    }

    static func parse(_ json: String) throws -> Result {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let limits = root["limits"] as? [String: Any] ?? [:]
        let activity = root["activity"] as? [String: Any] ?? [:]
        let period = activity["period"] as? [String: Any] ?? [:]
        // The API exposes only rolling activity windows (e.g. 4 weeks or range=7d).
        // It does not expose the billing cycle start or reset date, so the window
        // carries no `resetsAt` — showing one would be a guess.
        let start = date(period["starting_at"]) ?? date(root["from"])
        let end = date(period["ending_at"]) ?? date(root["until"])
        let duration = start.flatMap { s in end.map { e in e.timeIntervalSince(s) } }
            .flatMap { $0 > 0 ? $0 : nil }

        var windows: [LimitWindow] = []
        var headlineID: String?

        // Modern: a single monthly window with a usage fraction.
        if let monthly = limits["monthly"] as? [String: Any] {
            let usage = (monthly["usage"] as? NSNumber)?.doubleValue ?? (monthly["usage"] as? Double)
            if let usage, usage > 0 {
                windows.append(LimitWindow(
                    id: "monthly", label: L10n.t("Monthly usage"),
                    usedFraction: usage, resetsAt: nil, duration: duration
                ))
                headlineID = "monthly"
            }
            windows.append(contentsOf: models(from: monthly, prefix: "monthly"))
        }

        // Legacy: session and weekly windows, each with its own fraction.
        if let session = limits["session"] as? [String: Any] {
            let usage = (session["usage"] as? NSNumber)?.doubleValue ?? (session["usage"] as? Double)
            if let usage, usage > 0 {
                windows.append(LimitWindow(
                    id: "session", label: L10n.t("Session usage"),
                    usedFraction: usage, resetsAt: nil, duration: duration
                ))
                if headlineID == nil { headlineID = "session" }
            }
            windows.append(contentsOf: models(from: session, prefix: "session"))
        }

        if let weekly = limits["weekly"] as? [String: Any] {
            let usage = (weekly["usage"] as? NSNumber)?.doubleValue ?? (weekly["usage"] as? Double)
            if let usage, usage > 0 {
                windows.append(LimitWindow(
                    id: "weekly", label: L10n.t("Weekly usage"),
                    usedFraction: usage, resetsAt: nil, duration: duration
                ))
                // Weekly is the better headline than session for legacy plans.
                headlineID = "weekly"
            }
            windows.append(contentsOf: models(from: weekly, prefix: "weekly"))
        }

        // Cloud totals: usage responses without limits (totals request count, cost, tokens).
        if let totals = root["totals"] as? [String: Any] {
            let requestCount = (totals["request_count"] as? NSNumber)?.intValue
                ?? (totals["request_count"] as? Int)
            let usageUSD = (totals["usage_usd"] as? NSNumber)?.doubleValue
                ?? (totals["usage_usd"] as? Double)
            let inputTokens = (totals["input_tokens"] as? NSNumber)?.intValue
                ?? (totals["input_tokens"] as? Int)
            let outputTokens = (totals["output_tokens"] as? NSNumber)?.intValue
                ?? (totals["output_tokens"] as? Int)

            let range = (root["range"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestsLabel: String
            if let range, !range.isEmpty {
                requestsLabel = "\(L10n.t("Requests")) (\(range))"
            } else {
                requestsLabel = L10n.t("Requests")
            }

            if let count = requestCount, count > 0 {
                windows.append(LimitWindow(
                    id: "requests", label: requestsLabel,
                    used: count, resetsAt: nil, duration: duration
                ))
                if headlineID == nil { headlineID = "requests" }
            }

            if let cost = usageUSD, cost > 0 {
                windows.append(LimitWindow(
                    id: "cost", label: L10n.t("Cost"),
                    usedText: money(cost), detail: money(cost),
                    resetsAt: nil, duration: duration
                ))
                if headlineID == nil { headlineID = "cost" }
            }

            let totalTokens = (inputTokens ?? 0) + (outputTokens ?? 0)
            if totalTokens > 0 {
                windows.append(LimitWindow(
                    id: "tokens", label: L10n.t("Tokens"),
                    used: totalTokens, resetsAt: nil, duration: duration
                ))
            }

            windows.append(contentsOf: models(from: totals, prefix: "totals"))
        } else if let buckets = root["buckets"] as? [[String: Any]], !buckets.isEmpty {
            let bucketRequests = buckets.compactMap {
                ($0["request_count"] as? NSNumber)?.intValue ?? ($0["request_count"] as? Int)
            }.reduce(0, +)
            if bucketRequests > 0 {
                let range = (root["range"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let requestsLabel: String
                if let range, !range.isEmpty {
                    requestsLabel = "\(L10n.t("Requests")) (\(range))"
                } else {
                    requestsLabel = L10n.t("Requests")
                }
                windows.append(LimitWindow(
                    id: "requests", label: requestsLabel,
                    used: bucketRequests, resetsAt: nil, duration: duration
                ))
                if headlineID == nil { headlineID = "requests" }
            }
        }

        // Top-level or activity-level models if present. The cloud summary can
        // name the same model in more than one of these places, so a model
        // already listed by the totals is not listed again.
        for source in [models(from: root, prefix: "root"), models(from: activity, prefix: "activity")] {
            for model in source where !windows.contains(where: { $0.id.hasSuffix(".\(model.label)") }) {
                windows.append(model)
            }
        }

        // Bucket-level models aggregated by name if present.
        if let buckets = root["buckets"] as? [[String: Any]] {
            var modelCounts: [String: Int] = [:]
            for bucket in buckets {
                if let bucketModels = bucket["models"] as? [[String: Any]] {
                    for m in bucketModels {
                        if let name = m["name"] as? String,
                           let count = (m["request_count"] as? NSNumber)?.intValue ?? (m["request_count"] as? Int),
                           count > 0 {
                            modelCounts[name, default: 0] += count
                        }
                    }
                }
            }
            for (name, count) in modelCounts.sorted(by: { $0.key < $1.key }) {
                if !windows.contains(where: { $0.id.hasSuffix(".\(name)") }) {
                    windows.append(LimitWindow(
                        id: "models.\(name)", label: name,
                        used: count, resetsAt: nil
                    ))
                }
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Ollama usage recorded yet for this period.")
            )
        }

        return Result(windows: windows, headlineID: headlineID)
    }

    /// Per-model request counts as individual windows, so each model gets its
    /// own row in the tooltip. Returns an empty array when there are no models
    /// or all have zero requests.
    private static func models(
        from container: [String: Any], prefix: String
    ) -> [LimitWindow] {
        guard let models = container["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String,
                  let count = (model["request_count"] as? NSNumber)?.intValue
                    ?? (model["request_count"] as? Int),
                  count > 0
            else { return nil }
            return LimitWindow(
                id: "\(prefix).\(name)", label: name,
                used: count, resetsAt: nil
            )
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    private static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = value < 0.01 && value > 0 ? 4 : 2
        return "$" + (formatter.string(from: NSNumber(value: value))
                      ?? String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))
    }
}
