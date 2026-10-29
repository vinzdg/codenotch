import Foundation

/// Reads Xiaomi MiMo's Token Plan numbers out of the platform console.
///
/// MiMo's model gateway (`token-plan-*.xiaomimimo.com/v1`) answers only
/// `/models` and `/chat/completions` to a `tp-` key: every usage path there
/// 404s. The plan's real quota lives on the console at
/// `platform.xiaomimimo.com/api/v1/tokenPlan/usage`, authorized by the browser
/// session cookie rather than the key — so, like QianwenAI's, this parser only
/// ever sees the body the site script already mapped onto a status, and a
/// signed-out console becomes 401 before parsing.
///
/// The usage payload (recorded from the platform's own client):
///
/// ```json
/// { "code": 0, "data": {
///     "monthUsage": { "percent": 0.1661,
///                     "items": [{ "name": "month_total_token",
///                                 "used": 265741632, "limit": 1600000000,
///                                 "percent": 0.1661 }] },
///     "usage": { "items": [
///         { "name": "plan_total_token", "used": 14954038035, "limit": 38000000000, "percent": 0.39 },
///         { "name": "compensation_total_token", "used": 0, "limit": 0, "percent": 0 } ] } } }
/// ```
///
/// …and the plan detail, whose `currentPeriodEnd` is the subscription's own
/// reset moment (the period does not end on the 1st):
///
/// ```json
/// { "planCode": "pro", "planName": "Pro",
///   "currentPeriodEnd": "2026-11-05 23:59:59", "expired": false } }
/// ```
///
/// Both readings are written against the shape MiMo's console sends, not
/// against a live session this build could take — the first signed-in probe is
/// what confirms it, and a shape that does not match here fails loudly as
/// `badResponse` rather than drawing a ring from a guess.
enum MiMoUsage {
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let envelope = object(from: json),
              let usageText = envelope["usage"] as? String,
              let usage = object(from: usageText)
        else { throw UsageProviderError.badResponse(status: 0) }

        // The named failure first: a session that just died answers 200 with
        // `code` 401/403 in the body even though the transport was fine, and
        // reading the usage block first would report an unreadable shape where
        // the account is simply signed out.
        if let code = int(usage["code"]), code != 0 {
            if code == 401 || code == 403 || usage["loginUrl"] != nil {
                throw UsageProviderError.needsAuth
            }
            // `message` is the server's own prose: never shown or logged as is
            // (the store logs failures publicly), only a line of our own.
            if name(usage["message"]) != nil || name(usage["msg"]) != nil {
                throw UsageProviderError.apiError(L10n.t("MiMo refused the request."))
            }
            throw UsageProviderError.badResponse(status: 0)
        }

        let payload = usage["data"] as? [String: Any] ?? [:]
        let planBlock = payload["usage"] as? [String: Any] ?? [:]
        let monthBlock = payload["monthUsage"] as? [String: Any] ?? [:]
        let detail = detail(from: envelope["detail"], now: now)

        // The plan-period quota is the ring: the allowance the subscription
        // bought, reset at `currentPeriodEnd` — self-consistent, unlike pairing
        // the calendar-month view with a subscription date. `monthUsage` is the
        // fallback when the plan block is absent.
        let planItem = item(named: "plan_total_token", in: planBlock["items"])
        let monthItem = item(named: "month_total_token", in: monthBlock["items"])
        guard let primary = planItem ?? monthItem,
              let headline = window(
                  id: "month",
                  label: (detail?.planName).map { "\($0) plan" } ?? L10n.t("Token Plan"),
                  item: primary,
                  resetsAt: planItem != nil ? detail?.periodEnd : calendarMonthEnd(now)
              )
        else {
            throw UsageProviderError.nothingMetered(L10n.t("MiMo reported no Token Plan usage"))
        }

        var windows = [headline]

        // Bonus credits bought or granted on top, when the plan reports a real
        // pool. An empty compensation row — `limit` 0, whatever its `percent` —
        // is noise, not a ring, so a positive limit is the gate.
        if let bonus = item(named: "compensation_total_token", in: planBlock["items"]),
           int(bonus["limit"]).map({ $0 > 0 }) == true,
           let extra = window(
               id: "compensation",
               label: L10n.t("Bonus credits"),
               item: bonus,
               resetsAt: planItem != nil ? detail?.periodEnd : calendarMonthEnd(now)
           ) {
            windows.append(extra)
        }

        return windows
    }

    /// A window from one `items` row: the platform states both a 0–1 `percent`
    /// and exact `used`/`limit` counts, so either is a reading. The counts are
    /// preferred — they divide to the same fraction with no scale to guess —
    /// and `percent` is the fallback when a row carries only it.
    private static func window(id: String, label: String, item: [String: Any],
                               resetsAt: Date?) -> LimitWindow? {
        let used = int(item["used"])
        let limit = int(item["limit"])
        var usedFraction = number(item["percent"]).map { min(max($0, 0), 1) }
        if usedFraction == nil, let used, let limit, limit > 0 {
            usedFraction = min(max(Double(used) / Double(limit), 0), 1)
        }
        guard let usedFraction else { return nil }
        var remaining: Int?
        if let used, let limit { remaining = max(0, limit - used) }
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: usedFraction,
            remaining: remaining,
            used: used,
            resetsAt: resetsAt,
            // The cycle length the tooltip's pace line compares elapsed time
            // against (`UsagePace.usagePace`), and 30 days is the convention
            // this repo uses for a monthly window (`KiroUsage.monthlyDuration`,
            // `CodexUsage.label(windowSeconds:)`). The plan's own period is a
            // day-of-month anchor — 28 to 31 days apart — so the comparison is
            // off by at most a few percentage points, and only the pace line
            // reads it: the ring itself is the exact `usedFraction`.
            duration: 30 * 86_400
        )
    }

    /// The subscription's own reset moment, from `/tokenPlan/detail`. The
    /// endpoint is best-effort — an account without one still draws its ring —
    /// so a shape that does not parse yields no reset rather than a failure.
    private struct Detail {
        var planName: String?
        var periodEnd: Date?
    }

    private static func detail(from value: Any?, now: Date) -> Detail? {
        guard let text = value as? String, let body = object(from: text) else { return nil }
        // The detail rides in the same `usage` envelope, so it is unwrapped the
        // same way — one level of `data` when the wrapper is there, the object
        // itself when it is not.
        let payload = (body["data"] as? [String: Any]) ?? body
        let planName = name(payload["planName"])
        let periodEnd = periodEnd(payload["currentPeriodEnd"], now: now)
        guard planName != nil || periodEnd != nil else { return nil }
        return Detail(planName: planName, periodEnd: periodEnd)
    }

    /// `currentPeriodEnd` is a plain `yyyy-MM-dd HH:mm:ss` wall clock, which
    /// carries no offset — the console renders it in the account's own zone, so
    /// this reads it in the local one, the only zone a reader can check it
    /// against. A reset already past is stale data, not a countdown: dropped
    /// rather than drawn as a moment that has happened.
    private static func periodEnd(_ value: Any?, now: Date) -> Date? {
        guard let text = value as? String,
              let date = periodFormatter.date(from: text),
              date > now
        else { return nil }
        return date
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// The calendar-month view's reset, when the plan-period block is absent:
    /// `monthUsage` is a month-to-date reading and has no reset of its own, so
    /// its window closes at the boundary the month actually closes at.
    private static func calendarMonthEnd(_ now: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        return start.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }
    }

    private static func item(named name: String, in value: Any?) -> [String: Any]? {
        (value as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .first { self.name($0["name"]) == name }
    }

    private static func object(from json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// A name has to be text to be worth showing, and an empty one names
    /// nothing — the next fallback gets its turn instead.
    private static func name(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A reading has to be a *finite* number to be one. `Double("nan")` and
    /// `Double("inf")` both parse where the body named neither, and neither is
    /// clamped by the caller's `min(max(…))` — `NaN` passes straight through
    /// it — so such a fraction would satisfy the caller's `guard` and reach
    /// `Percent.text(for:)`/`Percent.halves(for:)`, whose `Int(_: Double)`
    /// conversion aborts the process instead of printing a ring.
    private static func number(_ value: Any?) -> Double? {
        var parsed: Double?
        if let number = value as? NSNumber {
            parsed = number.doubleValue
        } else if let text = value as? String {
            parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Token counts reach the platform as decimal strings as often as numbers,
    /// so both spellings have to count — with the same bounds as
    /// `QianwenUsage.int`, because `Int(_: Double)` aborts the process on an
    /// out-of-range value rather than answering.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) { return value }
        guard let value = Double(trimmed), value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
