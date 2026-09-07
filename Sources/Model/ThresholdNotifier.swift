import Foundation
import UserNotifications

/// One alert-worthy crossing of a provider's limit.
struct ThresholdAlert: Equatable {
    /// 80 or 100 — the two crossings worth interrupting someone for.
    let threshold: Int
    let providerID: String
    let providerName: String
    let windowLabel: String
    let usedPercent: Int
    let resetsAt: Date?
}

/// Watches the store's snapshots and reports the moment a provider's headline
/// limit crosses 80% or reaches 100%.
///
/// Crossing, not level: a provider parked at 91% must not alert twice, so the
/// highest threshold currently crossed is remembered per provider. The memory
/// clears when the reading drops back below the first threshold — the window
/// has rolled over, and the next climb is a new fact worth announcing.
///
/// The delivery is injected rather than reached for, so the whole rule is
/// testable without ever touching the notification centre.
@MainActor
final class ThresholdNotifier {
    private var crossed: [String: Int] = [:]
    private let isMuted: (String) -> Bool
    private let deliver: (ThresholdAlert) -> Void

    init(isMuted: @escaping (String) -> Bool = { _ in false },
         deliver: @escaping (ThresholdAlert) -> Void = { _ in }) {
        self.isMuted = isMuted
        self.deliver = deliver
    }

    func observe(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            observe(snapshot)
        }
    }

    private func observe(_ snapshot: ProviderSnapshot) {
        guard let fraction = snapshot.usedFraction else { return }
        let percent = fraction * 100
        let level = percent >= 100 ? 100 : percent >= 80 ? 80 : 0

        defer { crossed[snapshot.id] = level }
        let previous = crossed[snapshot.id] ?? 0
        guard level > previous, !isMuted(snapshot.id) else { return }

        guard let headline = snapshot.headline else { return }
        for threshold in [80, 100] where threshold > previous && threshold <= level {
            deliver(ThresholdAlert(
                threshold: threshold,
                providerID: snapshot.id,
                providerName: snapshot.displayName,
                windowLabel: headline.label,
                usedPercent: Int((percent).rounded()),
                resetsAt: headline.resetsAt
            ))
        }
    }
}

/// The side end of `ThresholdNotifier`: permission asked lazily, on the first
/// crossing rather than at launch — a prompt in the first seconds of a first
/// run reads as an app grabbing, one earned by a real event reads as a service.
enum ThresholdAlerts {
    static func deliver(_ alert: ThresholdAlert) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = alert.threshold >= 100
                ? "\(alert.providerName) limit reached"
                : "\(alert.providerName) is at \(alert.usedPercent)%"
            if alert.threshold >= 100 {
                content.body = "Its \(alert.windowLabel.lowercased()) limit is spent"
                    + (alert.resetsAt.map { " — resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ".")
            } else {
                content.body = "\(alert.usedPercent)% of its \(alert.windowLabel.lowercased()) limit used."
            }
            // One thread per provider, so two limits ending together read as
            // two notes, not one merged pile.
            content.threadIdentifier = alert.providerID

            let request = UNNotificationRequest(
                identifier: "\(alert.providerID).\(alert.threshold).\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil)
            center.add(request)
        }
    }
}
