import Foundation

struct UsagePace {
    /// Used quota minus elapsed time, expressed in percentage points.
    let percentagePoints: Double

    var isDeficit: Bool { percentagePoints > 0 }

    var summary: String {
        let magnitude = abs(percentagePoints)
        let rounded = (magnitude * 10).rounded() / 10
        let value = rounded == 0 && magnitude > 0
            ? "<0.1"
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
                .replacingOccurrences(of: ".0", with: "")
        return isDeficit
            ? L10n.t("\(value)% deficit")
            : L10n.t("\(value)% reserved")
    }
}

extension LimitWindow {
    func usagePace(now: Date) -> UsagePace? {
        guard let usedFraction, usedFraction.isFinite, usedFraction >= 0,
              let duration, duration.isFinite, duration > 0,
              let resetsAt else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime.isFinite, remainingTime > 0 else { return nil }
        // Provider and device clocks can put a fresh reset just beyond one full cycle.
        let remainingFraction = min(remainingTime / duration, 1)
        let elapsedFraction = 1 - remainingFraction
        // Once the allowance is exhausted there is no negative quota to account for.
        let spentFraction = min(usedFraction, 1)
        return UsagePace(
            percentagePoints: (spentFraction - elapsedFraction) * 100
        )
    }
}

struct UsageProjection {
    /// When the window reaches its limit if the average rate so far holds.
    let hitAt: Date
    /// How long before the reset that happens.
    let early: TimeInterval

    func summary(now: Date, calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let formatter = ResetCopy.formatter(for: calendar)
        formatter.locale = locale
        // ResetCopy's thresholds: a weekday alone reads as this week's.
        let days = ResetCopy.daysApart(from: now, to: hitAt, calendar: calendar)
        formatter.setLocalizedDateFormatFromTemplate(days == 0 ? "j:mm" : days < 7 ? "E j:mm" : "MMM d")
        let time = formatter.string(from: hitAt)
        return L10n.t("~100% around \(time) · \(Self.duration(early)) early", locale: locale)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 86400 else { return UsageFormat.duration(seconds: seconds) }
        let hours = Int((seconds / 3600).rounded())
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }
}

extension LimitWindow {
    func projection(now: Date) -> UsageProjection? {
        guard let usedFraction, usedFraction.isFinite, usedFraction < 1,
              let duration, duration.isFinite, duration > 0,
              let resetsAt else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime.isFinite, remainingTime > 0 else { return nil }
        let elapsedFraction = 1 - min(remainingTime / duration, 1)
        // A few percent spent in the first minutes extrapolates to several
        // times the limit. Below this share the average rate says nothing yet.
        guard elapsedFraction >= 0.05, usedFraction > elapsedFraction else { return nil }
        let rate = usedFraction / (elapsedFraction * duration)
        let hitAt = now.addingTimeInterval((1 - usedFraction) / rate)
        return UsageProjection(hitAt: hitAt, early: resetsAt.timeIntervalSince(hitAt))
    }
}

extension ProviderSnapshot {
    /// Rows that draw a projection line under their summary. The card and the
    /// hover region budget one line for each, or the last row clips.
    func projectionRowCount(now: Date, showsUsagePace: Bool) -> Int {
        guard showsUsagePace, localModel == nil, statusMessage == nil else { return 0 }
        return windows.filter { $0.money == nil && $0.projection(now: now) != nil }.count
    }
}
