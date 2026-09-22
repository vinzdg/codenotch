import AppKit

/// The menu bar icon, present only while `AppPresence.menuBar` is chosen.
///
/// It exists to be a way *into* the app, so it opens settings and offers Quit —
/// with no Dock tile there is otherwise nothing to right-click, and an app you
/// cannot quit is a worse problem than one you cannot see.
///
/// It also carries the same readings as the notch tooltips, so `NotchVisibility`
/// hidden stays usable: with the notch off screen the menu is where the
/// percentages, resets and stale ages live.
///
/// The item itself is the plain icon unless Settings switches on limits in
/// the menu bar. Then it shows each chosen provider's five-hour window at a
/// glance — "72% · 2h 18m" beside the provider's mark — and is the icon again
/// whenever none of them has such a window to show. See `StatusItemSummary`.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let onOpenSettings: () -> Void
    /// Refetch one provider, leaving the others alone.
    var onRefreshProvider: ((String) -> Void)?
    /// Refetch every provider.
    var onRefreshAll: (() -> Void)?
    /// Switch limits in the bar on or off — the same Settings preference,
    /// written back through the same place, never a second one kept here. The
    /// controller stores no answer of its own: it asks `limits.isOn`, which is
    /// the preference mirrored in, and so the tick and Settings are one thing.
    var onToggleLimits: ((Bool) -> Void)?

    /// The latest readings, mirrored from the store. The menu is rebuilt from
    /// these every time it opens, so reset countdowns and ages are fresh; the
    /// item's own summary is redrawn from them as they land.
    var snapshots: [ProviderSnapshot] = [] {
        didSet { updateButton() }
    }
    /// Whether the item shows limits at all, and whose — from Settings. Only
    /// the item's face follows it: the menu still lists every provider read.
    ///
    /// Redrawn at once from the readings already here, so answering it never
    /// waits for, or asks for, a fetch.
    var limits: MenuBarLimits = .off {
        didSet {
            guard limits != oldValue else { return }
            updateButton()
        }
    }
    /// How a reset time is worded, from Settings. The notch follows this, and
    /// the item's tooltip is the same sentence, so it follows it too.
    var resetTimeFormat: ResetTimeFormat = .automatic {
        didSet {
            guard resetTimeFormat != oldValue else { return }
            updateButton()
        }
    }
    /// Adds the compact weekly-consumption ring to each provider that has a
    /// valid weekly reading. Presentation only; changing it redraws from the
    /// snapshots already held here and never asks the store to refresh.
    var showsWeeklyLimit: Bool = false {
        didSet {
            guard showsWeeklyLimit != oldValue else { return }
            updateButton()
        }
    }
    /// What the item shows now, so a publication that changes nothing on it —
    /// a local runtime is re-read every second — redraws nothing.
    private var summary: StatusItemSummary?
    /// Wakes the item when its first countdown next changes, since the minutes
    /// run down between readings. One-shot and re-armed on every update: a
    /// minute's precision is all the bar shows.
    private var countdownTimer: Timer?
    /// The notch's decorated cells, read when the menu opens. A local runtime's
    /// own snapshot only lists its models; what each one is doing, how fast it
    /// answered and what it cost today are put on the cells by the view model,
    /// and the menu says the same things the cells do.
    var cells: () -> [ProviderSnapshot] = { [] }
    var activity: (ProviderSnapshot) -> ActivitySummary? = { _ in nil }

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    var isShowing: Bool { item != nil }

    func show() {
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = L10n.t("Codenotch")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.item = item
        updateButton()
    }

    func hide() {
        guard let item else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        summary = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: - Summary

    /// Redraws the item from the latest readings, and arranges to do so again
    /// when the first countdown on it next changes.
    ///
    /// Nothing here reads or refreshes usage: the store owns that, and it
    /// already re-reads on its first tick after a window resets. When the
    /// countdown reaches zero the item shows a dash until that reading lands.
    /// With limits off there is no countdown, so nothing is left to wake it.
    private func updateButton(now: Date = Date()) {
        guard let item, let button = item.button else { return }
        let next = StatusItemSummary.make(from: snapshots, showing: limits, now: now,
                                          format: resetTimeFormat,
                                          showingWeeklyLimit: showsWeeklyLimit)
        scheduleCountdown(at: next.nextChange)
        guard next != summary else { return }
        summary = next

        if next.entries.isEmpty {
            item.length = NSStatusItem.squareLength
            button.image = Self.icon()
            button.toolTip = L10n.t("Codenotch")
            button.setAccessibilityLabel(nil)
            return
        }
        item.length = NSStatusItem.variableLength
        button.image = StatusItemArtwork(summary: next).image()
        button.imagePosition = .imageOnly
        let details = next.entries.map(\.detail).joined(separator: "\n")
        button.toolTip = details
        // The image is text VoiceOver cannot read; this says what it shows.
        button.setAccessibilityLabel(details)
    }

    private func scheduleCountdown(at change: Date?) {
        // Just past the change, so the minute counted on waking is the new one.
        let fireDate = change?.addingTimeInterval(0.1)
        if let countdownTimer, countdownTimer.isValid, countdownTimer.fireDate == fireDate { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard let fireDate else { return }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton() }
        }
        // Late by a second is invisible at a minute's precision, and lets the
        // system fold this wake-up into others.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    // MARK: - Menu

    /// Rebuilt on every open rather than on every fetch: a menu built at fetch
    /// time would freeze "Resets in 51 min" and "20 hr ago" until the next
    /// reading lands.
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu: menu, now: Date())
    }

    /// Exposed for tests: what the menu says without needing a status item.
    func rebuild(menu: NSMenu, now: Date) {
        menu.removeAllItems()
        if snapshots.isEmpty {
            let empty = NSMenuItem(title: L10n.t("Waiting for the first reading…"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let cells = cells()
            for snapshot in snapshots {
                menu.addItem(headerItem(for: snapshot, now: now))
                for line in Self.detailLines(for: snapshot, cells: cells, activity: activity, now: now) {
                    let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    row.isEnabled = false
                    row.indentationLevel = 1
                    menu.addItem(row)
                }
            }
        }
        menu.addItem(.separator())
        // The one Settings switch, within reach of the bar it changes: a tick
        // beside its own wording, which is how macOS writes a setting into a
        // menu. It sits with the utilities rather than the readings, because
        // it is about the item rather than any provider on it.
        let showLimits = NSMenuItem(
            title: L10n.t("Show limit information in menu bar"),
            action: #selector(toggleLimits), keyEquivalent: ""
        )
        showLimits.target = self
        showLimits.state = limits.isOn ? .on : .off
        menu.addItem(showLimits)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Refresh all"), action: #selector(refreshAll), keyEquivalent: "r"
        ).target = self
        if PhoneLink.isAvailable {
            menu.addItem(
                withTitle: L10n.t("Connect Phone…"), action: #selector(connectPhone), keyEquivalent: ""
            ).target = self
        }
        menu.addItem(
            withTitle: L10n.t("Focus…"), action: #selector(openFocus), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: L10n.t("Settings…"), action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Quit Codenotch"), action: #selector(quit), keyEquivalent: "q"
        ).target = self
    }

    /// The menu bar mark: its own drawing, not the app icon shrunk down.
    ///
    /// A template image, which is what lets macOS tint it — dark on a light
    /// menu bar, light on a dark one, and correct against a wallpaper-tinted
    /// bar without the app knowing any of that. The full-colour app icon can do
    /// none of it: it would fight every system item beside it and ignore the
    /// user's appearance entirely.
    ///
    /// Vector, so it is drawn at whatever the bar asks for rather than scaled
    /// from a fixed bitmap.
    static func icon() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        // Menu bar items are laid out on an 18pt square; taller and macOS
        // clips it, shorter and it floats.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

@objc private func connectPhone() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openConnectPhone()
        }
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func openFocus() { Tasks.showFocus() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func refreshProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRefreshProvider?(id)
    }

    @objc private func refreshAll() { onRefreshAll?() }

    /// Asks for the opposite of what is on now. The answer comes back the way
    /// Settings' own does — through the preference and into `limits` — so the
    /// item redraws once, from one place, and the tick is right the next time
    /// the menu opens whichever switch was used.
    @objc private func toggleLimits() { onToggleLimits?(!limits.isOn) }

    /// The provider's own row: name, headline figure, and age when stale — the
    /// same three facts the tooltip header shows. Clicking re-reads it.
    private func headerItem(for snapshot: ProviderSnapshot, now: Date) -> NSMenuItem {
        var title = "\(snapshot.displayName) — \(Self.headline(for: snapshot))"
        if snapshot.kind == .usage, let since = snapshot.status.staleSince, since != .distantPast {
            title += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        let header = NSMenuItem(title: title, action: #selector(refreshProvider(_:)), keyEquivalent: "")
        header.target = self
        header.representedObject = snapshot.id
        return header
    }

    /// A runtime has no headline figure of its own; its models have. The row
    /// says how many there are, and the lines under it say the rest.
    static func headline(for snapshot: ProviderSnapshot) -> String {
        if snapshot.kind == .localRuntime {
            return snapshot.localRuntime?.summary ?? "—"
        }
        return snapshot.hasReading ? snapshot.headlineText : "—"
    }

    /// Everything the tooltip says under its header: the blocked line first,
    /// then one row per limit window, or the status message when there is
    /// nothing metered. For a local runtime, one line per loaded model, built
    /// from its decorated cell. Pure, so the wording can be tested without a
    /// menu.
    static func detailLines(for snapshot: ProviderSnapshot, cells: [ProviderSnapshot] = [],
                            activity: (ProviderSnapshot) -> ActivitySummary? = { _ in nil },
                            now: Date) -> [String] {
        let now = now
        if snapshot.kind == .localRuntime {
            let models = cells.filter { $0.providerID == snapshot.id && $0.localModel != nil }
            guard models.isEmpty else { return models.map { modelLine(for: $0, activity: activity($0)) } }
            // The header already says "No models loaded"; only a failure to
            // reach the server is worth a line of its own.
            return snapshot.localRuntime == nil ? [snapshot.statusMessage].compactMap { $0 } : []
        }
        if let block = snapshot.block {
            var lines = [block.summary(now: now)]
            lines += snapshot.windows.map { windowLine(for: $0, now: now) }
            return lines
        }
        if let message = snapshot.statusMessage {
            return [message]
        }
        return snapshot.windows.map { windowLine(for: $0, now: now) }
    }

    /// One loaded model on one line: what its cell prints, what it is doing,
    /// how full its context was, and what it cost today — the tooltip's rows,
    /// in the order the eye wants them.
    static func modelLine(for cell: ProviderSnapshot, activity: ActivitySummary?) -> String {
        guard let model = cell.localModel else { return cell.headlineText }
        var parts = [cell.headlineText]
        if let activity, activity.state == .working {
            parts.append(activity.note ?? activity.sessions.first?.name ?? L10n.t("Thinking"))
        }
        if let fraction = cell.localContextFraction {
            parts.append(L10n.t("Context \(Percent.text(for: fraction))%"))
        }
        if let ledger = cell.localLedger {
            parts.append(L10n.t("Today \(ledger.tokensTodayText)"))
        }
        return "\(model.name): \(parts.joined(separator: " · "))"
    }

    /// One metered window on one line: label, percentage burned, and reset —
    /// the same three the tooltip spreads over three lines.
    static func windowLine(for window: LimitWindow, now: Date,
                           format: ResetTimeFormat = .automatic) -> String {
        var line = "\(window.label): \(window.summary)"
        if let resetsAt = window.resetsAt {
            line += " · \(ResetCopy.text(for: resetsAt, now: now, format: format))"
        }
        return line
    }
}
