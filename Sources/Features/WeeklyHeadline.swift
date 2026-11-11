import Foundation

/// The weekly limit as the big ring, for every provider that publishes one
/// beside a shorter window.
///
/// The short window resets every few hours; the weekly one is the limit that
/// actually runs out, and the one that decides when to move to another account.
/// With both on the notch, the big ring was the short one and the week sat in
/// the hover card or a thin second ring. This leads with the week instead: the
/// big ring becomes the weekly window, the thin ring — where one is switched
/// on — the short one, and nothing leaves the card.
///
/// Decided by how long the window is, not by what it is called. A provider's
/// `weeklyID` is whatever it draws as the second ring, and that is not always a
/// week: Grok's is its credits, and Codex can report the week as its primary
/// window with the five-hour one second. So the swap happens only when the
/// second window really runs about a week *and* is longer than the one leading
/// — anything else is returned untouched. A provider with no second window,
/// Cursor's monthly cycle among them, has nothing to swap.
///
/// Like `DailyPace`, it is laid over the snapshots on the way out: it is a
/// reading of a preference as much as of the account, and the store keeps what
/// the vendor said. Applied first, so the daily pace ring — the more specific
/// of the two, and Claude's alone — still wins where both are switched on.
enum WeeklyHeadline {
    /// A week, give or take a day either side: vendors report the length they
    /// meter, and none reports it to the second.
    static let week: ClosedRange<TimeInterval> = (6 * 86_400)...(8 * 86_400)

    static func apply(to snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard let weeklyID = snapshot.weeklyID,
              weeklyID != snapshot.headlineID,
              let weekly = snapshot.windows.first(where: { $0.id == weeklyID }),
              let weeklyLength = weekly.duration, week.contains(weeklyLength)
        else { return snapshot }

        let headline = snapshot.windows.first { $0.id == snapshot.headlineID }
        // Already leading with something at least as long: nothing to gain.
        if let headlineLength = headline?.duration, headlineLength >= weeklyLength {
            return snapshot
        }

        var led = snapshot
        led.headlineID = weeklyID
        led.weeklyID = headline?.id
        return led
    }

    static func apply(to snapshots: [ProviderSnapshot], enabled: Bool) -> [ProviderSnapshot] {
        guard enabled else { return snapshots }
        return snapshots.map(apply(to:))
    }
}
