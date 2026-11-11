import Foundation

/// Watches store snapshots and detects when a provider's session or weekly
/// limit reaches 100% (exhausted) or becomes blocked.
@MainActor
final class UsageLimitWatcher {
    private struct TrackedLimit {
        /// False until this window has been read once. The first reading of a
        /// window only records: a limit already spent when Codenotch starts is
        /// not news. Kept per window rather than per provider because the
        /// windows do not arrive together: the store's first publication can
        /// be a placeholder with no window at all, and the weekly window can
        /// appear a fetch after the session one. Counting the placeholder as
        /// the baseline is what announced "limit reached" at launch.
        var seeded = false
        var isExhausted: Bool = false
        var resetsAt: Date?
        var fraction: Double = 0
    }

    private struct ProviderLimitState {
        var session: TrackedLimit = TrackedLimit()
        var weekly: TrackedLimit = TrackedLimit()
    }

    private var states: [String: ProviderLimitState] = [:]
    private let isMuted: (String) -> Bool
    private let deliver: (UsageAlertEvent) -> Void
    private let now: () -> Date

    init(
        isMuted: @escaping (String) -> Bool = { _ in false },
        deliver: @escaping (UsageAlertEvent) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.isMuted = isMuted
        self.deliver = deliver
        self.now = now
    }

    /// A later reset timestamp alone is not a new window: APIs which report a
    /// relative countdown move that timestamp by a few seconds on every
    /// refresh, and re-arming on that announced "limit reached" again on every
    /// fetch while the limit stayed spent. The tracked window must have
    /// actually elapsed, the same rule the reset watcher applies.
    private func rolledOver(from previous: Date?, to current: Date?) -> Bool {
        guard let previous, let current else { return false }
        return previous <= now() && current > previous
    }

    func observe(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            observe(snapshot)
        }
    }

    private func observe(_ snapshot: ProviderSnapshot) {
        // Same rule as the reset watcher: an archived (stale) reading is not a
        // baseline, so the first live reading after one only records.
        guard !snapshot.status.isStale else {
            states.removeValue(forKey: snapshot.id)
            return
        }
        var state = states[snapshot.id] ?? ProviderLimitState()

        // 1. Session limit (headline window)
        if let headline = snapshot.headline, let fraction = snapshot.usedFraction {
            // A block the spent week attached is the weekly alert's news, not
            // the session's: counting it here would fire a session card
            // claiming the session itself spent while it still shows room.
            let blockedBeyondWeekly = snapshot.block.map { !$0.isWeeklyExhaustion } ?? false
            let isExhausted = fraction >= 1.0 || blockedBeyondWeekly

            let dateRolledOver = rolledOver(from: state.session.resetsAt, to: headline.resetsAt)

            if dateRolledOver || fraction < 0.95 {
                state.session.isExhausted = false
            }

            if !state.session.seeded {
                state.session.seeded = true
                state.session.isExhausted = isExhausted
            } else if isExhausted && !state.session.isExhausted && !isMuted(snapshot.id) {
                state.session.isExhausted = true
                deliver(UsageAlertEvent(
                    kind: .sessionLimitReached,
                    providerID: snapshot.id,
                    providerName: snapshot.displayName,
                    windowLabel: headline.label,
                    glyph: snapshot.glyph,
                    previousFraction: state.session.fraction,
                    currentFraction: fraction,
                    resetsAt: headline.resetsAt
                ))
            }

            state.session.fraction = fraction
            state.session.resetsAt = headline.resetsAt
        }

        // 2. Weekly limit (secondary window)
        if let weekly = snapshot.weeklyWindow, let weeklyFraction = snapshot.weeklyFraction {
            let isWeeklyExhausted = weeklyFraction >= 1.0

            let dateRolledOver = rolledOver(from: state.weekly.resetsAt, to: weekly.resetsAt)

            if dateRolledOver || weeklyFraction < 0.95 {
                state.weekly.isExhausted = false
            }

            if !state.weekly.seeded {
                state.weekly.seeded = true
                state.weekly.isExhausted = isWeeklyExhausted
            } else if isWeeklyExhausted && !state.weekly.isExhausted && !isMuted(snapshot.id) {
                state.weekly.isExhausted = true
                deliver(UsageAlertEvent(
                    kind: .weeklyLimitReached,
                    providerID: snapshot.id,
                    providerName: snapshot.displayName,
                    windowLabel: weekly.label,
                    glyph: snapshot.glyph,
                    previousFraction: state.weekly.fraction,
                    currentFraction: weeklyFraction,
                    resetsAt: weekly.resetsAt
                ))
            }

            state.weekly.fraction = weeklyFraction
            state.weekly.resetsAt = weekly.resetsAt
        }

        states[snapshot.id] = state
    }
}
