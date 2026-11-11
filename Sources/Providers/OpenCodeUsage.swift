import Foundation

/// Parses `GET https://opencode.ai/zen/go/v1/usage`.
///
/// The account-wide Go plan windows, the same figures the OpenCode dashboard
/// shows — recorded live (secret redacted):
///
/// ```json
/// {"usage":{
///   "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-06T12:31:06.611Z"},
///   "weekly": {"status":"ok","percent":0,"resetsAt":"2026-09-07T00:00:00.611Z"},
///   "monthly":{"status":"ok","percent":0,"resetsAt":"2026-10-03T13:09:45.611Z"}}}
/// ```
///
/// `percent` is *used*, matching the dashboard's "X% used" — the ring needs no
/// inversion. `resetsAt` carries milliseconds, which the plain ISO8601
/// formatter refuses to read, so both fractional and plain forms are tried.
enum OpenCodeUsage {
    /// The Go plan's API key. This is the route the key is for.
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// The same figures for an OAuth sign-in — the `inference/` routes OpenCode
    /// itself uses once signed in. The pairing is not interchangeable:
    /// `zen/go` answers an OAuth token 401 even on an account that has Go, and
    /// `inference/go` answers a Go key the same way. Both 401s are
    /// indistinguishable from "no Go plan", so sending the wrong one reads as
    /// a signed-out app rather than as a bug. See `OpenCodeProvider`.
    static let oauthEndpoint = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    /// Where an OAuth sign-in's `metadata.server` points when it names none.
    static let defaultConsole = URL(string: "https://opencode.ai/console")!

    /// Window ids in headline order. The ring means the rolling window — the
    /// current one, the same subject Claude's session and Codex's primary are.
    private static var windows: [(id: String, label: String)] {
        [
            ("rolling", L10n.t("5h limit")),
            ("weekly", L10n.t("Weekly limit")),
            ("monthly", L10n.t("Monthly limit")),
        ]
    }

    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let out = self.windows.compactMap { id, label -> LimitWindow? in
            guard let entry = usage[id] as? [String: Any],
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            let resetsAt = (entry["resetsAt"] as? String).flatMap(date(from:))
            return LimitWindow(
                id: id,
                label: label,
                usedFraction: percent / 100,
                resetsAt: resetsAt,
                duration: duration(for: id, endingAt: resetsAt)
            )
        }
        guard !out.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return out
    }

    private static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }

    private static func duration(for id: String, endingAt reset: Date?) -> TimeInterval? {
        if id == "rolling" { return 5 * 3600 }
        if id == "weekly" { return 7 * 86400 }
        guard id == "monthly", let reset else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .month, value: -1, to: reset)
            .map { reset.timeIntervalSince($0) }
    }
}
