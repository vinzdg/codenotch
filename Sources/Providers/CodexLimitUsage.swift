import Foundation

/// The share of the weekly Codex limit spent on each day, split by model, from
/// the dashboard's `wham/usage/daily-token-usage-breakdown`.
struct CodexLimitUsage: Codable, Equatable, Sendable {
    struct ModelShare: Codable, Equatable, Sendable {
        let model: String
        let percent: Double
    }

    struct Day: Codable, Equatable, Sendable {
        /// As the endpoint dates it. Never converted: its time zone is not
        /// documented, and a shifted date would put a day's usage on another.
        let date: String
        let models: [ModelShare]

        var total: Double { models.reduce(0) { $0 + $1.percent } }
    }

    struct LegendEntry: Equatable {
        /// Nil for everything outside the leaders.
        let model: String?
        let share: Double
    }

    /// The last seven days the endpoint returned, oldest first: all the chart draws.
    let days: [Day]

    enum ParseError: Error { case notPercent }

    static func parse(_ data: Data) throws -> CodexLimitUsage {
        struct Body: Decodable {
            struct RawDay: Decodable {
                struct RawModel: Decodable {
                    let model: String
                    let credits: Double?
                }
                let date: String
                let models: [RawModel]?
            }
            let units: String?
            let data: [RawDay]
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        // The per-model field is named `credits` whatever the unit is, so the
        // body's own `units` is the only thing that says these are percent.
        if let units = body.units, units != "percent" { throw ParseError.notPercent }
        let days = body.data.map { raw in
            var totals: [String: Double] = [:]
            for entry in raw.models ?? [] {
                guard let value = entry.credits, value.isFinite, value > 0 else { continue }
                totals[entry.model, default: 0] += value
            }
            let models = totals
                .map { ModelShare(model: $0.key, percent: $0.value) }
                .sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.model < $1.model }
            return Day(date: raw.date, models: models)
        }
        return CodexLimitUsage(days: Array(days.sorted { $0.date < $1.date }.suffix(7)))
    }

    var leaders: [String] {
        var totals: [String: Double] = [:]
        for day in days {
            for share in day.models { totals[share.model, default: 0] += share.percent }
        }
        return totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(2)
            .map(\.key)
    }

    func stack(for day: Day) -> [Double] {
        let values = leaders.map { name in day.models.first { $0.model == name }?.percent ?? 0 }
        return values + [max(0, day.total - values.reduce(0, +))]
    }

    var legend: [LegendEntry] {
        let names: [String?] = leaders.map { Optional($0) } + [nil]
        let stacks = days.map(stack(for:))
        let totals = names.indices.map { index in stacks.reduce(0) { $0 + $1[index] } }
        let sum = totals.reduce(0, +)
        guard sum > 0 else { return [] }
        return zip(names, totals).compactMap { name, total in
            total > 0 ? LegendEntry(model: name, share: total / sum) : nil
        }
    }

    /// The tallest day, floored so a quiet week does not draw full-height bars.
    var scale: Double { max(1, days.map(\.total).max() ?? 0) }

    static func weekday(_ date: String, locale: Locale = L10n.locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("E")
        return formatter.string(from: day)
    }
}

extension ProviderSnapshot {
    var showsCodexLimitUsage: Bool {
        !(codexLimitUsage?.days.isEmpty ?? true)
    }
}
