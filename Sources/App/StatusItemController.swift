import AppKit
import QuartzCore
import SwiftUI

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
    /// Refetch every provider. Hands back the pass, so the menu can say it is
    /// running and when it is done.
    var onRefreshAll: (() -> Task<Void, Never>?)?
    /// Switch limits in the bar on or off — the same Settings preference,
    /// written back through the same place, never a second one kept here. The
    /// controller stores no answer of its own: it asks `limits.isOn`, which is
    /// the preference mirrored in, and so the tick and Settings are one thing.
    var onToggleLimits: ((Bool) -> Void)?
    /// Open or close one provider's card. Written back through Preferences the
    /// way `onToggleLimits` is, and read back through `expandedDetail`, so the
    /// switch and what the card draws are one thing rather than two.
    var onToggleDetail: ((String, Bool) -> Void)?

    /// Which cards are opened out, mirrored from Preferences.
    ///
    /// The controller keeps no answer of its own: a click asks for the
    /// opposite of what is here, the preference is written, and the new value
    /// arrives back through this — which is what re-measures and redraws the
    /// card, so the menu can be open while it happens.
    var expandedDetail: Set<String> = [] {
        didSet {
            guard expandedDetail != oldValue else { return }
            redrawOpenCards(now: Date())
        }
    }

    /// The latest readings, mirrored from the store. The menu is rebuilt from
    /// these every time it opens, so reset countdowns and ages are fresh; the
    /// item's own summary is redrawn from them as they land.
    var snapshots: [ProviderSnapshot] = [] {
        didSet {
            updateButton()
            // The menu is built when it opens, but a reading can land while it
            // is still up — and a menu bar utility that showed a stale number
            // for as long as you held it open would be the wrong way round.
            redrawOpenCards(now: Date())
        }
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
    /// Normalized activity from the same provider monitors that feed the
    /// notch. Kept separate from usage snapshots: a usage refresh is not work,
    /// and activity never asks a provider to refresh its limits.
    private(set) var activeProviderIDs: Set<String> = []
    private var pulseViews: [NSImageView] = []
    /// Core Animation media time, retained across countdown/artwork rebuilds so
    /// a still-active provider does not visibly restart its cycle every minute.
    private var pulseBeganAt: CFTimeInterval?
    private static let pulseDuration: TimeInterval = 1.2
    private static let pulseMinimumOpacity: CGFloat = 0.62
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
    /// The fleet's panel-less view model: the same readings every notch is
    /// handed, and the same Appearance settings — Watch and Critical, the
    /// accent, how a reset is worded. The cards are drawn from it, so what the
    /// menu says and what the notch says are one thing read twice, never two
    /// things that could drift.
    ///
    /// Held weakly: the fleet owns it for the life of the app, and an item
    /// that outlived it would be holding a model nobody feeds.
    weak var model: NotchViewModel?
    /// Keeps the countdowns on the cards from ageing while the menu is held
    /// open. Only the clock — nothing here reads a provider.
    private var menuClock: Timer?
    /// The menu this controller last filled.
    ///
    /// Held rather than reached for through the status item, because the cards
    /// have to be re-measured and redrawn in whatever menu they were put in —
    /// including one handed straight to `rebuild`, which is how the menu is
    /// read in a test. Weak: the menu belongs to the item, or to the caller.
    private weak var builtMenu: NSMenu?

    /// The menu the cards were last drawn into, so a test can read one card's
    /// view without a status item to hang a menu off.
    var builtMenuForTesting: NSMenu? { builtMenu }
    /// The Refresh all row of that menu, told when a pass it asked for is
    /// running. Weak for the same reason.
    private weak var refreshRow: MenuCommandRowView?
    /// Whether a pass asked for from the menu is still running.
    private var isRefreshing = false {
        didSet { refreshRow?.isBusy = isRefreshing }
    }
    /// Which wait is the current one. A pass can end after the menu has been
    /// closed and another pass asked for, and it must not say the newer one
    /// is done.
    private var refreshWait = 0

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        clearPulseViews(resetPhase: true)
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
            clearPulseViews(resetPhase: true)
            item.length = NSStatusItem.squareLength
            button.image = Self.icon()
            button.toolTip = L10n.t("Codenotch")
            button.setAccessibilityLabel(nil)
            return
        }
        item.length = NSStatusItem.variableLength
        button.imagePosition = .imageOnly
        redrawArtwork()
        let details = next.entries.map(\.detail).joined(separator: "\n")
        button.toolTip = details
        // The image is text VoiceOver cannot read; this says what it shows.
        button.setAccessibilityLabel(details)
    }

    /// Called by the activity coordinator with provider-specific normalized
    /// sessions. Waiting, success and an open-but-idle process are deliberately
    /// static; only actual work (`busy`) pulses.
    func setActivity(providerID: String, sessions: [AgentSession]) {
        let isActive = sessions.contains { $0.state == .busy }
        let changed: Bool
        if isActive {
            changed = activeProviderIDs.insert(providerID).inserted
        } else {
            changed = activeProviderIDs.remove(providerID) != nil
        }
        guard changed else { return }
        redrawArtwork()
    }

    /// Smooth 100% → 62% → 100% pulse. Core Animation runs it in the render
    /// server, so Codenotch does no work between activity state changes.
    static func pulseAnimation(beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = CGFloat(1)
        animation.toValue = pulseMinimumOpacity
        animation.duration = pulseDuration / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        return animation
    }

    private var visibleActiveProviderIDs: Set<String> {
        guard let summary else { return [] }
        return activeProviderIDs.intersection(summary.entries.map(\.id))
    }

    private func redrawArtwork() {
        guard let item, let button = item.button, let summary, !summary.entries.isEmpty else { return }
        let animated = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Set<String>() : visibleActiveProviderIDs
        if animated.isEmpty { pulseBeganAt = nil }
        else if pulseBeganAt == nil { pulseBeganAt = CACurrentMediaTime() }

        clearPulseViews(resetPhase: false)
        let base = StatusItemArtwork(summary: summary,
                                     activeProviderIDs: animated,
                                     activeGlyphOpacity: 0)
        button.image = base.image()
        button.layoutSubtreeIfNeeded()
        guard !animated.isEmpty, let pulseBeganAt else { return }

        let imageRect = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
            ?? button.bounds
        let glyphArtwork = StatusItemArtwork(summary: summary)
        for providerID in animated.sorted() {
            guard let frame = base.glyphFrame(for: providerID),
                  let image = glyphArtwork.glyphImage(for: providerID) else { continue }
            let view = PassThroughStatusImageView(frame: NSRect(
                x: imageRect.minX + frame.minX,
                y: imageRect.minY + frame.minY,
                width: frame.width,
                height: frame.height
            ))
            view.image = image
            view.imageScaling = .scaleNone
            view.contentTintColor = button.contentTintColor ?? .labelColor
            view.wantsLayer = true
            button.addSubview(view)
            if let layer = view.layer {
                let begin = layer.convertTime(pulseBeganAt, from: nil)
                layer.add(Self.pulseAnimation(beginTime: begin), forKey: "providerActivityPulse")
            }
            pulseViews.append(view)
        }
    }

    private func clearPulseViews(resetPhase: Bool) {
        for view in pulseViews { view.removeFromSuperview() }
        pulseViews = []
        if resetPhase { pulseBeganAt = nil }
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        redrawArtwork()
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
        startMenuClock(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuClock?.invalidate()
        menuClock = nil
        // Let go of the menu, or every reading that lands from here on lays
        // out a card per provider for a menu nobody is looking at — and a
        // local runtime republishes every second, so that is N forced layouts
        // a second for the rest of the session. There is nothing on screen to
        // keep current, and the next open rebuilds from scratch anyway.
        builtMenu = nil
        // Stop waiting with the menu. A pass stuck behind a keychain prompt
        // nobody has answered can outlast the store's own deadline, and it
        // would leave every menu after this one saying "Refreshing…".
        refreshWait += 1
        isRefreshing = false
    }

    /// The Refresh all row draws its own highlight — AppKit draws none for a
    /// row with a view — and this is how it learns it is under the pointer or
    /// the arrow keys.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        refreshRow?.isHighlighted = item?.view === refreshRow
    }

    /// A menu held open would otherwise show the countdowns it was built with.
    /// `.common` mode, because AppKit runs a menu in its own tracking mode and
    /// a timer in the default mode would not fire until the menu closed —
    /// which is exactly when it is no longer needed.
    private func startMenuClock(_ menu: NSMenu) {
        menuClock?.invalidate()
        _ = menu
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The cards only, not `model.now`: writing that republishes
                // the model to every notch, and the notches keep their own
                // clocks for exactly this.
                self.redrawOpenCards(now: Date())
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        menuClock = timer
    }

    /// Exposed for tests: what the menu says without needing a status item.
    func rebuild(menu: NSMenu, now: Date) {
        builtMenu = menu
        // The menu is mostly Codenotch's own drawing now, and an opaque card
        // cannot follow a material. Left alone, macOS gives a menu dropped
        // over a dark desktop a dark material while its *appearance* stays
        // Light — which put white cards, correctly drawn for Light, on a menu
        // that looked dark. Asking for the plain system appearance settles it
        // for the cards and for the items around them at once.
        menu.removeAllItems()
        if snapshots.isEmpty {
            let empty = NSMenuItem(title: L10n.t("Waiting for the first reading…"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for snapshot in Self.cardsToDraw(for: snapshots, cells: cells()) {
                menu.addItem(cardItem(for: snapshot, now: now))
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
        menu.addItem(refreshItem())
        if PhoneLink.isAvailable {
            menu.addItem(
                withTitle: L10n.t("Connect Phone…"), action: #selector(connectPhone), keyEquivalent: ""
            ).target = self
        }
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
    @objc private func quit() { NSApp.terminate(nil) }

    /// "Refresh all", as a row the menu stays open for.
    ///
    /// AppKit's own rows cannot stay: a click ends the menu's tracking, the
    /// menu goes, and only then is the action sent — so a refresh took away
    /// the very cards it was for. A row with a view of its own gets the click
    /// instead, the way the cards' Detail switch does, and each card redraws
    /// as its reading lands (see `snapshots`). Return on the row is the row's
    /// own too, and leaves the menu open the way a click does. The title, the
    /// shortcut and the action stay on the item: they are what ⌘R and
    /// VoiceOver use, and those close the menu as any menu command does.
    private func refreshItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("Refresh all"), action: #selector(refreshAll),
                              keyEquivalent: "r")
        item.target = self
        let row = MenuCommandRowView(title: item.title, busyTitle: L10n.t("Refreshing…"),
                                     keyEquivalent: item.keyEquivalent,
                                     modifiers: item.keyEquivalentModifierMask)
        row.isBusy = isRefreshing
        row.onClick = { [weak self] in self?.refreshAll() }
        item.view = row
        refreshRow = row
        return item
    }

    @objc private func refreshAll() {
        guard let pass = onRefreshAll?() else { return }
        refreshWait += 1
        let wait = refreshWait
        isRefreshing = true
        Task { [weak self] in
            await pass.value
            guard let self, self.refreshWait == wait else { return }
            self.isRefreshing = false
        }
    }

    /// Asks for the opposite of what is on now. The answer comes back the way
    /// Settings' own does — through the preference and into `limits` — so the
    /// item redraws once, from one place, and the tick is right the next time
    /// the menu opens whichever switch was used.
    @objc private func toggleLimits() { onToggleLimits?(!limits.isOn) }

    /// One provider's card, as a menu item.
    ///
    /// Drawn from `model` — the fleet's panel-less view model, the same
    /// readings and the same Appearance settings every notch is handed — so
    /// the menu and the notch cannot disagree about a percentage, a band or
    /// the wording of a reset. Nothing is fetched to build it.
    private func cardItem(for snapshot: ProviderSnapshot, now: Date) -> NSMenuItem {
        let item = MenuUsageCardItem.make(
            title: Self.headerTitle(for: snapshot, now: now),
            appearance: menuAppearance,
            onToggle: { [weak self] in self?.toggleDetail(for: snapshot.id) },
            root: { [weak self] onSwitchFrame in
                self?.card(for: snapshot, now: now, onSwitchFrame: onSwitchFrame) ?? AnyView(EmptyView())
            })
        // The card is a picture to VoiceOver. These are the same facts in
        // words — the header, then one line per limit — so the menu is as
        // readable aloud as it is on screen.
        let spoken = [Self.headerTitle(for: snapshot, now: now)]
            + Self.detailLines(for: snapshot, cells: cells(), activity: activity, now: now)
        item.setAccessibilityLabel(spoken.joined(separator: ", "))
        item.representedObject = snapshot.id
        return item
    }

    /// Ask for the opposite of what this card is showing.
    ///
    /// Nothing is decided here: the preference is written, and the answer
    /// comes back through `expandedDetail`, which is what re-measures the card
    /// and tells the menu its item changed height.
    private func toggleDetail(for providerID: String) {
        onToggleDetail?(providerID, !expandedDetail.contains(providerID))
    }

    /// Light or dark, as the Mac is.
    ///
    /// The menu's own items follow the system appearance, so the cards beside
    /// them have to as well — an opaque card cannot work it out for itself,
    /// because a hosting view built before it is installed resolves its colours
    /// against nothing in particular.
    ///
    /// Deliberately *not* the status item button's tone. macOS tints the menu
    /// bar to the desktop behind it, so the button reads dark over a dark
    /// wallpaper while the Mac is in Light — and taking the tone from there
    /// gave black cards under light menu items. The menu bar's tint is about
    /// the bar; the menu is about the Mac.
    private var menuAppearance: NSAppearance? {
        NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
    }

    /// One card, with the Appearance settings the notch is drawn with.
    ///
    /// Read off `model` — the fleet's own — with the shipped defaults as the
    /// fallback for a controller standing on its own. Nothing here is a second
    /// copy of a setting: it is the same object Settings writes through.
    private func card(for snapshot: ProviderSnapshot, now: Date,
                      onSwitchFrame: @escaping (CGRect) -> Void) -> AnyView {
        MenuUsageCardItem.root(
            snapshot: snapshot,
            activity: activity(snapshot),
            now: now,
            resetTimeFormat: model?.resetTimeFormat ?? resetTimeFormat,
            deepSeekPricingEnabled: model?.deepSeekPricingEnabled ?? true,
            deepSeekPricingSchedule: model?.deepSeekPricingSchedule ?? .current,
            // The notch's own budget: as many sessions as the display it is on
            // has room for, so an opened card says what its tooltip says.
            sessionCap: model?.sessionCap ?? NotchLayout.defaultSessionCap,
            accentColor: (model?.accentColor ?? .system).color,
            watchLimit: model?.watchLimit ?? 0.50,
            criticalLimit: model?.criticalLimit ?? 0.70,
            isExpanded: expandedDetail.contains(snapshot.id),
            onToggle: { [weak self] in self?.toggleDetail(for: snapshot.id) },
            // The card reports where its switch landed; the view hosting it
            // hit-tests against that, because a menu runs its own
            // event-tracking loop and a hosted control cannot be relied on to
            // see the click itself.
            //
            // Handed straight to that view. Looking it up in the menu instead
            // could not work on a first open: the card is measured inside
            // `make`, which is where the frame is first reported, and the item
            // it will live on has no `representedObject` — indeed is not in
            // any menu — until `cardItem` returns. The switch stayed dead
            // until something else made the card lay out again.
            onSwitchFrame: onSwitchFrame
        )
    }

    /// Redraw the cards of a menu that is already open.
    ///
    /// A reading that lands while the menu is up, or a countdown that has run
    /// down, changes what a card should say. Rebuilding the menu under AppKit
    /// while it is tracking is the one thing not to do, so each card's hosting
    /// view is handed a fresh root instead: same item, same frame, new
    /// contents. Nothing is fetched — this is the state that already arrived.
    private func redrawOpenCards(now: Date) {
        guard let menu = builtMenu else { return }
        let drawn = Self.cardsToDraw(for: snapshots, cells: cells())
        for menuItem in menu.items {
            guard let id = menuItem.representedObject as? String,
                  let hosting = menuItem.view as? MenuCardHostingView<AnyView>,
                  let snapshot = drawn.first(where: { $0.id == id })
            else { continue }
            hosting.appearance = menuAppearance
            hosting.rootView = card(for: snapshot, now: now) { [weak hosting] frame in
                hosting?.interactiveRect = frame
            }
            // A card that has just opened or closed is a different height, and
            // the menu laid itself out around the old one. Re-measuring and
            // then telling the menu the item changed is what makes it take the
            // new height while it is still on screen.
            MenuUsageCardItem.resize(hosting)
            menu.itemChanged(menuItem)
        }
    }

    /// What gets a card, in the order the menu draws them.
    ///
    /// A local runtime is one card per loaded model, which is what the notch
    /// makes of it — the runtime itself has no quota, its models have. With
    /// nothing loaded there are no model cells, and the runtime keeps a card
    /// of its own so "no models loaded" is still said rather than the provider
    /// silently disappearing from the menu.
    ///
    /// Pure, so the rule can be read off a test without a status item.
    static func cardsToDraw(for snapshots: [ProviderSnapshot],
                            cells: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.flatMap { snapshot -> [ProviderSnapshot] in
            let models = cells.filter { $0.providerID == snapshot.id && $0.localModel != nil }
            return models.isEmpty ? [snapshot] : models
        }
    }

    /// The provider's name, its headline figure, and its age when stale — the
    /// same three facts the card's header shows, as one line of text.
    static func headerTitle(for snapshot: ProviderSnapshot, now: Date) -> String {
        if let model = snapshot.localModel {
            return "\(snapshot.displayName) — \(model.name)"
        }
        var title = "\(snapshot.displayName) — \(headline(for: snapshot))"
        if snapshot.kind == .usage, let since = snapshot.status.staleSince, since != .distantPast {
            title += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        return title
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
            // A cell *is* one model, so it describes itself. Without this a
            // model card had nothing to say: the filter below looks for cells
            // belonging to a runtime, and a cell is not a runtime.
            if snapshot.localModel != nil {
                return [modelLine(for: snapshot, activity: activity(snapshot))]
            }
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

/// The animated glyph sits over the status bar button's static text. It is
/// presentation only and must never steal the click that opens the menu.
private final class PassThroughStatusImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
