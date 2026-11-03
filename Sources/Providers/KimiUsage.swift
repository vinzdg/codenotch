import Foundation

/// Parses `GET https://api.kimi.com/coding/v1/usages`.
///
/// The managed Kimi Code account's windows, the same figures the CLI's
/// `/usage` leads with — recorded live (user id redacted):
///
/// ```json
/// {"user":{"userId":"…","membership":{"level":"LEVEL_ADVANCED"}},
///  "usage":{"limit":"100","used":"2","remaining":"98",
///           "resetTime":"2026-09-15T19:39:34.389610Z"},
///  "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
///             "detail":{"limit":"100","used":"8","remaining":"92",
///                       "resetTime":"2026-09-11T16:39:34.389610Z"}}]}
/// ```
///
/// Two shapes of the same row: `usage` is the account summary (the weekly
/// window — the CLI assumes a week when no window is stated), each `limits[]`
/// entry names its own window. Counts arrive as decimal *strings*, and a
/// 300-minute window is the 5-hour one — minute durations divisible by 60 are
/// normalised to hours, as the CLI does. The Extra Usage wallet
/// (`boosterWallet`) is money, not a window, and is left out here.
enum KimiUsage {
    static let endpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!

    struct Read {
        let windows: [LimitWindow]
        /// The membership tier, named the way the account names it
        /// (`LEVEL_ADVANCED` → "Advanced"). Nil when there is nothing to name.
        let plan: String?
    }

    static func read(fromJSON json: String) throws -> Read {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        var windows: [LimitWindow] = []
        if let summary = root["usage"] as? [String: Any],
           let window = row(id: "weekly", label: L10n.t("Weekly limit"),
                            from: summary, duration: 7 * 86400) {
            windows.append(window)
        }
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let detail = entry["detail"] as? [String: Any],
                  let (baseId, label, duration) = windowKind(from: entry["window"])
            else { continue }
            let rawModel = modelName(from: entry, detail: detail)
            let group = rawModel.map(formatModelGroup)
            let id = rawModel != nil ? "\(modelSlug(rawModel!))-\(baseId)" : baseId
            if let window = row(id: id, group: group, label: label, from: detail, duration: duration) {
                windows.append(window)
            }
        }

        // Support Kimi K models and dedicated sections (e.g. `kimi_k`, `kimiK`, `models`, `model_limits`).
        if let kSection = (root["kimi_k"] as? [String: Any]) ?? (root["kimiK"] as? [String: Any]) {
            parseModelSection(kSection, modelName: "Kimi K", into: &windows)
        }
        if let modelsMap = root["models"] as? [String: Any] {
            for (key, val) in modelsMap {
                if let dict = val as? [String: Any] {
                    parseModelSection(dict, modelName: key, into: &windows)
                }
            }
        } else if let modelsList = root["models"] as? [[String: Any]] {
            for item in modelsList {
                let name = (item["name"] as? String) ?? (item["model"] as? String) ?? "Kimi K"
                parseModelSection(item, modelName: name, into: &windows)
            }
        }
        if let modelLimits = (root["model_limits"] as? [[String: Any]]) ?? (root["modelLimits"] as? [[String: Any]]) {
            for entry in modelLimits {
                guard let detail = entry["detail"] as? [String: Any],
                      let (baseId, label, duration) = windowKind(from: entry["window"])
                else { continue }
                let rawModel = modelName(from: entry, detail: detail) ?? "Kimi K"
                let group = formatModelGroup(rawModel)
                let id = "\(modelSlug(rawModel))-\(baseId)"
                if let window = row(id: id, group: group, label: label, from: detail, duration: duration) {
                    windows.append(window)
                }
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("No Kimi Code usage limits on this account"))
        }

        return Read(windows: windows, plan: plan(from: root))
    }

    private static func parseModelSection(
        _ dict: [String: Any],
        modelName: String,
        into windows: inout [LimitWindow]
    ) {
        let group = formatModelGroup(modelName)
        let prefix = modelSlug(modelName)
        if let summary = dict["usage"] as? [String: Any],
           let window = row(id: "\(prefix)-weekly", group: group, label: L10n.t("Weekly limit"),
                            from: summary, duration: 7 * 86400) {
            windows.append(window)
        }
        for entry in dict["limits"] as? [[String: Any]] ?? [] {
            guard let detail = entry["detail"] as? [String: Any],
                  let (baseId, label, duration) = windowKind(from: entry["window"])
            else { continue }
            if let window = row(id: "\(prefix)-\(baseId)", group: group, label: label, from: detail, duration: duration) {
                windows.append(window)
            }
        }
    }

    static func modelName(from entry: [String: Any], detail: [String: Any]) -> String? {
        for key in ["model", "modelName", "modelId", "name", "agent", "agentModel", "group"] {
            if let value = (entry[key] as? String) ?? (detail[key] as? String), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func formatModelGroup(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "kimi-k" || lower == "k" || lower == "kimi_k" || lower == "kimik" {
            return "Kimi K"
        }
        if lower.hasPrefix("kimi-k") || lower.hasPrefix("kimi_k") {
            let suffix = trimmed.dropFirst("kimi-k".count).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            return suffix.isEmpty ? "Kimi K" : "Kimi K \(suffix.uppercased())"
        }
        if lower.hasPrefix("k3") {
            return "Kimi \(trimmed.uppercased())"
        }
        return trimmed
    }

    static func modelSlug(_ model: String) -> String {
        model.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// One metered row. Counts are decimal strings in the wire format, but
    /// numbers are accepted too. When Kimi omits `used`, a valid limit and
    /// remaining pair still identifies the quota exactly.
    private static func row(id: String, group: String? = nil, label: String,
                            from detail: [String: Any], duration: TimeInterval) -> LimitWindow? {
        let limit = count(detail["limit"])
        let used: Int
        if let reportedUsed = count(detail["used"]) {
            used = reportedUsed
        } else if let limit, limit > 0,
                  let remaining = count(detail["remaining"]), (0...limit).contains(remaining) {
            used = limit - remaining
        } else {
            return nil
        }
        let resetsAt = (detail["resetTime"] as? String).flatMap(date(from:))
        guard let limit, limit > 0 else {
            return LimitWindow(id: id, group: group, label: label, used: used,
                               resetsAt: resetsAt, duration: duration)
        }
        return LimitWindow(id: id, group: group, label: label,
                           usedFraction: Double(used) / Double(limit),
                           resetsAt: resetsAt, duration: duration)
    }

    /// A `limits[]` window as an id, a label and a length. Only the windows
    /// Kimi meters today — the 5-hour rate window and the weekly quota — get
    /// named; anything else is left out rather than mislabelled.
    private static func windowKind(from raw: Any?) -> (id: String, label: String, duration: TimeInterval)? {
        guard let window = raw as? [String: Any],
              let duration = count(window["duration"]), duration > 0,
              let unit = window["timeUnit"] as? String
        else { return nil }
        switch unit {
        case "TIME_UNIT_MINUTE" where duration % 60 == 0:
            let hours = duration / 60
            return hours == 5
                ? ("rolling", L10n.t("5h limit"), TimeInterval(duration * 60))
                : nil
        case "TIME_UNIT_HOUR" where duration == 5:
            return ("rolling", L10n.t("5h limit"), TimeInterval(duration * 3600))
        case "TIME_UNIT_WEEK" where duration == 1:
            return ("weekly", L10n.t("Weekly limit"), 7 * 86400)
        default:
            return nil
        }
    }

    /// `LEVEL_ADVANCED` → "Advanced"; the raw level when there is no prefix to
    /// strip; nil when the account says nothing.
    private static func plan(from root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = membership["level"] as? String, !level.isEmpty
        else { return nil }
        let name = level.hasPrefix("LEVEL_") ? String(level.dropFirst("LEVEL_".count)) : level
        return name.lowercased().capitalized
    }

    private static func count(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        guard let text = any as? String, let value = Int(text) else { return nil }
        return value
    }

    private static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }
}
