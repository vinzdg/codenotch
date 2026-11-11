import AppKit
import Combine
import SwiftUI

/// Which updates to the usage store's snapshots the cost layer acts on.
///
/// `snapshots` is republished whenever any provider lands, which for a local
/// runtime is once a second, reading or no reading. Acting on each of those
/// wrote a row per window to every account's database and re-ran its queries,
/// for numbers that had not moved. Only a quota can feed the cost layer, so
/// only a change among the usage providers counts as one.
///
/// The heartbeat is there for `CostStore.currentPeriod`, which spreads what it
/// cannot attribute over the turns up to the latest sample, and for anything
/// else that waits on the next pass: a changed price, a new profile. It keeps
/// them at the pace of a usage poll. It is not a timer: the first update after
/// it has elapsed passes, whichever provider that update came from.
struct CostReadingGate {
    static let heartbeat: TimeInterval = 15

    private var last: [ProviderSnapshot]?
    private var passedAt = Date.distantPast

    mutating func admits(_ snapshots: [ProviderSnapshot], at now: Date = Date()) -> Bool {
        let readings = snapshots.filter { $0.kind == .usage }
        guard readings != last || now.timeIntervalSince(passedAt) >= Self.heartbeat else { return false }
        last = readings
        passedAt = now
        return true
    }
}

/// Where the cost layer plugs into the app: the cost models watch the usage
/// store's snapshots, a Claude card borrows the token chart the Codex card
/// has, and the Activity window opens from the menu.
@MainActor
enum Costs {
    private static var subscription: AnyCancellable?
    private static var gate = CostReadingGate()
    private static var activityWindow: NSWindow?

    /// What a Claude login's card gains before the notch draws it: the daily
    /// token chart and summary the Codex server publishes for Codex, built
    /// here from the transcripts Claude Code writes.
    static func decorate(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        // The suite compares cells to what it fed in; the machine's own
        // accounts and transcripts must not leak into that.
        guard !Runtime.isUnderTest, snapshot.tokenUsage == nil,
              let usage = CostModels.model(for: snapshot.id)?.tokenUsage else { return snapshot }
        var snapshot = snapshot
        snapshot.tokenUsage = usage
        return snapshot
    }

    static func attach(to store: UsageStore) {
        _ = PlanCatalog.shared
        _ = PriceTable.shared
        _ = CostAccountStore.shared
        subscription = store.$snapshots
            .receive(on: RunLoop.main)
            .sink { snapshots in
                guard gate.admits(snapshots) else { return }
                CostAccountStore.shared.rediscover()
                CostModels.all.forEach { $0.observe(snapshots) }
            }
    }

    static func showActivity() {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.t("Activity")
            w.minSize = NSSize(width: 900, height: 560)
            w.contentViewController = NSHostingController(rootView: TimelinePane().frame(minWidth: 900, minHeight: 560))
            w.isReleasedWhenClosed = false
            w.center()
            activityWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        activityWindow?.makeKeyAndOrderFront(nil)
    }
}
