import Foundation

/// The rule that turns a remembered order into a real one.
///
/// The awkward part is not applying an order, it is that the set of providers is
/// not fixed: Claude Code contributes one per `~/.claude-<slug>` found at launch,
/// so an id can appear on a Mac that has never seen it and vanish from one that
/// has. A stored order is a preference to reconcile, never an authority.
enum ProviderOrder {
    /// A runtime's inventory can arrive alphabetically on every poll. Keep its
    /// existing cells in place and append newly loaded models.
    static func cells(from snapshots: [ProviderSnapshot],
                      keeping previous: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.flatMap { snapshot in
            let cells = snapshot.notchSnapshots
            return snapshot.kind == .localRuntime
                ? arrange(cells, by: previous.map(\.id), id: \.id) : cells
        }
    }

    /// `items` in the user's order, then everything the order has never seen, in
    /// the order it arrived in.
    ///
    /// Idempotent, which is what lets the store re-apply it to an already-sorted
    /// `snapshots` without the rings shuffling.
    static func arrange<T>(_ items: [T], by order: [String], id: (T) -> String) -> [T] {
        guard !order.isEmpty else { return items }

        var remaining = items
        var arranged: [T] = []
        for providerID in order {
            // A stored id no provider claims is the ordinary case, not
            // corruption: a `~/.claude-work` that is not on this Mac today.
            guard let index = remaining.firstIndex(where: { id($0) == providerID })
            else { continue }
            arranged.append(remaining.remove(at: index))
        }
        // Appended rather than dropped: a provider added by a new version has to
        // turn up somewhere, and the end is the one position that is never a lie
        // about what the user chose.
        return arranged + remaining
    }

    /// Where a provider goes when it is switched back on: after the ones already
    /// connected, rather than back to wherever it used to sit.
    ///
    /// Restoring its old place would make off/on a perfect round trip, which is
    /// tempting — but it lets a row that was not on screen outrank one the user
    /// deliberately dragged to the top while it was away. Landing at the end is
    /// never a surprise, and it is one drag to fix.
    static func joiningConnected(_ id: String, in order: [String],
                                 isConnected: (String) -> Bool) -> [String] {
        var rest = order.filter { $0 != id }
        // Nothing connected at all makes it the first, not the last.
        let insertAt = rest.lastIndex(where: isConnected).map { $0 + 1 } ?? 0
        rest.insert(id, at: insertAt)
        return rest
    }

    /// The order to remember, given the order now on screen.
    ///
    /// Ids that are remembered but not visible are kept, at the end: a Claude
    /// profile whose directory is not on this Mac today must not lose its place
    /// because an unrelated row moved.
    static func remember(_ visible: [String], keeping remembered: [String]) -> [String] {
        visible + remembered.filter { !visible.contains($0) }
    }

    /// Auto-order: most remaining first, by the window that leads each cell.
    ///
    /// The headline is whatever the derivations left leading — the weekly
    /// window where that is switched on, the 5-hour (or primary) one
    /// otherwise — so "more weekly up" and "more 5-hour up" are the same rule
    /// read off different leads. Tiers, then remaining within them:
    ///
    /// - usable first, most remaining at the top;
    /// - shut with room next: a high main number that cannot be spent because
    ///   the other window is empty sinks below everything usable, but stays
    ///   above what is fully empty;
    /// - fully empty after that — the headline itself spent;
    /// - unmeasurable last: no reading yet, or a runtime with no quota.
    ///
    /// Stable by arrival order, which is the manual order: ties, and the
    /// unmeasurable trailing group, keep the arrangement dragging made.
    static func byRemainingUsage(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        sorted(snapshots) { orderKey(for: $0, leading: $0.headline) }
    }

    /// The same rule read off the five-hour window, for the menu bar.
    ///
    /// The bar prints that window whatever the notch's rings are leading
    /// with, and it has four places with the countdowns in the first of them
    /// — so here the order decides what is said about an account and whether
    /// it is said at all. Sorting it by a figure it is not showing would be
    /// the same fault as printing one.
    static func byRemainingFiveHour(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        sorted(snapshots) { orderKey(for: $0, leading: $0.fiveHourWindow) }
    }

    /// Tier, then remaining within it, then arrival — which is the manual
    /// order, so ties keep the arrangement dragging made.
    private static func sorted(_ snapshots: [ProviderSnapshot],
                               by key: (ProviderSnapshot) -> (tier: Int, remaining: Double))
    -> [ProviderSnapshot] {
        snapshots.enumerated()
            .sorted {
                let (rankA, leftA) = key($0.element)
                let (rankB, leftB) = key($1.element)
                if rankA != rankB { return rankA < rankB }
                if leftA != leftB { return leftA > leftB }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// (tier, remaining of the leading window): 0 usable, 1 shut with room,
    /// 2 fully empty, 3 nothing measurable. The other window is the weekly
    /// one where the provider has one apart from its headline.
    private static func orderKey(for snapshot: ProviderSnapshot,
                                 leading window: LimitWindow?) -> (tier: Int, remaining: Double) {
        guard let used = window?.usedFraction else { return (3, 0) }
        let remaining = 1 - used
        if used >= 1 { return (2, remaining) }
        if let other = snapshot.weeklyWindow?.usedFraction, other >= 1 { return (1, remaining) }
        return (0, remaining)
    }

    /// Auto-order by burn deficit: most quota expiring soonest first.
    ///
    /// The deficit is remaining quota minus remaining time, in points —
    /// 70% left with 23h of a week left is ~56 points to burn, while 100%
    /// with 6 days left is ~14. Sorting most-to-burn first puts the
    /// use-it-or-lose-it ring at the front, where most-remaining would put
    /// the fresh 100% first and let the expiring 70% die.
    ///
    /// Rings are ordered by expiry: the quota that is about to be wasted
    /// (soonest reset) goes first, so it is used before it dies — earliest
    /// deadline first. The deficit is still the leading window's, like the
    /// remaining figure in `byRemainingUsage`: the weekly window where the
    /// week is the main ring, the 5-hour one where it is not. Tiers mirror
    /// `byRemainingUsage` so spent and unmeasurable rings still sink — only
    /// the order within usable timed rings changes, from soonest expiry to
    /// latest:
    ///
    /// - timed usable first, most to burn at the top (over-pace, negative
    ///   burn, sinks to the bottom of this tier — nothing to waste there);
    /// - timeless usable next, most remaining first (no clock, no deficit);
    /// - shut with room next, then fully empty, then unmeasurable last.
    ///
    /// Stable by arrival order, which is the manual order: ties, and the
    /// unmeasurable trailing group, keep the arrangement dragging made.
    static func byBurnDeficit(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        snapshots.enumerated()
            .sorted {
                let (rankA, subA, resetA, leftA) = deficitOrderKey(for: $0.element, now: now)
                let (rankB, subB, resetB, leftB) = deficitOrderKey(for: $1.element, now: now)
                if rankA != rankB { return rankA < rankB }
                if subA != subB { return subA < subB }
                // Usable timed rings (tier 0): soonest expiry first, so the
                // quota about to be wasted is used before it dies — earliest
                // deadline first. Remaining is the tie-break: among rings that
                // reset together, burn the larger amount first.
                if rankA == 0 {
                    switch (resetA, resetB) {
                    case let (a?, b?):
                        if a != b { return a < b }
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil): break
                    }
                }
                if leftA != leftB { return leftA > leftB }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// Auto-order by expiring first: the ring whose main window resets
    /// soonest comes first, so quota about to reset (and be lost) is used
    /// before it dies. A ring whose main ring or weekly allowance is spent
    /// sinks to the end, and unmeasurable rings trail in manual order.
    ///
    /// Unlike burn deficit, no burn/pace sub-tier is applied: every timed
    /// usable ring sorts purely by its reset deadline, soonest first.
    static func byExpiringFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        snapshots.enumerated()
            .sorted {
                let keyA = expiringOrderKey(for: $0.element)
                let keyB = expiringOrderKey(for: $1.element)
                if keyA.tier != keyB.tier { return keyA.tier < keyB.tier }
                // Usable timed rings (tier 0): soonest reset first.
                if keyA.tier == 0 {
                    switch (keyA.resetAt, keyB.resetAt) {
                    case let (a?, b?):
                        if a != b { return a < b }
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil): break
                    }
                }
                if keyA.remaining != keyB.remaining { return keyA.remaining > keyB.remaining }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    // Aliases, so whichever spelling a caller reaches for resolves.
    static func byExpiring(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiresFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiringSoon(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func bySoonestReset(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byClosestReset(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func bySoonestExpiry(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiryFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byResetFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byResetsFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byEarliestReset(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byNextReset(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiringSoonest(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byClosestResetFirst(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiringUsage(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byUsageExpiring(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiringReset(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byEarliestExpiry(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func bySoonestDeadline(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byNextExpiry(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }
    static func byExpiry(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        byExpiringFirst(snapshots, now: now)
    }

    /// (tier, reset of the leading window, headline-remaining): 0 timed
    /// usable (main ring has a reset and is not spent), 1 timeless usable,
    /// 2 spent (main ring or weekly allowance at 0%), 3 nothing measurable.
    private static func expiringOrderKey(for snapshot: ProviderSnapshot) -> (tier: Int, resetAt: Date?, remaining: Double) {
        guard let used = snapshot.headline?.usedFraction else { return (3, nil, 0) }
        let remaining = 1 - used
        let resetAt = snapshot.headline?.resetsAt
        let weeklyUsed = snapshot.weeklyWindow?.usedFraction
        if used >= 1 || (weeklyUsed ?? 0) >= 1 {
            return (2, resetAt, remaining)
        }
        if resetAt != nil {
            return (0, resetAt, remaining)
        }
        return (1, nil, remaining)
    }

    /// (tier, sub-tier, soonest reset of the leading window,
    /// headline-remaining): 0 timed usable (0 under-pace waste risk,
    /// 1 over-pace, nothing to waste), 1 timeless usable, 2 shut with room,
    /// 3 fully empty, 4 nothing measurable.
    private static func deficitOrderKey(for snapshot: ProviderSnapshot, now: Date) -> (tier: Int, subTier: Int, resetAt: Date?, remaining: Double) {
        guard let used = snapshot.headline?.usedFraction else { return (4, 0, nil, 0) }
        let remaining = 1 - used
        let resetAt = snapshot.headline?.resetsAt
        if used >= 1 { return (3, 0, resetAt, remaining) }
        if let other = snapshot.weeklyWindow?.usedFraction, other >= 1 {
            return (2, 0, resetAt, remaining)
        }
        // Usable: timed sorts by soonest expiry, timeless by what is left.
        if snapshot.headline?.burnDeficitPoints(now: now) != nil {
            // Under-pace (positive burn, quota left unused) is the waste
            // risk and goes first; over-pace (negative burn) will run out
            // on its own and sinks below it.
            let burn = snapshot.headlineBurnDeficit(now: now) ?? 0
            let subTier = burn > 0 ? 0 : 1
            return (0, subTier, resetAt, remaining)
        }
        return (1, 0, nil, remaining)
    }
}
