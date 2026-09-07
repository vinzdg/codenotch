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
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let onOpenSettings: () -> Void
    /// Refetch one provider, leaving the others alone.
    var onRefreshProvider: ((String) -> Void)?
    /// Refetch every provider.
    var onRefreshAll: (() -> Void)?

    /// The latest readings, mirrored from the store. The menu is rebuilt from
    /// these every time it opens, so reset countdowns and ages are fresh.
    var snapshots: [ProviderSnapshot] = []

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    var isShowing: Bool { item != nil }

    func show() {
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = "Codenotch"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.item = item
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
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
            let empty = NSMenuItem(title: "Waiting for the first reading…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for snapshot in snapshots {
                menu.addItem(headerItem(for: snapshot, now: now))
                for line in Self.detailLines(for: snapshot, now: now) {
                    let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    row.isEnabled = false
                    row.indentationLevel = 1
                    menu.addItem(row)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Refresh all", action: #selector(refreshAll), keyEquivalent: "r"
        ).target = self
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Codenotch", action: #selector(quit), keyEquivalent: "q"
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

    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func refreshProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRefreshProvider?(id)
    }

    @objc private func refreshAll() { onRefreshAll?() }

    /// The provider's own row: name, headline figure, and age when stale — the
    /// same three facts the tooltip header shows. Clicking re-reads it.
    private func headerItem(for snapshot: ProviderSnapshot, now: Date) -> NSMenuItem {
        var title = "\(snapshot.displayName) — \(snapshot.hasReading ? snapshot.headlineText : "—")"
        if let since = snapshot.status.staleSince, since != .distantPast {
            title += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        let header = NSMenuItem(title: title, action: #selector(refreshProvider(_:)), keyEquivalent: "")
        header.target = self
        header.representedObject = snapshot.id
        return header
    }

    /// Everything the tooltip says under its header: the blocked line first,
    /// then one row per limit window, or the status message when there is
    /// nothing metered. Pure, so the wording can be tested without a menu.
    static func detailLines(for snapshot: ProviderSnapshot, now: Date) -> [String] {
        let now = now
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

    /// One metered window on one line: label, percentage burned, and reset —
    /// the same three the tooltip spreads over three lines.
    static func windowLine(for window: LimitWindow, now: Date) -> String {
        var line = "\(window.label): \(window.summary)"
        if let resetsAt = window.resetsAt {
            line += " · \(ResetCopy.text(for: resetsAt, now: now))"
        }
        return line
    }
}
