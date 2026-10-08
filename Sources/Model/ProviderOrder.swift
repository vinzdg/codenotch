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
        snapshots.enumerated()
            .sorted {
                let (rankA, leftA) = orderKey(for: $0.element)
                let (rankB, leftB) = orderKey(for: $1.element)
                if rankA != rankB { return rankA < rankB }
                if leftA != leftB { return leftA > leftB }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// (tier, headline-remaining): 0 usable, 1 shut with room, 2 fully
    /// empty, 3 nothing measurable. The other window is the weekly one where
    /// the provider has one apart from its headline.
    private static func orderKey(for snapshot: ProviderSnapshot) -> (tier: Int, remaining: Double) {
        guard let used = snapshot.headline?.usedFraction else { return (3, 0) }
        let remaining = 1 - used
        if used >= 1 { return (2, remaining) }
        if let other = snapshot.weeklyWindow?.usedFraction, other >= 1 { return (1, remaining) }
        return (0, remaining)
    }
}
