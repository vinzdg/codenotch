import Foundation

/// The used share of each provider's weekly window across its current cycle,
/// sampled from the store's own polls while "Show usage history" is on.
struct UsageHistory {
    struct Sample: Codable, Equatable {
        let at: Date
        let used: Double
    }

    struct Segment {
        let from: Sample
        let to: Sample
        /// False across a silence long enough that the app may have been
        /// closed or asleep: the chart must not present it as measured.
        let observed: Bool
    }

    struct Series: Codable, Equatable {
        let windowID: String
        let cycleStart: Date
        var samples: [Sample]

        var segments: [Segment] {
            zip(samples, samples.dropFirst()).map {
                Segment(from: $0, to: $1,
                        observed: $1.at.timeIntervalSince($0.at) < UsageHistory.gapThreshold)
            }
        }
    }

    /// With no change, one sample per half hour still shows the app was
    /// watching. Past the gap threshold, a flat stretch is unobserved.
    static let heartbeat: TimeInterval = 30 * 60
    static let gapThreshold: TimeInterval = 45 * 60
    /// `resetsAt` moves by seconds between polls; a new cycle moves it by hours.
    static let cycleTolerance: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let key = "usageHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every stored series, decoded once for the caller to keep.
    func all() -> [String: Series] {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Series].self, from: data)
        else { return [:] }
        return all
    }

    /// Records the snapshot's weekly window, or its headline without one, and
    /// returns that provider's series: nil when there is nothing to chart.
    @discardableResult
    func record(_ snapshot: ProviderSnapshot, at now: Date) -> Series? {
        guard let window = snapshot.weeklyLimitWindow ?? snapshot.headline,
              let reported = window.usedFraction, reported.isFinite,
              let duration = window.duration, duration.isFinite, duration > 0,
              let resetsAt = window.resetsAt else { return nil }
        // A tenth of a percent is under a pixel on the chart. Finer values from
        // money- or token-metered windows would add a sample on nearly every poll.
        let used = (reported * 1000).rounded() / 1000
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        var all = all()
        var series = all[snapshot.id]
        if let current = series, current.windowID != window.id
            || abs(current.cycleStart.timeIntervalSince(cycleStart)) > Self.cycleTolerance {
            series = nil
        }
        var updated = series ?? Series(windowID: window.id, cycleStart: cycleStart, samples: [])
        if let last = updated.samples.last,
           now <= last.at || (last.used == used && now.timeIntervalSince(last.at) < Self.heartbeat) {
            return updated
        }
        let kept = updated.cycleStart
        updated.samples.removeAll { $0.at < kept }
        updated.samples.append(Sample(at: now, used: used))
        all[snapshot.id] = updated
        save(all)
        return updated
    }

    func forget(_ providerID: String) {
        var all = all()
        guard all.removeValue(forKey: providerID) != nil else { return }
        save(all)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func save(_ all: [String: Series]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}

extension ProviderSnapshot {
    /// The series and the window it charts, when the card has a chart to draw.
    /// Two samples at least: one point is not a line.
    var chartedHistory: (series: UsageHistory.Series, window: LimitWindow)? {
        guard let usageHistory, usageHistory.samples.count >= 2,
              localModel == nil, statusMessage == nil,
              // By the series' own id: the ring overlays rename `headlineID` and
              // `weeklyID` on the way to the card, but never the window ids.
              let window = windows.first(where: { $0.id == usageHistory.windowID }),
              window.resetsAt != nil, (window.duration ?? 0) > 0
        else { return nil }
        return (usageHistory, window)
    }
}

extension UsageHistory.Series {
    /// The sample under `date` while the app was watching; nil across a gap,
    /// or further than half a gap from either end of the recorded span.
    func reading(at date: Date) -> UsageHistory.Sample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let reach = UsageHistory.gapThreshold / 2
        if date < first.at { return first.at.timeIntervalSince(date) <= reach ? first : nil }
        if date > last.at { return date.timeIntervalSince(last.at) <= reach ? last : nil }
        guard let segment = segments.first(where: { $0.from.at <= date && date <= $0.to.at }),
              segment.observed else { return nil }
        return date.timeIntervalSince(segment.from.at) <= segment.to.at.timeIntervalSince(date)
            ? segment.from : segment.to
    }
}

extension UsageHistory {
    private static func time(_ moment: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = ResetCopy.formatter(for: calendar)
        formatter.locale = locale
        // Past or future, a weekday alone only names a day within a week.
        let days = abs(ResetCopy.daysApart(from: moment, to: now, calendar: calendar))
        formatter.setLocalizedDateFormatFromTemplate(days == 0 ? "j:mm" : days < 7 ? "E j:mm" : "MMM d j:mm")
        return formatter.string(from: moment)
    }

    /// The chart's title, and when the recording began if that was after the
    /// cycle did, which is why a young chart looks empty.
    static func heading(series: Series, window: LimitWindow, now: Date,
                        calendar: Calendar = .current, locale: Locale = L10n.locale) -> (title: String, since: String?) {
        let duration = window.duration ?? 0
        let title: String
        switch duration {
        case ..<86400: title = window.label
        case ...(8 * 86400): title = L10n.t("\(window.label) · this week", locale: locale)
        default: title = L10n.t("\(window.label) · this month", locale: locale)
        }
        guard let first = series.samples.first, let resetsAt = window.resetsAt,
              first.at.timeIntervalSince(resetsAt.addingTimeInterval(-duration)) > 30 * 60
        else { return (title, nil) }
        let since = time(first.at, now: now, calendar: calendar, locale: locale)
        return (title, L10n.t("history since \(since)", locale: locale))
    }

    /// The line under the chart, in plain words: how the use compares with a
    /// steady use of the limit without a pointer, the moment under it with one.
    /// Readings print like the rest of the card, `~` included, and so does the
    /// rate, which is an estimate; steady use is time arithmetic and carries none.
    static func detail(series: Series, window: LimitWindow, hovering date: Date?, now: Date,
                       fidelity: Fidelity = .official, staleSince: Date? = nil,
                       calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let duration = max(1, window.duration ?? 1)
        let start = (window.resetsAt ?? now).addingTimeInterval(-duration)
        func steady(at moment: Date) -> Int {
            Int((min(max(moment.timeIntervalSince(start) / duration, 0), 1) * 100).rounded())
        }
        func reading(_ fraction: Double) -> String { "\(fidelity.qualifier)\(Percent.text(for: fraction))" }
        func time(_ moment: Date) -> String { Self.time(moment, now: now, calendar: calendar, locale: locale) }
        let reached = (window.usedFraction ?? 0) >= 1

        guard let date else {
            guard let latest = window.usedFraction ?? series.samples.last?.used else { return "" }
            if let staleSince {
                return L10n.t("At \(time(staleSince)) · used \(reading(latest))% (steady use \(steady(at: staleSince))%)",
                              locale: locale)
            }
            let summary = L10n.t("Used \(reading(latest))% · steady use \(steady(at: now))%", locale: locale)
            // Judged on where the rate line ends, so the verdict, the line and
            // the card's own projection row never disagree.
            let verdict: String
            if reached {
                verdict = L10n.t("limit reached", locale: locale)
            } else if let resetsAt = window.resetsAt, let atReset = window.usedAtThisRate(resetsAt, now: now) {
                verdict = atReset > 1.2 ? L10n.t("fast", locale: locale)
                    : atReset > 1 ? L10n.t("a bit fast", locale: locale)
                    : atReset >= 0.9 ? L10n.t("on track", locale: locale)
                    : L10n.t("room to spare", locale: locale)
            } else {
                return summary
            }
            return L10n.t("\(summary) → \(verdict)", locale: locale)
        }
        if date > now {
            guard !reached, let projected = window.usedAtThisRate(date, now: now) else {
                return L10n.t("\(time(date)) · steady use \(steady(at: date))%", locale: locale)
            }
            return L10n.t("\(time(date)) · at this rate ~\(Percent.text(for: min(projected, 1)))% (steady use \(steady(at: date))%)",
                          locale: locale)
        }
        guard let sample = series.reading(at: date) else {
            if let first = series.samples.first, date < first.at {
                return L10n.t("\(time(date)) · before history began", locale: locale)
            }
            return L10n.t("\(time(date)) · no data recorded", locale: locale)
        }
        return L10n.t("\(time(sample.at)) · used \(reading(sample.used))% (steady use \(steady(at: sample.at))%)",
                      locale: locale)
    }
}
