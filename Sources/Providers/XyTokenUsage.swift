import Foundation

/// Parses `GET /api/subscription/self` on api.xytoken.xyb2b.com — the call the
/// station's own wallet page makes right after refreshing its session. The
/// page is unreachable to URLSession (the refresh cookie is HttpOnly and
/// rotates on every call), so the fetch runs inside the app's WebView and this
/// type only decodes the response body.
///
/// Shape, pinned from a recorded response:
///
/// ```json
/// { "data": {
///     "subscriptions": [{
///       "quota_limits": [{
///         "rule_key": "day:1|day:00:00", "name": "每日",
///         "amount": 75000000, "amount_used": 4855975, "remaining": 70144025,
///         "window_start": 1788940296, "window_end": 1788969600
///       }, {
///         "rule_key": "week:1|week:MON 00:00", "name": "每周",
///         "amount": 300000000, "amount_used": 4855975, "remaining": 295144025,
///         "window_start": 1788940296, "window_end": 1789315200
///       }]
///     }],
///     "all_subscriptions": [ … same entries plus expired ones … ]
/// } } }
/// ```
///
/// `amount`/`amount_used` are token counts (75M/day, 300M/week in the capture);
/// `window_*` are Unix seconds. Active windows live under `subscriptions`;
/// `all_subscriptions` repeats them alongside expired ones and is only a
/// fallback.
///
/// Window ids are the stable half of `rule_key` — everything before the `|`
/// (`day:1`, `week:1`) — not the whole string. The right half is the reset
/// schedule, and it moves: the week rule reads `week:MON 00:00` for a Monday
/// reset and would read something else for another day. `Sites.xytoken`
/// declares its headline and weekly roles by id, and consumers match those
/// exactly, so an id that carried the schedule would stop resolving the
/// moment the schedule changed — which is how the weekly ring went missing
/// the first time these were declared.
enum XyTokenUsage {
    struct Response: Decodable {
        struct Data: Decodable {
            struct Subscription: Decodable {
                struct QuotaLimit: Decodable {
                    let rule_key: String?
                    let name: String?
                    let amount: Double?
                    let amount_used: Double?
                    let window_end: TimeInterval?
                    let period_value: Double?
                    let period_unit: String?
                }
                let quota_limits: [QuotaLimit]?
            }
            let subscriptions: [Subscription]?
            let all_subscriptions: [Subscription]?
        }
        let data: Data?
    }

    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let raw = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: raw),
              let payload = response.data
        else { throw UsageProviderError.badResponse(status: 0) }

        let active = payload.subscriptions ?? []
        let limits = (active.isEmpty ? payload.all_subscriptions ?? [] : active)
            .flatMap { $0.quota_limits ?? [] }

        var windows: [LimitWindow] = []
        for (index, limit) in limits.enumerated() {
            guard let amount = limit.amount, amount > 0,
                  let used = limit.amount_used else { continue }
            windows.append(LimitWindow(
                id: windowID(fromRuleKey: limit.rule_key, index: index),
                label: limit.name ?? "Limit",
                usedFraction: used / amount,
                resetsAt: limit.window_end.map { Date(timeIntervalSince1970: $0) },
                duration: duration(periodValue: limit.period_value, periodUnit: limit.period_unit)
            ))
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("XyToken has no active quota windows")
        }
        return windows
    }

    /// The window id: the part of `rule_key` before the `|`, which is the
    /// rule's unit and count (`day:1`, `week:1`, `hour:3`) rather than the
    /// schedule after it. See the type comment for why the schedule half is
    /// not kept. A limit that reports no `rule_key` falls back to its position,
    /// which at least stays unique within one response.
    private static func windowID(fromRuleKey ruleKey: String?, index: Int) -> String {
        guard let ruleKey, !ruleKey.isEmpty else { return "limit-\(index)" }
        guard let bar = ruleKey.firstIndex(of: "|") else { return ruleKey }
        return String(ruleKey[ruleKey.startIndex..<bar])
    }

    /// Length of one quota cycle, for the tooltip's pace line.
    ///
    /// Read from the limit's own period rather than from `window_end -
    /// window_start`: in the recorded capture both windows report the same
    /// `window_start`, and the day window's span is 8.14 h — exactly the time
    /// left before midnight at the moment of the call — so that field marks
    /// when the request was made, not when the cycle began. An unknown unit
    /// leaves it nil, which costs only the pace line.
    private static func duration(periodValue: Double?, periodUnit: String?) -> TimeInterval? {
        guard let periodValue, periodValue.isFinite, periodValue > 0,
              let unit = periodUnit?.lowercased() else { return nil }
        switch unit {
        case "hour":  return periodValue * 3600
        case "day":   return periodValue * 86_400
        case "week":  return periodValue * 7 * 86_400
        default:      return nil
        }
    }
}
