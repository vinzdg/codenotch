import Foundation

/// The ring led by the fullest limit a provider reports, instead of the one it
/// declares: a spent week or month reads 100% while the five-hour window is
/// empty, and the ring falls back to the shorter window when the long one
/// resets.
///
/// Three kinds of window compete: the declared headline, the declared weekly
/// one, and any ungrouped, non-monetary window longer than both a week and the
/// headline (OpenCode's month). A sibling in the same cycle as the headline
/// (Cursor's API bucket, Copilot's chat quota) is not longer, so it never takes
/// the ring from the plan's own figure. A tie keeps the declared headline.
/// When the weekly window wins, the old headline takes the thin ring; when a
/// longer one wins, the thin ring stays on the week.
///
/// Antigravity is left to its own "Notch reads" choice, and Claude's daily
/// pace ring, laid after this, still replaces the ring where it is on.
///
/// Laid over the snapshots on the way out, like `WeeklyHeadline`: the store and
/// the alert watchers keep what the vendor said.
enum FullestHeadline {
    static let longWindow: TimeInterval = 7 * 86_400

    static func apply(to snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard !AntigravityProfile.isAntigravity(providerID: snapshot.providerID),
              let declared = snapshot.headline, let declaredUsed = declared.usedFraction
        else { return snapshot }

        let longer = max(longWindow, declared.duration ?? 0)
        let fullest = snapshot.windows
            .filter { window in
                guard window.usedFraction != nil else { return false }
                if window.id == declared.id || window.id == snapshot.weeklyID { return true }
                return window.group == nil && window.money == nil && (window.duration ?? 0) > longer
            }
            .max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
        guard let fullest, fullest.id != declared.id,
              (fullest.usedFraction ?? 0) > declaredUsed
        else { return snapshot }

        var led = snapshot
        led.headlineID = fullest.id
        if fullest.id == snapshot.weeklyID { led.weeklyID = declared.id }
        return led
    }

    static func apply(to snapshots: [ProviderSnapshot], enabled: Bool) -> [ProviderSnapshot] {
        guard enabled else { return snapshots }
        return snapshots.map(apply(to:))
    }
}
