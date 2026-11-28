import Foundation

/// Reads Qwen.ai's subscription allowance out of the chat console's own
/// entitlement service.
///
/// `qwen code`'s OAuth token only covers model calls (`model:invoke
/// profile:read`), and the CLI learns about quota only when a request is
/// refused with 402 `insufficient_quota` — there is no remaining-credit reading
/// in that protocol. The number the console shows on its Usage & Billing page
/// comes from a different service, authorized by the *web* session:
///
/// - `GET https://sg-entitlement.qwen.com/api/entitlement/agent/usage`
///   → `data.remainingPercent` (0–100, the way the console clamps it),
///     `data.resetAt` (epoch milliseconds — the console subtracts `Date.now()`
///     and divides by 3_600_000), and `data.memberType`.
/// - `GET https://sg-entitlement.qwen.com/api/entitlement/credits/credits/history`
///   → `data.totalCredits` / `subscriptionCredits` / `bonusCredits`, the
///     credits *left*, not the allowance that was granted.
///
/// The site script reads both with the signed-in WKWebView and passes their raw
/// bodies here. These are the console's own field reads, not a documented API
/// and not a response captured from a live account: a shape this cannot read
/// fails loudly instead of drawing a ring from a guess.
enum QwenAIUsage {
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let envelope = object(from: json) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let usageText = envelope["usage"] as? String ?? ""

        // The entitlement service answers signed-out requests with HTTP 200 and
        // a `NOT_LOGIN` envelope, so the site script has to map that to a 401;
        // the same check here keeps an unmapped one from becoming a ring.
        guard let usage = object(from: usageText) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        try rejectFailure(in: usage)

        let data = payload(in: usage)
        guard let remainingPercent = number(data["remainingPercent"]) else {
            throw UsageProviderError.nothingMetered(L10n.t("Qwen.ai reported no subscription usage"))
        }
        let usedFraction = min(max(1 - remainingPercent / 100, 0), 1)
        let plan = name(data["memberType"])

        // The balance is a better tooltip number than a bare percentage, but it
        // is best-effort: a credits endpoint that changes shape must not cost an
        // otherwise readable allowance ring.
        var remaining: Int?
        if let creditsText = envelope["credits"] as? String,
           let credits = object(from: creditsText),
           credits["errorCode"] == nil,
           (credits["success"] as? Bool ?? true) {
            let balance = payload(in: credits)
            remaining = int(balance["subscriptionCredits"]) ?? int(balance["totalCredits"])
        }

        return [LimitWindow(
            id: "week",
            label: plan.map { "\($0.capitalized) plan" } ?? L10n.t("Subscription credits"),
            usedFraction: usedFraction,
            remaining: remaining,
            resetsAt: resetDate(data["resetAt"], now: now),
            // Qwen's coding credits are a weekly allowance. The console's own
            // reset moment is preferred above; this is the pace line's cycle.
            duration: 7 * 86_400
        )]
    }

    /// Signed-out is a body-level `NOT_LOGIN` on this service, not a transport
    /// status. Named failures are never shown verbatim — the store logs failures
    /// publicly — so our own one-line prose replaces them.
    private static func rejectFailure(in body: [String: Any]) throws {
        let code = int(body["httpCode"]) ?? 0
        let named = name(body["errorCode"])?.uppercased() ?? ""
        let success = body["success"] as? Bool ?? true
        if code == 401 || ["NOT_LOGIN", "UNAUTHORIZED", "LOGIN_REQUIRED"].contains(named) {
            throw UsageProviderError.needsAuth
        }
        if code >= 400 || !success || !named.isEmpty {
            throw UsageProviderError.apiError(L10n.t("Qwen.ai refused the request."))
        }
    }

    /// The console unwraps `data` before storing the result, but a raw response
    /// still carries the envelope: accept either.
    private static func payload(in body: [String: Any]) -> [String: Any] {
        (body["data"] as? [String: Any]) ?? body
    }

    /// `resetAt` is in milliseconds — verified by the console's own arithmetic
    /// (`(resetAt - Date.now()) / 36e5` hours). Some gateways send seconds, so
    /// the unit is chosen by magnitude. A reset already past is stale data,
    /// not a countdown.
    private static func resetDate(_ value: Any?, now: Date) -> Date? {
        guard let milliseconds = number(value) else { return nil }
        let seconds = milliseconds > 100_000_000_000 ? milliseconds / 1_000 : milliseconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date > now ? date : nil
    }

    private static func object(from json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func name(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A reading has to be finite: `Double("nan")` parses and then passes the
    /// caller's `min(max(…))`, reaching `Percent`'s integer conversion, which
    /// traps on NaN rather than drawing anything.
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
