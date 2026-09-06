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
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    /// Window ids in headline order. The ring means the rolling window — the
    /// current one, the same subject Claude's session and Codex's primary are.
    private static let windows: [(id: String, label: String)] = [
        ("rolling", "5h limit"),
        ("weekly", "Weekly limit"),
        ("monthly", "Monthly limit"),
    ]

    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let out = self.windows.compactMap { id, label -> LimitWindow? in
            guard let entry = usage[id] as? [String: Any],
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return LimitWindow(
                id: id,
                label: label,
                usedFraction: percent / 100,
                resetsAt: (entry["resetsAt"] as? String).flatMap(date(from:))
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
}
