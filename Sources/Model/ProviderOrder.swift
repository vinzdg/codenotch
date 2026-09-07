import Foundation

/// The rule that turns a remembered order into a real one.
///
/// The awkward part is not applying an order, it is that the set of providers is
/// not fixed: Claude Code contributes one per `~/.claude-<slug>` found at launch,
/// so an id can appear on a Mac that has never seen it and vanish from one that
/// has. A stored order is a preference to reconcile, never an authority.
enum ProviderOrder {
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
}
