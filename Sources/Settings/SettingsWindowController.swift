import AppKit
import SwiftUI

/// Hosts the settings sheet in its own window.
///
/// A real window rather than a panel attached to the notch: settings are a place
/// you go, not something you glance at, and a floating panel that follows the
/// notch would be one more thing hovering over the screen edge.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Ends text editing when a click lands anywhere but a text field.
    private var clickAwayMonitor: Any?
    private let preferences: Preferences
    /// A closure, not a snapshot. Read once at launch, the account shown here
    /// went stale the moment someone switched account in Cursor — and stayed
    /// stale until the app was restarted.
    private let providers: () -> [ProviderSummary]
    private let signOut: (String) -> Void
    private let signIn: (String) -> Bool
    private let switchAccount: (String) -> Bool
    private let retry: (String) -> Void
    private let updater: Updater
    private let ollamaRelay: OllamaActivityRelay?
    private let lmstudioMetrics: LMStudioMetrics?
    private let usageStore: UsageStore?
    let phoneLinkPairing: PhoneLinkPairing?
    let phoneLinkRegistry: PhoneLinkRegistry?
    let phoneLinkServerStatus: PhoneLinkServerStatus?
    private let resetPosition: () -> Void
    private let quit: () -> Void
    private let previewResetAlert: (() -> Void)?
    private let previewSessionLimitAlert: (() -> Void)?
    private let previewWeeklyLimitAlert: (() -> Void)?

    init(preferences: Preferences,
         providers: @escaping () -> [ProviderSummary],
         updater: Updater,
         signOut: @escaping (String) -> Void,
         signIn: @escaping (String) -> Bool,
         switchAccount: @escaping (String) -> Bool,
         retry: @escaping (String) -> Void,
         resetPosition: @escaping () -> Void,
         quit: @escaping () -> Void,
         previewResetAlert: (() -> Void)? = nil,
         previewSessionLimitAlert: (() -> Void)? = nil,
         previewWeeklyLimitAlert: (() -> Void)? = nil,
         usageStore: UsageStore? = nil,
         ollamaRelay: OllamaActivityRelay? = nil,
         lmstudioMetrics: LMStudioMetrics? = nil, phoneLinkPairing: PhoneLinkPairing? = nil, phoneLinkRegistry: PhoneLinkRegistry? = nil, phoneLinkServerStatus: PhoneLinkServerStatus? = nil) {
        self.ollamaRelay = ollamaRelay
        self.lmstudioMetrics = lmstudioMetrics
        self.usageStore = usageStore
        self.phoneLinkPairing = phoneLinkPairing
        self.phoneLinkRegistry = phoneLinkRegistry
        self.phoneLinkServerStatus = phoneLinkServerStatus
        self.resetPosition = resetPosition
        self.quit = quit
        self.previewResetAlert = previewResetAlert
        self.previewSessionLimitAlert = previewSessionLimitAlert
        self.previewWeeklyLimitAlert = previewWeeklyLimitAlert
        self.switchAccount = switchAccount
        self.retry = retry
        self.updater = updater
        self.preferences = preferences
        self.providers = providers
        self.signOut = signOut
        self.signIn = signIn
    }

    /// Bring the window to the front from an accessory app.
    ///
    /// `makeKeyAndOrderFront` plus `activate` alone were not enough here: an
    /// accessory app — anything but `AppPresence.dock` — is restricted by
    /// macOS from properly activating and compositing its own windows, so the
    /// window could be created, "visible" by `NSWindow`'s own bookkeeping, and
    /// still never actually drawn on screen (its `occlusionState` missing
    /// `.visible` is what gave this away). A `.regular` app has no such
    /// restriction, so this promotes to one for as long as the window is
    /// open and restores whatever `AppPresence` actually chose once it
    /// closes — settings staying open is the one moment the Dock is allowed
    /// to gain an icon it did not ask for.
    private func surface(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Self.startUnfocused(window)
    }

    /// Opened with nothing being typed in. AppKit hands a window that becomes
    /// key to the first control in its key-view loop — here, whichever text
    /// field the open pane happens to start with — so Settings opened with a
    /// caret blinking in an API key field, and AutoFill offering passwords for
    /// it. Cleared now and once more after SwiftUI's first layout, which is
    /// when a freshly built pane's fields join the loop. Tab still reaches them.
    static func startUnfocused(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak window] in
            guard let window, window.firstResponder is NSText else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// A text field in Settings stayed active — caret blinking, AutoFill's
    /// "Passwords…" bubble hanging under it — until another field took focus,
    /// because AppKit only moves focus between controls that accept it, and
    /// most of this panel (rows, labels, the background) does not. A click
    /// anywhere else in the window now ends the editing. The value is not
    /// lost: the fields bind on every keystroke, and the click still goes
    /// through to whatever it landed on, a Save button included.
    ///
    /// Decided after the click, from where focus actually went, not from what
    /// the click hit: a SwiftUI text field sits inside wrapper views, and
    /// judging by the hit view read a click into another field as a click
    /// away — the new field took focus and was dropped a moment later.
    private func watchForClicksAway(in window: NSWindow) {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window,
                  let edited = Self.editedField(in: window)
            else { return event }
            let fieldFrame = edited.convert(edited.bounds, to: nil)
            guard !Self.isInside(event.locationInWindow, fieldFrame: fieldFrame) else { return event }
            // After the click is delivered, so a button it landed on still sees
            // the edited value, and a field it landed on has taken focus.
            DispatchQueue.main.async { [weak window, weak edited] in
                guard let window, let edited,
                      Self.editedField(in: window) === edited
                else { return }   // focus already moved on, to another field or nowhere
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// The text field being typed in: AppKit edits it through the window's
    /// shared field editor, whose delegate is the field.
    private static func editedField(in window: NSWindow) -> NSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSTextField
    }

    /// Whether a click belongs to the field being edited, allowing a few points
    /// round it for the focus ring and the bezel the eye counts as the field.
    static func isInside(_ point: NSPoint, fieldFrame: NSRect) -> Bool {
        fieldFrame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.appPresence.activationPolicy)
    }

    /// Sit the traffic lights in the middle of the panel's header band.
    ///
    /// Their default place is a title bar's worth from the top, which on a
    /// `fullSizeContentView` window leaves them crowded into the corner of
    /// the sidebar card rather than centred in the row the card's toggle and
    /// the pane's title share. AppKit puts them back on some window events,
    /// so this runs again whenever the window comes forward rather than only
    /// at creation.
    private func layoutTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton,
                       .miniaturizeButton,
                       .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }

        for (index, button) in buttons.enumerated() {
            var frame = button.frame
            frame.origin.x = Self.firstLightCentreX
                + CGFloat(index) * Self.lightSpacing - frame.width / 2
            // Flipped: AppKit measures a window's content from the bottom.
            frame.origin.y = container.bounds.height
                - SettingsView.headerHeight / 2 - frame.height / 2
            button.frame = frame
        }
    }

    /// Centre of the close button, in from the window's left edge, and the
    /// centre-to-centre step to the next one — both measured off the design
    /// this panel is matching.
    private static let firstLightCentreX: CGFloat = 26
    private static let lightSpacing: CGFloat = 22.5

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        layoutTrafficLights(in: window)
    }

    /// Put the window away if it is already in front, otherwise bring it up.
    ///
    /// Only the notch's own gear calls this. A menu item reading "Settings…"
    /// and the first-launch introduction both `show()` instead, because a
    /// command that names a destination should go there rather than toggle.
    ///
    /// The condition is *key*, not merely visible. Clicking the gear while the
    /// window is open but behind something else should fetch it forward — the
    /// intent there is plainly "show me that", and closing it would be the one
    /// thing the click could not have meant.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            // `isReleasedWhenClosed` is false, so this hides it and keeps the
            // window itself for the next `show()`.
            window.close()
            return
        }
        show()
    }

    /// Open the window on one section, named by its raw value ("activity",
    /// "focus"…), the way a menu command that names a destination should.
    func show(section: String) {
        show()
        NotificationCenter.default.post(name: SettingsView.openSection, object: nil,
                                        userInfo: ["section": section])
    }

    func show() {
        if let window {
            // Re-centered every time, not only at creation: a window is
            // positioned once and then just re-surfaced from here on, so if
            // it ever ended up off any connected screen — a display that was
            // reconfigured or disconnected since — every later click would
            // silently bring forward a window that isn't anywhere visible.
            if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                window.center()
            }
            surface(window)
            return
        }

        // As large as the screen comfortably allows, never below the design
        // size: the Activity and Focus sections are charts and tables.
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: SettingsView.width, height: SettingsView.height)
        let size = CGSize(width: min(max(SettingsView.width, visible.width * 0.8), 1400),
                          height: min(max(SettingsView.height, visible.height * 0.85), 1000))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            // `fullSizeContentView` runs the sidebar flush up under the traffic
            // lights, with no separate title strip above it. This reserved a
            // tall blank band once before, but that band was
            // `NavigationSplitView`'s own toolbar — the sidebar is a plain
            // `HStack` now, so there is no toolbar left to reserve for.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Kept for the Window menu and Mission Control; hidden from the bar
        // itself, where the sidebar already names what you are looking at.
        window.title = L10n.t("Codenotch Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A floating rounded panel rather than a square window. The rounded
        // shape is drawn by the content (see `SettingsView.body`), so the
        // window has to stop painting its own square one behind it — hence
        // the clear background, which also lets the corners cut through
        // instead of showing black wedges outside the curve.
        window.isOpaque = false
        window.backgroundColor = .clear
        // The panel is always drawn dark (see `SettingsView.body`); AppKit's
        // own controls inside it — pickers, switches, menus — follow suit.
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true
        window.delegate = self
        watchForClicksAway(in: window)
        // The window itself answers first, not the first text field in it.
        window.initialFirstResponder = nil
        window.contentView = NSHostingView(
            rootView: SettingsView(preferences: preferences,
                                   providers: providers, phoneLinkPairing: phoneLinkPairing, phoneLinkRegistry: phoneLinkRegistry, phoneLinkServerStatus: phoneLinkServerStatus,
                                   signOut: signOut,
                                   signIn: signIn,
                                   switchAccount: switchAccount,
                                   retry: retry,
                                   resetPosition: resetPosition,
                                   quit: quit,
                                   updater: updater,
                                   ollamaRelay: ollamaRelay, lmstudioMetrics: lmstudioMetrics,
                                   usageStore: usageStore,
                                   previewResetAlert: previewResetAlert,
                                   previewSessionLimitAlert: previewSessionLimitAlert,
                                   previewWeeklyLimitAlert: previewWeeklyLimitAlert)
        )
        window.minSize = NSSize(width: SettingsView.minWidth, height: SettingsView.minHeight)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        layoutTrafficLights(in: window)
        surface(window)
    }
}
