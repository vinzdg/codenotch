import Foundation

/// Reads the QianwenAI Token Plan (个人版) numbers out of the platform
/// console's own gateway response.
///
/// The platform publishes model-call APIs but no usage API: the Token Plan is
/// only readable through the console's own RPC gateway, one POST per read to
/// `cs-data.qianwenai.com/data/api.json`, with the session riding in cookies.
/// So this parser only ever sees the body the site script already mapped onto a
/// status — a signed-out console answers HTTP 200 with
/// `{"code":"ConsoleNeedLogin"}`, the site script turns *that* into 401, and
/// `WebSessionProvider` turns *that* into `needsAuth` before parsing.
///
/// A *business* failure is also HTTP 200, and it is named rather than merely
/// unreadable. Recorded from the live gateway on 2026-09-18, a call whose
/// `params.Data` carries no `cornerstoneParam` — the object the gateway's own
/// validation asks for — comes back as:
///
/// ```json
/// { "code": "200", "successResponse": true, "httpStatusCode": "200",
///   "data": { "success": false, "httpStatus": 200, "errorCode": "Bad Request",
///             "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
///             "errorMsg": "Bad Request" } }
/// ```
///
/// The wrapper's `code` stays "200" through every one of these, so the flags
/// (`successResponse` on the wrapper, `success` on the data) are what say it
/// failed and `data.errorCode` is what names it. That name is the whole of what
/// such an answer has to say, which is why it leaves here as `apiError` rather
/// than being flattened into `badResponse`, whose only content is a status the
/// transport already reported as 200.
///
/// Three of those names are the platform's own signed-out markers:
/// `ConsoleNeedLogin`, `BailianGateway.Login.NotLogined` and `NO_LOGIN` — the
/// set the console's own bundle keys its "session expired" dialogue off, and
/// the same set the site script maps to 401. Matching it here as well keeps a
/// session that dies between the token call and the usage call from being
/// reported as an ordinary failure. Only those three may become `needsAuth`,
/// because it is the one status that discards the remembered reading: right for
/// a dead session, wrong for a server fault the next refresh will pass, and
/// wrong again for telling someone who is signed in to go and sign in.
///
/// The console bundle all of this mirrors is
/// `https://q.alyasset.com/code/qwen-cloud/console-home/1.1.43/assets/`:
/// `shared.js` holds the gateway client whose `data.DataV2.data` unwrap this
/// parser follows, the session-code set above and the individual-plan card's
/// choice between the two periods the numbers below are read for, while
/// `analytics.js`/`home.js` hold the usage call.
///
/// The numbers sit two unwraps down, inside a `DataV2.data` wrapper that also
/// carries the gateway's own `msg`, `code` and `requestId` and, beside them,
/// `ret` — a list of platform messages ("SUCCESS::接口调用成功"). None of that is
/// read here, because the console's own client does not read it either. Recorded
/// from the first live signed-in read on 2026-09-18, with the account's own
/// numbers replaced:
///
/// ```json
/// { "code": "200", "successResponse": true, "httpStatusCode": "200",
///   "data": { "success": true, "httpStatus": 200,
///             "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
///             "DataV2": { "ret": ["SUCCESS::接口调用成功"],
///                         "data": { "msg": "Success.", "code": "SUCCESS",
///                                   "success": true,
///                                   "data": { "per1WeekPercentage": 0.42,
///                                             "per1WeekResetTime": 1700179200000 } } } } }
/// ```
///
/// A monthly plan answers with `per1MonthPercentage` and `per1MonthResetTime`
/// in that innermost object instead, and no `per1Week*` field at all (recorded
/// the same way on 2026-09-23, against the console's 1.1.43 build).
enum QianwenUsage {
    /// The personal plan's credits window, whichever period the plan is on.
    ///
    /// The period belongs to the account's plan, not to the site, and the two
    /// are told apart by which pair of fields the payload carries: a weekly
    /// plan reports `per1WeekPercentage`/`per1WeekResetTime`, a monthly one the
    /// `per1Month*` pair. `…/tokenplan/personal/api/v2/subscription` is what
    /// says which plan the account is on — `specCode`, status and the plan's
    /// start and end dates — and `…/tokenplan/personal/api/v2/quota-config`
    /// states each tier's allowances under `five_hour`, `weekly` and `monthly`
    /// keys, so a weekly plan's own figure is the `weekly` one there.
    ///
    /// The figures that call answered for this account when the plan change was
    /// read — `essential` 1 800 / 25 500, `lite` 700 / 11 500, `standard`
    /// 3 000 / 45 000, `pro` 12 000 / 180 000 — are a live reading of it alone:
    /// nothing in this repository pins them, they are here as context for the
    /// labels below, and they are not something a reader can check. What the
    /// usage payload read here carries is only the period's percentage and
    /// reset time — no credit counts.
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        let payload = try payload(fromJSON: json)

        // Which period the plan is on is decided the way the console's own
        // individual-plan card decides it (`e.per1WeekPercentage != null`): the
        // weekly branch when that field is there, the monthly one otherwise.
        // Missing and JSON `null` are the same answer there, so they are here
        // too. The percentage and the reset time are then read from that one
        // branch — a weekly fraction against a monthly reset would be a
        // reading of neither period.
        //
        // The branch is chosen by presence alone, not by readability: a weekly
        // field that is there but unreadable is a failed read of the weekly
        // plan, and reading the monthly number as if it were that plan's would
        // report a different period's usage rather than reporting nothing.
        let weeklyValue = payload["per1WeekPercentage"]
        let weeklyPlan = !(weeklyValue == nil || weeklyValue is NSNull)
        let percentage = weeklyPlan ? weeklyValue : payload["per1MonthPercentage"]

        // The console renders remaining as `(1 - percentage)`, clamped,
        // because the platform stops the work at the limit rather than
        // reporting past it. Same reading, same clamp — and the units are the
        // console's too: both live signed-in reads (the weekly one 2026-09-18,
        // the monthly one 2026-09-23) answered a 0–1 fraction, not a
        // percent-scaled 42. That value would clamp here to a full ring rather
        // than being divided by a hundred on a guess, which is what the
        // console's own client does with it.
        var usedFraction = number(percentage).map { min(max($0, 0), 1) }
        var remaining: Int?
        var used: Int?

        // Credits are the fallback reading, not a derivation: a payload that
        // carries counts instead of a fraction still states the allowance, and
        // one that carries neither has nothing to divide by.
        if let total = int(payload["totalCredits"]) ?? int(payload["totalQuota"]),
           let left = int(payload["remainingCredits"]) ?? int(payload["availableQuota"]),
           total > 0, left >= 0 {
            let spent = max(0, total - left)
            remaining = left
            used = spent
            if usedFraction == nil {
                usedFraction = min(max(Double(spent) / Double(total), 0), 1)
            }
        }

        guard let usedFraction else {
            throw UsageProviderError.nothingMetered(L10n.t("QianwenAI reported no Token Plan usage"))
        }

        return [LimitWindow(
            // The id names the *role* this window plays, not its period: the
            // allowance the provider's own ring draws. `Sites.qianwen`
            // declares its roles statically (`headlineID`/`weeklyID` = "week")
            // and every consumer resolves by id — `ProviderSnapshot.headline`,
            // `weeklyLimitWindow`/`weeklyWindow` — so a monthly plan reporting
            // through an id of its own would resolve to nothing and draw an
            // empty ring. What period it is is what the label says, exactly as
            // `CodexUsage` keeps role ids `primary`/`secondary` under
            // period-accurate labels.
            id: "week",
            label: weeklyPlan ? L10n.t("Weekly limit") : L10n.t("Monthly limit"),
            usedFraction: usedFraction,
            remaining: remaining,
            used: used,
            resetsAt: reset(payload[weeklyPlan ? "per1WeekResetTime" : "per1MonthResetTime"],
                            now: now),
            // The cycle length the tooltip's pace line compares elapsed time
            // against (`UsagePace.usagePace`; `LimitWindow.isFiveHour` also
            // reads it, and 30 days is nowhere near the five-hour window that
            // looks for). The monthly reset is anchored to a *day of the
            // month*, not to a cycle length: the live read's
            // `per1MonthResetTime` is 2026-10-02 16:00 UTC, the same day and
            // hour as the plan's own `endTime` (2026-12-02 16:00 UTC, and the
            // term between the recorded `startTime` and it is 91.52 days), so
            // consecutive resets are 28, 29, 30 or 31 days apart depending on
            // the month between them. A nominal 30 days is the convention this
            // repo already uses for a monthly window (`KiroUsage.monthlyDuration
            // = 30 * 86400`; `CodexUsage.label(windowSeconds:)` calls a 30-day
            // window "Monthly limit"), and what it costs is bounded: the
            // elapsed-time comparison is off by at most |cycle − 30| / 30 of the
            // ring — 3.3 percentage points in a 29- or 31-day cycle, 6.7 in the
            // 28-day February one, nothing at all when a cycle is 30 days.
            duration: weeklyPlan ? 7 * 86_400 : 30 * 86_400
        )]
    }

    /// The console's own extractor: `data.DataV2.data`, then one level further
    /// when the object it reached carries a `data` of its own.
    ///
    /// The named failure is read *first*, because a failed read carries no
    /// `DataV2` at all: taken in the other order the failure would arrive as an
    /// unreadable shape, which is exactly how it used to be reported as
    /// `badResponse(status: 0)` — "HTTP 0", naming nothing.
    static func payload(fromJSON json: String) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let data = root["data"] as? [String: Any] ?? [:]
        // Both flags are read: the console sets `successResponse` on the
        // wrapper and `success` on the data, and a failure that flipped only
        // one of them would otherwise look like a happy empty answer.
        if root["successResponse"] as? Bool == false || data["success"] as? Bool == false {
            let message = name(data["errorMsg"])
            if let signedOut = failureName(root: root, data: data) ?? message,
               sessionCodes.contains(where: { $0.caseInsensitiveCompare(signedOut) == .orderedSame }) {
                throw UsageProviderError.needsAuth
            }
            if let code = failureName(root: root, data: data) {
                throw UsageProviderError.apiError(code)
            }
            // `errorMsg` is the server's own prose: never shown or logged as is
            // (the store logs failures publicly), only a line of our own.
            if message != nil {
                throw UsageProviderError.apiError(L10n.t("QianwenAI refused the request."))
            }
            // A failure that names nothing is only the shape it looks like.
            throw UsageProviderError.badResponse(status: 0)
        }

        guard int(root["code"]) == 200,
              let dataV2 = data["DataV2"] as? [String: Any],
              let payload = dataV2["data"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        return (payload["data"] as? [String: Any]) ?? payload
    }

    /// The session-failure names the console's own bundle treats as "signed
    /// out", and the only names allowed to become `needsAuth`.
    private static let sessionCodes = ["ConsoleNeedLogin",
                                       "BailianGateway.Login.NotLogined",
                                       "NO_LOGIN"]

    /// Where this dialect puts a failure's code, in its own order of authority:
    /// the gateway's `errorCode`, then the data's `code`, then the wrapper's
    /// `code` when it is not a success. Codes only — `errorMsg` is free text.
    private static func failureName(root: [String: Any], data: [String: Any]) -> String? {
        if let name = name(data["errorCode"]) { return name }
        if let name = name(data["code"]) { return name }
        if int(root["code"]) != 200, let name = name(root["code"]) { return name }
        return nil
    }

    /// A name has to be text to be worth showing, and an empty one names
    /// nothing — the next fallback gets its turn instead.
    private static func name(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `per1WeekResetTime` is whatever dayjs accepts: an epoch (milliseconds
    /// past 1e12, seconds past 1e9), or the ISO-8601 string the console sends.
    /// A reset in the past is stale data, not a countdown — it is dropped
    /// rather than drawn as a moment that has already happened.
    private static func reset(_ value: Any?, now: Date) -> Date? {
        guard let date = date(from: value), date > now else { return nil }
        return date
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = number(value), raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String else { return nil }
        // Two formatters, because one with fractional-second support refuses a
        // string without them and vice versa.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// A reading has to be a *finite* number to be one. `Double("nan")` and
    /// `Double("inf")` both parse where the body named neither, and neither is
    /// clamped by the caller's `min(max(…))` — `NaN` passes straight through it
    /// — so such a fraction would satisfy the caller's `guard` and reach
    /// `Percent.text(for:)`/`Percent.halves(for:)`, whose `Int(_: Double)`
    /// conversion aborts the process instead of printing a ring. The console's
    /// own client refuses the same value (`typeof n != "number" ||
    /// !Number.isFinite(n)`, on the field it just picked), and a fraction that
    /// is not finite can be drawn as neither a ring nor a percent, so it is not
    /// a reading — and this is the boundary where a body becomes one.
    /// `date(from:)` reads through here too, where a non-finite epoch would
    /// otherwise come out as a reset moment that is not one.
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

    /// Credits reach the console's own model as decimal strings ("10000.00"),
    /// so both spellings have to count.
    ///
    /// Only the string path needs a bound: `Int("1e30")` fails where
    /// `Double("1e30")` succeeds, and `Int(_: Double)` aborts the process on
    /// that value rather than answering — the same trap `"1e400"` and `"nan"`
    /// reach, all three measured. `NSNumber.intValue` does not abort on those,
    /// so there is nothing to guard on that path.
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
