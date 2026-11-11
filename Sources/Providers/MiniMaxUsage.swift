import Foundation

/// Parses MiniMax Coding Plan and Token Plan remains JSON.
///
/// `GET /v1/api/openplatform/coding_plan/remains` and `GET /v1/token_plan/remains`
/// share one `model_remains` array. Coding Plan meters prompt counts over a
/// rolling ~5-hour interval; Token Plan answers the same keys as remaining
/// percent. Errors ride in under HTTP 200 inside `base_resp`, the way Z.ai's
/// monitor does:
///
/// ```json
/// { "base_resp": { "status_code": 0 },
///   "current_subscribe_title": "Max",
///   "model_remains": [
///     { "model_name": "general",
///       "current_interval_total_count": 1000,
///       "current_interval_usage_count": 250,
///       "start_time": 1700000000000, "end_time": 1700018000000 } ] }
/// ```
///
/// `current_interval_usage_count` and `current_weekly_usage_count` are
/// remaining, not used — used is `total - remaining`. Token Plan rows often
/// leave both counts at 0 and put the reading in
/// `*_remaining_percent`; used percent is `100 - remaining`.
enum MiniMaxUsage {
    struct Reading {
        var plan: String?
        var windows: [LimitWindow]
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Reading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let payload = unwrap(root)
        if let failure = envelopeFailure(in: root, payload: payload) { throw failure }

        let windows = windows(in: payload, now: now)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("MiniMax reported no usage windows"))
        }
        return Reading(plan: planName(in: payload), windows: windows)
    }

    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        try parse(Data(json.utf8), now: now).windows
    }

    /// `data` is the payload when present; plan name and `model_remains` live
    /// in either the wrapper or the inner object, so the inner keys win and
    /// the outer ones fill gaps.
    private static func unwrap(_ root: [String: Any]) -> [String: Any] {
        guard let inner = root["data"] as? [String: Any] else { return root }
        var merged = root
        for (key, value) in inner { merged[key] = value }
        if merged["base_resp"] == nil { merged["base_resp"] = root["base_resp"] }
        return merged
    }

    /// Non-zero `base_resp.status_code` is a business error, not a transport
    /// one — HTTP 200 with `1004` is a missing cookie, not a successful empty
    /// reading. Inner `data.base_resp` can be `{status_code:0}` while the
    /// wrapper still carries 1004, so both envelopes are read and auth wins.
    private static func envelopeFailure(in root: [String: Any],
                                        payload: [String: Any]) -> UsageProviderError? {
        var fallback: UsageProviderError?
        for resp in [payload["base_resp"] as? [String: Any], root["base_resp"] as? [String: Any]] {
            guard let resp,
                  let code = int(resp["status_code"]) ?? int(resp["code"]),
                  code != 0, code != 200
            else { continue }
            let message = (string(resp["status_msg"]) ?? string(resp["msg"]))?.lowercased() ?? ""
            if isAuthFailure(code: code, message: message) { return .needsAuth }
            if fallback == nil { fallback = .badResponse(status: code) }
        }
        return fallback
    }

    private static func isAuthFailure(code: Int, message: String) -> Bool {
        if code == 1004 || code == 401 || code == 403 { return true }
        return message.contains("cookie")
            || message.contains("log in")
            || message.contains("login")
            || message.contains("unauthorized")
    }

    private static func planName(in payload: [String: Any]) -> String? {
        for key in ["current_subscribe_title", "plan_name", "combo_title"] {
            if let name = string(payload[key]) { return name }
        }
        return nil
    }

    private static func windows(in payload: [String: Any], now: Date) -> [LimitWindow] {
        let lanes = (payload["model_remains"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for lane in lanes.sorted(by: Self.laneOrder) {
            // Video / speech / image schema rows are not the coding ring, even
            // when they sit first and report 100% remaining.
            guard isTextLane(string(lane["model_name"])) else { continue }
            var out: [LimitWindow] = []
            if let session = window(
                id: "session", label: L10n.t("5h limit"),
                defaultDuration: 5 * 3600,
                meter: meter(lane, weekly: false),
                weekly: false, now: now)
            {
                out.append(session)
            }
            if let weekly = window(
                id: "weekly", label: L10n.t("Weekly limit"),
                defaultDuration: 7 * 86400,
                meter: meter(lane, weekly: true),
                weekly: true, now: now)
            {
                out.append(weekly)
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    /// General first so a video placeholder sitting at the head of
    /// `model_remains` cannot become the ring.
    private static func laneOrder(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        func rank(_ lane: [String: Any]) -> Int {
            let name = string(lane["model_name"])?.lowercased() ?? ""
            if name == "general" { return 0 }
            if isTextLane(name) { return 1 }
            return 2
        }
        return rank(a) < rank(b)
    }

    /// Unnamed remains are the coding-plan text quota — older answers omit
    /// `model_name`. Video / speech / image names are not.
    private static func isTextLane(_ name: String?) -> Bool {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return true }
        let name = raw.lowercased()
        return name == "general"
            || name == "text generation"
            || name == "text-generation"
            || name.contains("minimax-m")
            || name.hasPrefix("m2.")
    }

    private struct Meter {
        let total: Int?
        let remaining: Int?
        let remainingPercent: Double?
        let status: Int?
        let start: Double?
        let end: Double?
        let remainsTime: Double?
        let boostPermill: Int?
    }

    private static func meter(_ lane: [String: Any], weekly: Bool) -> Meter {
        if weekly {
            return Meter(
                total: int(lane["current_weekly_total_count"]),
                remaining: int(lane["current_weekly_usage_count"]),
                remainingPercent: number(lane["current_weekly_remaining_percent"]),
                status: int(lane["current_weekly_status"]),
                start: number(lane["weekly_start_time"]),
                end: number(lane["weekly_end_time"]),
                remainsTime: number(lane["weekly_remains_time"]),
                boostPermill: int(lane["weekly_boost_permill"])
                    ?? int(lane["weekly_boost_permille"])
            )
        }
        return Meter(
            total: int(lane["current_interval_total_count"]),
            remaining: int(lane["current_interval_usage_count"]),
            remainingPercent: number(lane["current_interval_remaining_percent"]),
            status: int(lane["current_interval_status"]),
            start: number(lane["start_time"]),
            end: number(lane["end_time"]),
            remainsTime: number(lane["remains_time"]),
            boostPermill: int(lane["interval_boost_permill"])
                ?? int(lane["interval_boost_permille"])
        )
    }

    private static func window(id: String, label: String, defaultDuration: TimeInterval,
                               meter: Meter, weekly: Bool, now: Date) -> LimitWindow? {
        let unlimited = isUnlimitedWeekly(meter, weekly: weekly)
        // Status 3 with zeros and 100% remaining is a schema row, not a quota
        // — Token Plan Plus answers a video lane this way. Unlimited weekly
        // on general / Text Generation is the one status-3 reading that is
        // real.
        if !unlimited, isPlaceholder(meter) { return nil }

        let duration = Self.duration(start: meter.start, end: meter.end) ?? defaultDuration
        let resetsAt = unlimited ? nil : reset(end: meter.end, remains: meter.remainsTime, now: now)

        if unlimited {
            return LimitWindow(id: id, label: label, usedFraction: 0,
                               resetsAt: nil, duration: duration)
        }

        if let remainingPercent = meter.remainingPercent {
            // Remaining can exceed 100 when a boost is active; a negative
            // used-fraction would draw as an empty ring of leftover quota.
            let usedFraction = max(0, (100 - remainingPercent) / 100)
            let scaled = scaledCounts(usedFraction: usedFraction, boostPermill: meter.boostPermill)
            return LimitWindow(
                id: id, label: label, usedFraction: usedFraction,
                remaining: scaled?.remaining, used: scaled?.used,
                resetsAt: resetsAt, duration: duration
            )
        }

        guard let total = meter.total, total > 0, let remaining = meter.remaining else { return nil }
        let used = max(0, total - remaining)
        return LimitWindow(
            id: id, label: label,
            usedFraction: Double(used) / Double(total),
            remaining: remaining, used: used,
            resetsAt: resetsAt, duration: duration
        )
    }

    private static func isPlaceholder(_ meter: Meter) -> Bool {
        meter.status == 3
            && (meter.total ?? 0) == 0
            && (meter.remaining ?? 0) == 0
            && (meter.remainingPercent.map { $0 >= 100 } ?? false)
    }

    private static func isUnlimitedWeekly(_ meter: Meter, weekly: Bool) -> Bool {
        weekly && meter.status == 3
            && (meter.remainingPercent.map { $0 >= 100 } ?? false)
    }

    /// `interval_boost_permill` 2000 is a 200-unit bar (permill / 10). No
    /// boost means no count to invent — the fraction already came from
    /// remaining percent.
    private static func scaledCounts(usedFraction: Double, boostPermill: Int?) -> (used: Int, remaining: Int)? {
        guard let boostPermill, boostPermill > 0 else { return nil }
        let limit = max(1, Int((Double(boostPermill) / 10).rounded()))
        let used = Int((usedFraction * Double(limit)).rounded())
        return (used, max(0, limit - used))
    }

    private static func duration(start: Double?, end: Double?) -> TimeInterval? {
        guard let start = date(fromEpoch: start), let end = date(fromEpoch: end) else { return nil }
        let length = end.timeIntervalSince(start)
        return length > 0 ? length : nil
    }

    /// `end_time` is an epoch (ms past 1e12, seconds past 1e9). A past end is
    /// stale — fall through to `remains_time`, which is always a millisecond
    /// duration, not an epoch. Values under 1e6 ms are the last minutes of a
    /// 5h window, not seconds.
    private static func reset(end: Double?, remains: Double?, now: Date) -> Date? {
        if let end = date(fromEpoch: end), end > now { return end }
        guard let remains, remains > 0 else { return nil }
        return now.addingTimeInterval(remains / 1000)
    }

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value, value > 1_000_000_000 else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    /// A reading has to be a *finite* number to be one. `Double("nan")` and
    /// `Double("-inf")` both parse where the body said neither, and the
    /// caller's `max(0, (100 - remaining) / 100)` is not a finiteness check:
    /// `max` answers its *first* argument when the comparison is false, so an
    /// ordering that happens to swallow `NaN` when `0` comes first still lets
    /// `-inf` through as a `+inf` fraction, which reaches
    /// `Percent.text(for:)`/`Percent.halves(for:)` and aborts the process on
    /// `Int(_: Double)` instead of drawing a ring. The `NSNumber` path needs
    /// the guard too: `JSONSerialization` answers `-1e400` with an `NSNumber`
    /// carrying `-infinity` rather than refusing it. `date(fromEpoch:)` reads
    /// through here as well, where a non-finite epoch would be a reset that is
    /// not one.
    private static func number(_ any: Any?) -> Double? {
        var parsed: Double?
        if let number = any as? NSNumber {
            parsed = number.doubleValue
        } else if let text = any as? String {
            parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Both paths need a bound. `Int("1e30")` fails where `Double("1e30")`
    /// succeeds, and `Int(_: Double)` aborts the process on that value rather
    /// than answering — the same trap `"1e400"` and `"nan"` reach. And while
    /// `NSNumber.intValue` saturates instead of aborting, a saturated count is
    /// both invented and dangerous: `Int.min` reaches `total - remaining` and
    /// traps there instead.
    private static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber {
            // `intValue` saturates rather than aborting, which is worse here than
            // aborting would be: `-1e400` arrives from JSONSerialization as a
            // non-finite NSNumber, saturates to `Int.min`, and the caller's
            // `total - remaining` then traps on overflow. A count nobody can
            // represent is not a count.
            let value = number.doubleValue
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return number.intValue
        }
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) { return value }
        guard let value = Double(trimmed), value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func string(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
