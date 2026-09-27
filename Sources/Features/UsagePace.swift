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
    /// Share of the window's cycle elapsed, from 0 at reset to just under 1 —
    /// where the fill *should* be. Nil when the window never says when it
    /// rolls, so there is no cycle to be through.
    func elapsedFraction(now: Date) -> Double? {
        guard let duration, duration.isFinite, duration > 0,
              let resetsAt else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime.isFinite, remainingTime > 0 else { return nil }
        // Provider and device clocks can put a fresh reset just beyond one full cycle.
        return 1 - min(remainingTime / duration, 1)
    }

    /// Where the card's pace tick sits on the window's bar, 0...1 from the
    /// leading edge: the elapsed share when the bar reads used, mirrored to
    /// the expected-remaining share when it reads remaining. Nil exactly when
    /// there is no cycle to mark.
    func paceMarkerFraction(now: Date, showingRemaining: Bool) -> Double? {
        guard let elapsed = elapsedFraction(now: now) else { return nil }
        return min(max(Percent.metered(elapsed, showingRemaining: showingRemaining), 0), 1)
    }

    func usagePace(now: Date) -> UsagePace? {
        guard let usedFraction, usedFraction.isFinite, usedFraction >= 0,
              let elapsedFraction = elapsedFraction(now: now) else { return nil }
        // Once the allowance is exhausted there is no negative quota to account for.
        let spentFraction = min(usedFraction, 1)
        return UsagePace(
            percentagePoints: (spentFraction - elapsedFraction) * 100
        )
    }
}
