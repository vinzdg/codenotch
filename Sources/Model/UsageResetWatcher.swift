import Foundation

/// The kind of usage alert event.
enum UsageAlertKind: Equatable {
    case reset
    case sessionLimitReached
    case weeklyLimitReached
}

/// One alert event for a provider's usage window (reset or limit reached).
struct UsageAlertEvent: Equatable {
    let kind: UsageAlertKind
    let providerID: String
    let providerName: String
    let windowLabel: String
    let glyph: ProviderGlyph
    let previousFraction: Double
    let currentFraction: Double
    let resetsAt: Date?
    /// Set for a notice that is not a reset or a limit (a threshold crossing
    /// on the notch channel, a test): the card shows these words instead of
    /// the kind's own.
    var noticeTitle: String? = nil
    var noticeSubtitle: String? = nil
    var noticeStatus: String? = nil

    init(
        kind: UsageAlertKind = .reset,
        providerID: String,
        providerName: String,
        windowLabel: String,
        glyph: ProviderGlyph,
        previousFraction: Double,
        currentFraction: Double,
        resetsAt: Date?
    ) {
        self.kind = kind
        self.providerID = providerID
        self.providerName = providerName
        self.windowLabel = windowLabel
        self.glyph = glyph
        self.previousFraction = previousFraction
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
    }
}

typealias UsageResetEvent = UsageAlertEvent

/// Watches store snapshots and detects when a provider's limit window rolls over
/// or its usage drops back down to reset levels.
@MainActor
final class UsageResetWatcher {
    private struct TrackedState {
        var fraction: Double
        var resetsAt: Date?
        var peakFraction: Double
        var lastAlertedResetDate: Date?
    }

    private var states: [String: TrackedState] = [:]
    private let isMuted: (String) -> Bool
    private let deliver: (UsageResetEvent) -> Void
    private let now: () -> Date

    init(
        isMuted: @escaping (String) -> Bool = { _ in false },
        deliver: @escaping (UsageResetEvent) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.isMuted = isMuted
        self.deliver = deliver
        self.now = now
    }

    func observe(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            observe(snapshot)
        }
    }

    private func observe(_ snapshot: ProviderSnapshot) {
        // An archived reading is not a baseline: at launch the store publishes
        // the last run's snapshot, marked stale, and the live fetch that
        // follows carries a newer reset date or a lower fraction, both of
        // which read as a reset. That was "Claude has reset" two seconds
        // after every start. Forgetting the provider here makes the first
        // live reading the one that only records.
        guard !snapshot.status.isStale else {
            states.removeValue(forKey: snapshot.id)
            return
        }
        guard let headline = snapshot.headline,
              let fraction = snapshot.usedFraction else { return }

        guard var previous = states[snapshot.id] else {
            states[snapshot.id] = TrackedState(
                fraction: fraction,
                resetsAt: headline.resetsAt,
                peakFraction: fraction,
                lastAlertedResetDate: headline.resetsAt
            )
            return
        }

        // A later reset timestamp alone is not evidence of a reset: APIs which
        // report a relative countdown can move that timestamp by a few seconds
        // on every refresh. The previous window must have actually elapsed
        // before its replacement can announce a reset.
        let previousWindowElapsed = previous.resetsAt.map { $0 <= now() } ?? false
        let isDateRolled = previousWindowElapsed
            && headline.resetsAt != nil
            && previous.resetsAt != nil
            && headline.resetsAt! > previous.resetsAt!
            && (previous.lastAlertedResetDate == nil || headline.resetsAt! > previous.lastAlertedResetDate!)

        let droppedSignificantly = fraction < previous.fraction
            && (previous.fraction - fraction >= 0.20 || (previous.peakFraction >= 0.30 && fraction <= 0.10))

        let hadSignificantUsage = previous.peakFraction >= 0.15

        // A percentage-only fallback, for providers that give no reset
        // timestamp at all, and for the reading after a deadline has passed
        // whose new window comes back without one (a CLI line that did not
        // parse, a window that reports null until first used). Before a known
        // deadline, a lower reading is a correction or fluctuation, not a reset.
        let canInferResetFromDrop = droppedSignificantly
            && (previous.resetsAt == nil || previousWindowElapsed)

        if (isDateRolled || canInferResetFromDrop) && hadSignificantUsage && !isMuted(snapshot.id) {
            let event = UsageResetEvent(
                providerID: snapshot.id,
                providerName: snapshot.displayName,
                windowLabel: headline.label,
                glyph: snapshot.glyph,
                previousFraction: previous.fraction,
                currentFraction: fraction,
                resetsAt: headline.resetsAt
            )
            deliver(event)

            previous.fraction = fraction
            previous.peakFraction = fraction
            previous.resetsAt = headline.resetsAt
            previous.lastAlertedResetDate = headline.resetsAt
            states[snapshot.id] = previous
        } else {
            previous.fraction = fraction
            previous.peakFraction = max(previous.peakFraction, fraction)
            previous.resetsAt = headline.resetsAt
            states[snapshot.id] = previous
        }
    }
}
