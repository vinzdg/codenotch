import Foundation
import CoreFoundation

/// Website response contract cross-checked against issue #340 and CodexBar's
/// Qoder plugin. Fixtures are synthetic; no signed-in response was captured.
enum QoderUsage {
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 200) }
        func field(_ object: [String: Any], _ camel: String, _ snake: String) -> Any? {
            let value = object[camel]
            return value == nil || value is NSNull ? object[snake] : value
        }
        func number(_ object: [String: Any], _ camel: String, _ snake: String) throws -> Double {
            guard let n = field(object, camel, snake) as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= 0 else { throw UsageProviderError.badResponse(status: 200) }
            return n.doubleValue
        }
        func quota(_ value: Any?) throws -> (Double, Double) {
            guard let container = value as? [String: Any],
                  let summary = field(container, "quotaSummary", "quota_summary") as? [String: Any]
            else { throw UsageProviderError.badResponse(status: 200) }
            if let remaining = field(summary, "remainingValue", "remaining_value"), !(remaining is NSNull) {
                _ = try number(summary, "remainingValue", "remaining_value")
            }
            return (try number(summary, "usedValue", "used_value"),
                    try number(summary, "limitValue", "limit_value"))
        }
        var (used, total) = try quota(field(root, "totalQuota", "total_quota"))
        if let shared = field(root, "sharedQuota", "shared_quota"), !(shared is NSNull) {
            let (sharedUsed, sharedTotal) = try quota(shared)
            used += sharedUsed
            total += sharedTotal
        }
        guard used.isFinite, total.isFinite else { throw UsageProviderError.badResponse(status: 200) }
        guard total > 0 else {
            if used > 0 { throw UsageProviderError.badResponse(status: 200) }
            throw UsageProviderError.nothingMetered(L10n.t("Qoder reported no credit allowance"))
        }
        guard (used / total).isFinite else { throw UsageProviderError.badResponse(status: 200) }
        var reset: Date?
        if let value = field(root, "nextResetAt", "next_reset_at"), !(value is NSNull) {
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
               n.doubleValue.isFinite, n.doubleValue >= 0 {
                let timestamp = n.doubleValue
                reset = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
            } else if let string = value as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: string)
                if reset == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    reset = formatter.date(from: string)
                }
            }
            guard reset != nil else { throw UsageProviderError.badResponse(status: 200) }
        }
        // Keep fractional credits in text; Int counters would truncate them.
        return [LimitWindow(id: "credits", label: L10n.t("Credits"),
                            usedFraction: used / total,
                            usedText: "\(used.formatted()) / \(total.formatted())",
                            resetsAt: reset, prefersUsedText: true)]
    }
}
