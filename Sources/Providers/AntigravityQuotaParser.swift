import Foundation

/// Normalizes the quota envelopes shared by Antigravity's local language server
/// and Cloud Code. Keeping this outside either transport prevents source-specific
/// window IDs, cadence inference, or ordering from leaking into the UI.
enum AntigravityQuotaParser {
    private struct Remaining: Decodable {
        let fraction: Double?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case oneofCase = "case"
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let fraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                self.fraction = fraction
            } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
                self.fraction = try container.decodeIfPresent(Double.self, forKey: .value)
            } else {
                self.fraction = nil
            }
        }
    }

    private struct Bucket: Decodable {
        let modelId: String?
        let bucketId: String?
        let name: String?
        let displayName: String?
        let remainingFraction: Double?
        let remaining: Remaining?
        let used: Double?
        let limit: Double?
        let resetTime: String?
        let window: String?
        let disabled: Bool?

        var fraction: Double? { self.remainingFraction ?? self.remaining?.fraction }
    }

    private struct Group: Decodable {
        let displayName: String?
        let buckets: [Bucket]?
    }

    private struct GroupBody: Decodable {
        let groups: [Group]?
    }

    private struct Response: Decodable {
        let buckets: [Bucket]?
        let groups: [Group]?
        let quotaGroups: [Group]?
        let response: GroupBody?
        let summary: GroupBody?
    }

    private struct Candidate {
        let remaining: Double
        let resetDate: Date?
        let isWeekly: Bool
    }

    static func parse(_ data: Data, now: Date) -> [LimitWindow] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let groups = response.response?.groups
            ?? response.summary?.groups
            ?? response.groups
            ?? response.quotaGroups
            ?? []
        if !groups.isEmpty { return self.groupedWindows(groups) }
        guard let buckets = response.buckets, !buckets.isEmpty else { return [] }
        if buckets.contains(where: { $0.limit != nil }) {
            return self.legacyWindows(buckets)
        }
        return self.modelWindows(buckets, now: now)
    }

    private static func groupedWindows(_ groups: [Group]) -> [LimitWindow] {
        let sortedGroups = groups.enumerated().sorted { lhs, rhs in
            let lhsRank = self.groupRank(lhs.element.displayName)
            let rhsRank = self.groupRank(rhs.element.displayName)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        var windows: [LimitWindow] = []
        for indexedGroup in sortedGroups {
            windows.append(contentsOf: self.bucketWindows(in: indexedGroup.element))
        }
        return windows
    }

    private static func bucketWindows(in group: Group) -> [LimitWindow] {
        let sortedBuckets = (group.buckets ?? []).enumerated().sorted { lhs, rhs in
            let lhsRank = self.cadence(lhs.element)
            let rhsRank = self.cadence(rhs.element)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        return sortedBuckets.compactMap { indexedBucket in
            let bucket = indexedBucket.element
            guard bucket.disabled != true else { return nil }
            let groupName = group.displayName
            let rawID = self.id(for: bucket, group: groupName)
            let reset = bucket.resetTime.flatMap(AntigravityCredentials.parse)
            if let remaining = bucket.fraction, (0...1).contains(remaining) {
                return LimitWindow(
                    id: rawID,
                    group: self.groupName(groupName),
                    label: self.label(for: bucket, fallback: "Usage"),
                    usedFraction: 1 - remaining,
                    resetsAt: reset,
                    duration: self.duration(for: bucket))
            }
            guard let limit = bucket.limit, limit > 0,
                  let used = bucket.used, used >= 0, used <= limit * 1.5
            else { return nil }
            return LimitWindow(
                id: rawID,
                group: self.groupName(groupName),
                label: self.label(for: bucket, fallback: rawID),
                usedFraction: used / limit,
                resetsAt: reset,
                duration: self.duration(for: bucket))
        }
    }

    private static func legacyWindows(_ buckets: [Bucket]) -> [LimitWindow] {
        buckets.compactMap { bucket in
            guard let limit = bucket.limit, limit > 0,
                  let used = bucket.used, used >= 0, used <= limit * 1.5
            else { return nil }
            let rawID = self.id(for: bucket, group: nil)
            return LimitWindow(
                id: rawID,
                label: self.label(for: bucket, fallback: rawID),
                usedFraction: used / limit,
                resetsAt: bucket.resetTime.flatMap(AntigravityCredentials.parse),
                duration: self.duration(for: bucket))
        }
    }

    private static func modelWindows(_ buckets: [Bucket], now: Date) -> [LimitWindow] {
        var geminiHourly: [Candidate] = []
        var geminiWeekly: [Candidate] = []
        var thirdPartyHourly: [Candidate] = []
        var thirdPartyWeekly: [Candidate] = []

        for bucket in buckets {
            guard let remaining = bucket.fraction, (0...1).contains(remaining) else { continue }
            let model = self.normalized(self.id(for: bucket, group: nil))
            guard !model.isEmpty, !model.starts(with: "chat_") else { continue }
            let resetDate = bucket.resetTime.flatMap(AntigravityCredentials.parse)
            let resetIsWeekly: Bool
            if let resetDate {
                resetIsWeekly = resetDate.timeIntervalSince(now) > 24 * 3600
            } else {
                resetIsWeekly = false
            }
            let isWeekly = self.cadence(bucket) == 1 || resetIsWeekly
            let candidate = Candidate(remaining: remaining, resetDate: resetDate, isWeekly: isWeekly)
            if model.contains("gemini") {
                if isWeekly { geminiWeekly.append(candidate) } else { geminiHourly.append(candidate) }
            } else if model.contains("claude") || model.contains("gpt") || model.contains("openai") {
                if isWeekly { thirdPartyWeekly.append(candidate) } else { thirdPartyHourly.append(candidate) }
            }
        }

        var windows: [LimitWindow] = []
        if let window = self.aggregate(
            geminiHourly, id: "gemini-hourly", group: L10n.t("Gemini Models"), label: L10n.t("5-hour Limit"), weekly: false)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            geminiWeekly, id: "gemini-weekly", group: L10n.t("Gemini Models"), label: L10n.t("Weekly Limit"), weekly: true)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            thirdPartyHourly, id: "3p-hourly", group: L10n.t("Claude and GPT models"), label: L10n.t("5-hour Limit"), weekly: false)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            thirdPartyWeekly, id: "3p-weekly", group: L10n.t("Claude and GPT models"), label: L10n.t("Weekly Limit"), weekly: true)
        {
            windows.append(window)
        }
        return windows
    }

    private static func aggregate(
        _ candidates: [Candidate],
        id: String,
        group: String,
        label: String,
        weekly: Bool) -> LimitWindow?
    {
        guard let best = candidates.min(by: { $0.remaining < $1.remaining }) else { return nil }
        return LimitWindow(
            id: id,
            group: group,
            label: label,
            usedFraction: 1 - best.remaining,
            resetsAt: best.resetDate,
            duration: weekly ? 7 * 86400 : 5 * 3600)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func groupRank(_ value: String?) -> Int {
        let normalized = self.normalized(value ?? "")
        if normalized.contains("gemini") { return 0 }
        if normalized.contains("claude") || normalized.contains("gpt") { return 1 }
        return 2
    }

    private static func cadence(_ bucket: Bucket) -> Int {
        if let value = self.cadenceValue(bucket.window), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.bucketId), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.displayName), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.window), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.bucketId), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.displayName), self.isSessionValue(value) { return 0 }
        return 2
    }

    private static func cadenceValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.normalized(raw)
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(" limit") ? String(value.dropLast(" limit".count)) : value
    }

    private static func isWeeklyValue(_ value: String) -> Bool {
        value == "weekly" || value.hasSuffix("-weekly") || value.hasSuffix(" weekly")
    }

    private static func isSessionValue(_ value: String) -> Bool {
        value == "session" || value == "5h" || value == "5-hour" ||
            value == "five hour" || value == "five-hour" || value == "hourly" ||
            value.hasSuffix("-session") || value.hasSuffix("-5h") ||
            value.hasSuffix("-5-hour") || value.hasSuffix("-five-hour") ||
            value.hasSuffix("-hourly")
    }

    private static func duration(for bucket: Bucket) -> TimeInterval? {
        switch self.cadence(bucket) {
        case 0: return 5 * 3600
        case 1: return 7 * 86400
        default: return nil
        }
    }

    /// The server names its windows in English whatever the app's language,
    /// so the ones it is known to send are looked up in the catalog. Any other
    /// name is shown as the server spelled it.
    private static func label(for bucket: Bucket, fallback: String) -> String {
        var value = bucket.displayName ?? fallback
        if value.hasSuffix(" Remaining") {
            value = String(value.dropLast(" Remaining".count))
        }
        switch value {
        case "Five Hour Limit", "5-hour Limit": return L10n.t("5-hour Limit")
        case "Weekly Limit": return L10n.t("Weekly Limit")
        default: return value
        }
    }

    /// The same for the groups the windows sit under.
    private static func groupName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        switch name {
        case "Gemini Models": return L10n.t("Gemini Models")
        case "Claude and GPT models": return L10n.t("Claude and GPT models")
        default: return name
        }
    }

    private static func id(for bucket: Bucket, group: String?) -> String {
        [bucket.bucketId, bucket.modelId, bucket.name, group]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? "quota"
    }
}
