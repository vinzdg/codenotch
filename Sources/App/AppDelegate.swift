import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var store: UsageStore?
    private var monitors: [String: any AgentActivityMonitor] = [:]
    private var preferences: Preferences?
    private var settings: SettingsWindowController?
    private var whatsNew: WhatsNewWindowController?
    /// Held for the life of the app: releasing it stops the scheduled checks.
    private var updater: Updater?
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    /// The unit bundle is hosted by this app, so `xcodebuild test` launches it
    /// for real. Without this guard every test run put a live request on the
    /// usage endpoint — which is both wrong on its own terms and, on an endpoint
    /// that rate-limits, actively harmful.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Every Claude Code configuration directory on this Mac — `~/.claude` and
    /// any `~/.claude-<slug>` — found once at launch. Each gets a usage
    /// provider and a session monitor of its own, keyed by the same id, so a
    /// work login's sessions spin the work ring and nobody else's.
    private let claudeProfiles = ClaudeProfile.discover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set here, not in the Info.plist: this call is applied at launch and
        // overrides `LSUIElement` either way. Removing the plist key alone left
        // the app registered as a UIElement with no Dock tile, which looked
        // exactly like the icon having failed to install. The user's choice
        // replaces this a moment later, once preferences exist.
        NSApp.setActivationPolicy(.regular)
        guard !isRunningTests else { return }

        let controller = NotchWindowController()

        // `CODENOTCH_DEMO=1` puts the design frame's three providers on screen
        // with its numbers, for screenshots and for eyeballing the layout.
        if ProcessInfo.processInfo.environment["CODENOTCH_DEMO"] == "1" {
            controller.model.snapshots = Fixtures.snapshots()
        } else {
            // Grok reads SuperGrok's weekly pool through a signed-in WebView
            // (`Sites.grok`); `Sites.perplexity` is kept unregistered as the
            // spare pattern for a site behind bot management.
            let webProviders: [WebSessionProvider] = [WebSessionProvider(site: Sites.grok)]
            controller.signInItems = webProviders.map { provider in
                (title: "Sign in to \(provider.displayName)…",
                 action: { [weak provider] in provider?.presentSignIn() })
            }
            // Before Preferences reads anything, or the first launch flag and
            // every choice would be read from an empty domain.
            Preferences.migrateFromPreviousName()
            let preferences = Preferences()
            self.preferences = preferences

            // Cursor reads the editor's own session rather than a browser one:
            // signing into cursor.com separately created a second, empty account.
            //
            // Built *after* preferences and told what is switched off, so the
            // very first list it draws already excludes them. Constructed first,
            // it drew every provider from the archive and only dropped the
            // switched-off ones once the binding below delivered.
            Log.usage.info("claude profiles: \(self.claudeProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            let store = UsageStore(
                providers: claudeProfiles.map { ClaudeOAuthProvider(profile: $0) }
                    + [CursorLocalProvider(), CodexLocalProvider(), AntigravityProvider(),
                       GLMProvider(), OpenCodeProvider()]
                    + webProviders,
                disconnected: preferences.disconnectedProviders
            )

            // The stored edge goes in before the panel is ever put up. The
            // sink below delivers on the next run loop turn, by which time the
            // notch has already been shown on the default edge — so without
            // this, every launch on any other edge opens with a flash of the
            // right-hand one and then crossfades away from it.
            controller.model.edge = preferences.notchEdge

            let updater = Updater()
            self.updater = updater

            let settings = SettingsWindowController(
                preferences: preferences,
                // A closure so the sheet re-reads accounts each time it comes
                // forward; a snapshot here is what made a switched account keep
                // showing the old address until the app restarted.
                providers: { [weak store] in store?.providerSummaries ?? [] },
                updater: updater,
                signOut: { [weak store] in store?.signOut(providerID: $0) },
                signIn: { [weak store] in store?.signIn(providerID: $0) ?? false },
                switchAccount: { [weak store] in
                    store?.openAccountSource(providerID: $0) ?? false
                },
                retry: { [weak store] in store?.reauthorize(providerID: $0) }
            )
            controller.onOpenSettings = { [weak settings] in settings?.show() }
            self.settings = settings

            // What changed, once per version — including on a fresh install,
            // where it is the introduction.
            let whatsNew = WhatsNewWindowController(
                preferences: preferences, version: updater.currentVersion
            )
            self.whatsNew = whatsNew

            // An agent app has no dock icon and no window: installed and
            // launched, it shows four empty rings on a screen edge and no
            // reason to look at them. Once, on the very first run, it opens the
            // one place that explains what to connect.
            //
            // Sequenced behind What's New rather than beside it: two windows
            // arriving together is one to dismiss before you can read either.
            let introduce = { [weak settings] in
                guard preferences.isFirstLaunch else { return }
                settings?.show()
            }
            whatsNew.onDismiss = introduce
            if !whatsNew.showIfNeeded() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: introduce)
            }

            let statusItem = StatusItemController { [weak settings] in settings?.show() }
            self.statusItem = statusItem

            preferences.$appPresence
                .receive(on: RunLoop.main)
                .sink { presence in
                    NSApp.setActivationPolicy(presence.activationPolicy)
                    if presence.wantsStatusItem { statusItem.show() } else { statusItem.hide() }
                }
                .store(in: &cancellables)

            preferences.$notchVisibility
                .receive(on: RunLoop.main)
                .sink { [weak controller] in controller?.apply($0) }
                .store(in: &cancellables)

            preferences.$notchEdge
                .receive(on: RunLoop.main)
                .sink { [weak controller] in controller?.apply(edge: $0) }
                .store(in: &cancellables)

            preferences.$disconnectedProviders
                .receive(on: RunLoop.main)
                .sink { [weak store] in store?.disconnected = $0 }
                .store(in: &cancellables)

            store.$snapshots
                .receive(on: RunLoop.main)
                .sink { [weak controller] snapshots in
                    withAnimation(NotchMotion.unfold) {
                        controller?.model.snapshots = snapshots
                    }
                    controller?.model.now = Date()
                }
                .store(in: &cancellables)
            store.start()
            controller.onRefresh = { [weak store] in store?.refreshNow() }
            controller.onRefreshProvider = { [weak store] id in store?.refresh(providerID: id) }
            store.$refreshing
                .receive(on: RunLoop.main)
                .sink { [weak controller] ids in controller?.model.refreshing = ids }
                .store(in: &cancellables)

            // CODENOTCH_DISCOVER=<url> loads that page in the signed-in WebView
            // and logs the API calls it makes — for finding an undocumented
            // endpoint by watching the site rather than guessing at path names.
            if let target = ProcessInfo.processInfo.environment["CODENOTCH_DISCOVER"],
               let url = URL(string: target),
               let provider = webProviders.first(where: { url.host?.contains($0.id) == true })
                   ?? webProviders.first {
                Task {
                    let calls = await provider.recordCalls(on: url)
                    Log.usage.notice("discovered: \(calls.joined(separator: "  "), privacy: .public)")
                }
            }
            self.store = store
        }

        // What each agent is doing right now, so the notch can say whether it is
        // still working without you switching to it.
        var monitors: [String: any AgentActivityMonitor] = [
            "cursor": CursorActivityMonitor(),
            "codex": CodexActivityMonitor(),
            "gemini": AntigravityActivityMonitor()
        ]
        for profile in claudeProfiles {
            monitors[profile.id] = ClaudeSessionMonitor(directory: profile.sessionsDirectory)
        }
        for (id, monitor) in monitors {
            monitor.sessionsPublisher
                .receive(on: RunLoop.main)
                .sink { [weak controller] live in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        controller?.model.sessions[id] = live
                    }
                    controller?.model.now = Date()
                }
                .store(in: &cancellables)
            monitor.start()
        }
        // Poll usage hard only while something is actually running.
        store?.isBusy = { monitors.values.contains { m in m.sessions.contains { $0.state == .busy } } }
        self.monitors = monitors

        controller.show()
        notchController = controller
    }

    /// Closing the settings window must not take the app with it.
    ///
    /// The default for a Dock app is to quit once its last window closes, which
    /// here would kill the notch — the part that is actually the product —
    /// every time someone shut the settings they had just opened.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The way back in when the notch is hidden.
    ///
    /// With no dock icon, no menu bar item and no notch on screen, there is
    /// otherwise nothing left to click — choosing Hide would be a one-way door.
    /// Launching the app again while it is already running lands here, so
    /// opening it from Applications or Spotlight reopens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        settings?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        monitors.values.forEach { $0.stop() }
        notchController?.stop()
    }
}
