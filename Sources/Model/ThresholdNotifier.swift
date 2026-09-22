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
    var isPlugin: Bool = false

    /// See `UsageAlertEvent.notifiedName`.
    var notifiedName: String {
        isPlugin ? L10n.t("\(providerName) (plugin)") : providerName
    }
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
                resetsAt: headline.resetsAt,
                isPlugin: snapshot.isPlugin
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
                ? L10n.t("\(alert.notifiedName) limit reached")
                : L10n.t("\(alert.notifiedName) is at \(alert.usedPercent)%")
            if alert.threshold >= 100 {
                content.body = alert.resetsAt.map {
                    L10n.t("Its \(alert.windowLabel.lowercased()) limit is spent — resets \($0.formatted(date: .omitted, time: .shortened))")
                } ?? L10n.t("Its \(alert.windowLabel.lowercased()) limit is spent.")
            } else {
                content.body = L10n.t("\(alert.usedPercent)% of its \(alert.windowLabel.lowercased()) limit used.")
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

/// The out-of-notch end of the usage reset and limit alerts.
///
/// The card in the notch is the primary form; this is what is owed when there
/// is no notch open to put it in — a hidden notch used to swallow the alert
/// silently, which for a weekly limit is the one alert worth not missing.
enum UsageAlertNotifications {
    static func deliver(_ event: UsageAlertEvent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            let window = event.windowLabel.lowercased()
            switch event.kind {
            case .reset:
                content.title = L10n.t("\(event.notifiedName) has reset")
                content.body = L10n.t("Its \(window) limit is available again.")
            case .sessionLimitReached, .weeklyLimitReached:
                content.title = L10n.t("\(event.notifiedName) limit reached")
                content.body = event.resetsAt.map {
                    L10n.t("Its \(window) limit is spent — resets \($0.formatted(date: .omitted, time: .shortened))")
                } ?? L10n.t("Its \(window) limit is spent.")
            }
            // Same threading as the crossing alerts: one pile per provider.
            content.threadIdentifier = event.providerID

            // The kind rather than the window label: the label is display text
            // and changes with the language, and an identifier should not.
            let request = UNNotificationRequest(
                identifier: "\(event.providerID).\(event.kind).\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil)
            center.add(request)
        }
    }
}
