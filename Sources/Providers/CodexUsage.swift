import Foundation

/// Only the account's main rate-limit windows belong in the usage rings —
/// `additional_rate_limits` and `code_review_rate_limit` meter something else
/// and are deliberately left out.
enum CodexUsage {
    private struct Response: Decodable {
        let rate_limit: RateLimit?
    }

    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }

    private struct Window: Decodable {
        let limit_window_seconds: Double?
        let used_percent: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }

    static func windows(from data: Data, now: Date = Date()) throws -> [LimitWindow] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []
        for (id, window) in [("primary", response.rate_limit?.primary_window),
                             ("secondary", response.rate_limit?.secondary_window)] {
            guard let window else { continue }
            // One malformed window must not discard the other: a null
            // `used_percent` on the 5h window once threw the whole fetch away,
            // hiding a perfectly good weekly window behind an error.
            guard let percent = window.used_percent else { continue }
            let resetsAt = window.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? window.reset_after_seconds.map { now.addingTimeInterval($0) }
            windows.append(LimitWindow(
                id: id,
                label: label(windowSeconds: window.limit_window_seconds ?? 0, fallback: id),
                usedFraction: percent / 100,
                resetsAt: resetsAt
            ))
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Codex reported no usage windows")
        }
        return windows
    }

    /// The plan an account is on decides what its primary window actually is
    /// — a free plan has shown a 30-day window here, not the 5-hour one a paid
    /// plan reports — so the label is derived from the length Codex actually
    /// sent rather than assumed from a fixed pair of durations. Getting this
    /// wrong doesn't mislabel the window, it drops it: an unrecognised length
    /// used to be silently skipped, which on a free account left both windows
    /// absent and the ring reporting nothing metered at all.
    static func label(windowSeconds: Double, fallback: String) -> String {
        guard windowSeconds > 0 else {
            return fallback == "primary" ? "Current session" : "Longer window"
        }
        let minutes = windowSeconds / 60
        if minutes < 60 { return "\(Int(minutes))m limit" }
        if minutes < 60 * 24 { return "\(Int(minutes / 60))h limit" }
        let days = Int((minutes / (60 * 24)).rounded())
        switch days {
        case 7:  return "Weekly limit"
        case 30: return "Monthly limit"
        default: return "\(days)d limit"
        }
    }
}
