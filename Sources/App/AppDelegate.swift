import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchFleet: NotchFleet?
    private var store: UsageStore?
    var phoneLinkServer: PhoneLinkServer?
    var phoneLinkServerStatus: PhoneLinkServerStatus?
    var phoneLinkPairing: PhoneLinkPairing?
    var phoneLinkRegistry: PhoneLinkRegistry?
    private var activityCoordinator: ActivityCoordinator?
    private var ollamaRelay: OllamaActivityRelay?
    private var lmstudioMetrics: LMStudioMetrics?
    private var preferences: Preferences?
    private var settings: SettingsWindowController?
    private var whatsNew: WhatsNewWindowController?
    /// Held for the life of the app: releasing it stops the scheduled checks.
    private var updater: Updater?
    private var thresholdNotifier: ThresholdNotifier?
    private var resetWatcher: UsageResetWatcher?
    private var limitWatcher: UsageLimitWatcher?
    private var statusItem: StatusItemController?
    /// Keeps the Claude keychain token from ageing out on a Mac where the CLI
    /// is never run by hand. See `ClaudeTokenRefresher`.
    private var tokenRefresher: ClaudeTokenRefresher?
    private var cancellables = Set<AnyCancellable>()
    /// Turns the monitors' running commentary into the one event worth
    /// interrupting for: an agent that has just stopped working.
    private var completions = SessionCompletionWatcher()

    /// The unit bundle is hosted by this app, so `xcodebuild test` launches it
    /// for real. Without this guard every test run put a live request on the
    /// usage endpoint — which is both wrong on its own terms and, on an endpoint
    /// that rate-limits, actively harmful.
    private var isRunningTests: Bool { Runtime.isUnderTest }

    /// Quit any copy of Codenotch that was already running.
    ///
    /// Every notch is a window on the screen edge, so a second copy is not a
    /// harmless duplicate the way a second text editor is: it draws a second
    /// notch over the first, and a developer with a build in `DerivedData`, a
    /// staged release and `/Applications` could end up with the screen ringed
    /// by them. They are separate bundles at separate paths, so the system
    /// launches each as its own process rather than activating the one that is
    /// already up.
    ///
    /// The newcomer wins, deliberately. Quitting the *new* copy instead would
    /// be the wrong way round while developing: the whole point of launching a
    /// fresh build is to replace the one already running.
    ///
    /// Only strictly older instances are asked to go, which is what keeps two
    /// simultaneous launches from each terminating the other and leaving none.
    private static func retireOlderInstances() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let launched = NSRunningApplication.current.launchDate ?? Date()
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where other.processIdentifier != mine && (other.launchDate ?? .distantPast) < launched {
            Log.usage.info("retiring an older instance (pid \(other.processIdentifier, privacy: .public))")
            if !other.terminate() { other.forceTerminate() }
        }
    }

    /// The snapshots as the rings draw them: the vendor's own, with the weekly
    /// window leading where that is switched on, and the daily pace laid over
    /// that where it is. One place, so the notch and the phone agree on what a
    /// ring means. The menu bar and the alert watchers are deliberately fed the
    /// vendor's own order instead — see their sink.
    static func drawn(_ snapshots: [ProviderSnapshot], weekly: Bool, paced: Bool)
    -> [ProviderSnapshot] {
        DailyPace.apply(to: WeeklyHeadline.apply(to: snapshots, enabled: weekly), enabled: paced)
    }

    /// Every Claude Code configuration directory on this Mac — `~/.claude` and
    /// any `~/.claude-<slug>` — found once at launch. Each gets a usage
    /// provider and a session monitor of its own, keyed by the same id, so a
    /// work login's sessions spin the work ring and nobody else's.
    private let claudeProfiles = ClaudeProfile.discover()
    private let codexProfiles = CodexProfile.discover()
    private let antigravityProfiles = AntigravityProfile.discover()
    /// Held as concrete providers, not just handed to the store: the token
    /// refresher needs to ask one of them how long its token has left, and the
    /// protocol has no business carrying that.
    private var claudeProviders: [ClaudeOAuthProvider] = []
    /// MiniMax Platform sign-in sheet. Not a UsageProvider — that is MiniMaxProvider.
    private var miniMaxWeb: WebSessionProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set here, not in the Info.plist: this call is applied at launch and
        // overrides `LSUIElement` either way. Removing the plist key alone left
        // the app registered as a UIElement with no Dock tile, which looked
        // exactly like the icon having failed to install. The user's choice
        // replaces this a moment later, once preferences exist.
        NSApp.setActivationPolicy(.regular)
        guard !isRunningTests else { return }
        Self.retireOlderInstances()

        // Before Preferences reads anything, or the first launch flag and
        // every choice would be read from an empty domain.
        Preferences.migrateFromPreviousName()
        let preferences = Preferences()
        self.preferences = preferences

        // One notch per display: the fleet owns a controller for each screen
        // the scope asks for and fans every reading out to all of them. The
        // stored edge goes in up front, before any panel is ever put up — the
        // sink below delivers on the next run loop turn, by which time the
        // notch would already have flashed on the default edge.
        let fleet = NotchFleet(scope: preferences.notchScope, edge: preferences.notchEdge)
        self.notchFleet = fleet

        // `CODENOTCH_DEMO=1` puts the design frame's three providers on screen
        // with its numbers, for screenshots and for eyeballing the layout.
        if ProcessInfo.processInfo.environment["CODENOTCH_DEMO"] == "1" {
            fleet.setSnapshots(Fixtures.snapshots())
        } else {
            // DeepSeek's Platform usage page is a browser-session provider:
            // login is explicit, stays in Codenotch's own WKWebView store, and
            // the page-local requests are refreshed only after that login.
            let deepSeek = WebSessionProvider(site: Sites.deepSeek)
            // QianwenAI's Token Plan is the same kind of provider: no usage API
            // to call, only a console, readable after the user signs in inside
            // this app's own WKWebView. Unlike MiniMax's sheet below, its ring
            // *is* this adapter, so it belongs in `webProviders` — exactly once.
            let qianwen = WebSessionProvider(site: Sites.qianwen)
            // MiniMax's ring is MiniMaxProvider. The sheet is the same kind of
            // WebView DeepSeek uses, but it must not join `webProviders`:
            // those are appended to `allProviders`, and two adapters with
            // id `minimax` would both poll, both draw a row, and fight over
            // the same archive key. Region is applied here and again when
            // Settings changes it, because the fetch URLs live on the site.
            let miniMaxWeb = WebSessionProvider(site: Sites.minimax(region: preferences.minimaxRegion))
            self.miniMaxWeb = miniMaxWeb
            let webProviders: [WebSessionProvider] = [deepSeek, qianwen]
            fleet.signInItems = [deepSeek, miniMaxWeb, qianwen].map { provider in
                let name = provider.displayName
                return (title: L10n.t("Sign in to \(name)…"),
                        action: { [weak provider] in provider?.presentSignIn() })
            }

            // Cursor reads the editor's session, or cursor-agent's if the
            // editor is missing — never a browser one: signing into
            // cursor.com separately created a second, empty account.
            //
            // Built *after* preferences and told what is switched off, so the
            // very first list it draws already excludes them. Constructed first,
            // it drew every provider from the archive and only dropped the
            // switched-off ones once the binding below delivered.
            Log.usage.info("claude profiles: \(self.claudeProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            Log.usage.info("codex profiles: \(self.codexProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            Log.usage.info("antigravity profiles: \(self.antigravityProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            // Named together rather than one by one: a name derived from the
            // signed-in address can collide with another profile's, and a lone
            // profile needs no name beyond "Claude" — only a caller holding
            // every profile can see either.
            let claudeNames = ClaudeProfile.displayNames(for: claudeProfiles)
            let claudeProviders = claudeProfiles.map {
                ClaudeOAuthProvider(profile: $0, displayName: claudeNames[$0.id])
            }
            self.claudeProviders = claudeProviders
            let customProviders: [UsageProvider] = preferences.customEndpoints.filter(\.isEnabled).map { endpoint in
                CustomEndpointProvider(endpoint: endpoint)
            }
            let allProviders: [UsageProvider] = claudeProviders
                + [CursorLocalProvider()]
                + codexProfiles.map { CodexLocalProvider(profile: $0) }
                + antigravityProfiles.map { AntigravityProvider(profile: $0) }
                + [GLMProvider(), MiniMaxProvider(web: miniMaxWeb), GrokLocalProvider(), DevinLocalProvider(), OpenCodeProvider(),
                   CommandCodeProvider(), GitHubCopilotProvider(), KimiProvider(), KiroProvider(), AmpProvider(),
                   OllamaLocalProvider(endpoint: URL(string: preferences.ollamaEndpoint)!),
                   LMStudioLocalProvider(endpoint: URL(string: preferences.lmstudioEndpoint)!),
                   OllamaProvider(),
                   // A closure, not the value: the provider is an actor and
                   // re-reads the budget on every fetch, so a ceiling typed
                   // into Settings applies without a restart.
                   GeminiAPIProvider(budget: {
                       Preferences.storedGeminiAPIMonthlyTokenBudget()
                   })]
                + webProviders
                + customProviders
            preferences.reconcile(discoveredIDs: allProviders.map(\.id))
            let store = UsageStore(
                providers: allProviders,
                disconnected: preferences.disconnectedIDs(among: allProviders.map(\.id)),
                // Passed at construction, not left to the sink below, for the
                // same reason `disconnected` is: the sink delivers a run loop
                // turn later, so without this every launch draws the built-in
                // order for a frame and then visibly shuffles.
                order: preferences.providerOrder
            )
            preferences.$customEndpoints
                .map { endpoints in
                    endpoints.filter(\.isEnabled).map {
                        "\($0.id):\($0.name):\($0.baseURL):\($0.trackingUnit.rawValue):\($0.monthlyBudgetUSD ?? -1):\($0.currentSpendUSD ?? -1):\($0.monthlyBudgetTokensM ?? -1):\($0.currentTokensUsedM ?? -1):\($0.displayRemaining):\($0.showCurrency):\($0.iconPreset ?? ""):\($0.customIconFilename ?? ""):\($0.accentColorHex):\($0.selectedModel)"
                    }
                }
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak store] _ in
                    let stored = Preferences.storedCustomEndpoints()
                    let active = stored.filter(\.isEnabled)
                    let providers: [UsageProvider] = active.map { CustomEndpointProvider(endpoint: $0) }
                    store?.registerCustomProviders(providers)
                }
                .store(in: &cancellables)
            deepSeek.onAuthenticated = { [weak store] in
                store?.providerAuthenticationChanged(providerID: "deepseek")
            }
            qianwen.onAuthenticated = { [weak store] in
                store?.providerAuthenticationChanged(providerID: "qianwenai")
            }
            miniMaxWeb.onAuthenticated = { [weak store] in
                store?.providerAuthenticationChanged(providerID: "minimax")
            }

            let updater = Updater()
            self.updater = updater

            let relay = OllamaActivityRelay()
            self.ollamaRelay = relay
            // A single publisher chain exceeds Swift's type-checking time limit.
            let relayPreferences = Publishers.CombineLatest3(
                preferences.$connectedProviders,
                preferences.$ollamaEndpoint,
                preferences.$ollamaMetricsEnabled)
            let relayConfiguration = relayPreferences.map { values in
                (enabled: values.0.contains("ollama-local") && values.2, endpoint: values.1)
            }.eraseToAnyPublisher()
            relayConfiguration
                .removeDuplicates { $0.enabled == $1.enabled && $0.endpoint == $1.endpoint }
                .receive(on: RunLoop.main)
                .sink { [weak relay, weak fleet] configuration in
                    fleet?.setLocalMetricsEnabled(configuration.enabled)
                    relay?.configure(enabled: configuration.enabled, endpoint: configuration.endpoint)
                }
                .store(in: &cancellables)
            relay.$thinkingModels
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] models in
                    let previous = fleet?.thinkingModels ?? [:]
                    fleet?.setThinkingModels(models)
                    if models.keys.contains(where: { previous[$0] == nil }) { store?.refresh(providerID: "ollama-local") }
                }
                .store(in: &cancellables)

            relay.$performances
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] measurements in
                    fleet?.setPerformances(measurements)
                    if !measurements.isEmpty { store?.refresh(providerID: "ollama-local") }
                }
                .store(in: &cancellables)

            // LM Studio needs no relay: its own socket says what each model is
            // doing and its own log says what every request cost. Monitoring
            // follows the provider's switch, and the address follows Settings.
            let lmstudio = LMStudioMetrics()
            self.lmstudioMetrics = lmstudio
            // Split like the relay's chain above, and for the same reason.
            let lmstudioPreferences = Publishers.CombineLatest(
                preferences.$connectedProviders, preferences.$lmstudioEndpoint)
            let lmstudioConfiguration = lmstudioPreferences.map { values in
                (enabled: values.0.contains(LMStudioMetrics.providerID), endpoint: values.1)
            }.eraseToAnyPublisher()
            lmstudioConfiguration
                .removeDuplicates { $0.enabled == $1.enabled && $0.endpoint == $1.endpoint }
                .receive(on: RunLoop.main)
                .sink { [weak lmstudio] configuration in
                    lmstudio?.configure(enabled: configuration.enabled, endpoint: configuration.endpoint)
                }
                .store(in: &cancellables)
            lmstudio.$activities
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.setLocalActivities($0) }
                .store(in: &cancellables)
            lmstudio.$performances
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] measurements in
                    fleet?.setPerformances(measurements, source: LMStudioMetrics.providerID)
                    if !measurements.isEmpty { store?.refresh(providerID: LMStudioMetrics.providerID) }
                }
                .store(in: &cancellables)
            lmstudio.$ledger
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.setLedger($0) }
                .store(in: &cancellables)

            let dir: URL
            if NSClassFromString("XCTestCase") != nil {
                dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                dir = appSupport.appendingPathComponent("Codenotch/phone-link", isDirectory: true)
            }
            let phoneSecretStore: PhoneLinkSecretStore = NSClassFromString("XCTestCase") != nil
                ? InMemoryPhoneLinkSecretStore()
                : PhoneLinkKeychainSecretStore()
            let phoneRegistry = PhoneLinkRegistry(directory: dir, secretStore: phoneSecretStore)
            let phonePairing = PhoneLinkPairing()
            let serverStatus = PhoneLinkServerStatus()
            self.phoneLinkRegistry = phoneRegistry
            self.phoneLinkPairing = phonePairing
            
            let server = PhoneLinkServer(
                pairing: phonePairing,
                registry: phoneRegistry,
                status: serverStatus,
                getSnapshot: { @Sendable [weak store, weak fleet, weak preferences] in
                    guard let store, let fleet, let preferences else { return nil }
                    let snap = await MainActor.run {
                        PhoneLinkSnapshotBuilder.build(
                            snapshots: Self.drawn(store.snapshots,
                                                  weekly: preferences.weeklyHeadline,
                                                  paced: preferences.claudeDailyPaceRing),
                            sessions: Array(fleet.sessions.values.flatMap { $0 }),
                            disconnected: store.disconnected,
                            order: preferences.providerOrder,
                            serverName: PhoneLinkNetwork.getComputerName(),
                            serverVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0",
                            now: Date()
                        )
                    }
                    return try? JSONEncoder().encode(snap)
                },
                refreshAndGetSnapshot: { @Sendable [weak store, weak fleet, weak preferences] in
                    guard let store, let fleet, let preferences else { return nil }
                    await MainActor.run { store.refreshNow() }
                    for _ in 0..<20 {
                        let isRef = await MainActor.run { !store.refreshing.isEmpty }
                        if !isRef { break }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    let snap = await MainActor.run {
                        PhoneLinkSnapshotBuilder.build(
                            snapshots: Self.drawn(store.snapshots,
                                                  weekly: preferences.weeklyHeadline,
                                                  paced: preferences.claudeDailyPaceRing),
                            sessions: Array(fleet.sessions.values.flatMap { $0 }),
                            disconnected: store.disconnected,
                            order: preferences.providerOrder,
                            serverName: PhoneLinkNetwork.getComputerName(),
                            serverVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0",
                            now: Date()
                        )
                    }
                    return try? JSONEncoder().encode(snap)
                }
            )
            self.phoneLinkServerStatus = serverStatus
            self.phoneLinkServer = server

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
                    store?.openAccountSource(providerID: $0, switching: true) ?? false
                },
                retry: { [weak store] in store?.reauthorize(providerID: $0) },
                // Both halves, because the stored nudge and the live one are
                // kept apart on purpose — clearing only the preference would
                // leave the notch where it is until the next edge change, and
                // moving only the panel would put it back on relaunch.
                resetPosition: { [weak fleet, weak preferences] in
                    preferences?.setOffset(0, for: preferences?.notchEdge ?? .right)
                    fleet?.apply(alongOffset: 0)
                },
                quit: { NSApp.terminate(nil) },
                previewResetAlert: { [weak self] in
                    self?.previewUsageResetAlert()
                },
                previewSessionLimitAlert: { [weak self] in
                    self?.previewSessionLimitAlert()
                },
                previewWeeklyLimitAlert: { [weak self] in
                    self?.previewWeeklyLimitAlert()
                },
                usageStore: store, ollamaRelay: relay, lmstudioMetrics: lmstudio,
                phoneLinkPairing: phonePairing, phoneLinkRegistry: phoneRegistry, phoneLinkServerStatus: serverStatus
            )
            // The gear toggles; everything else that opens settings opens it.
            fleet.onOpenSettings = { [weak settings] in settings?.toggle() }
            // A session row answers where it runs by taking you there.
            fleet.onFocusSession = { pid in
                Task { _ = await SessionFocus.focus(pid: pid) }
            }
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
            // The cards in the menu are drawn from the fleet's panel-less
            // model — the very snapshots and Appearance settings the notches
            // are handed. No provider is read to open the menu and no second
            // store is kept: the menu is another reader of the one the notch
            // already reads, which is what keeps the two from disagreeing.
            statusItem.model = fleet.menuModel
            statusItem.onRefreshAll = { [weak store] in store?.refreshNow() }
            // The menu's tick writes to the same preference Settings writes to,
            // and reads nothing back of its own: the sink below carries the new
            // value to the item, and Settings — a published property away —
            // redraws its own switch from it in the same breath.
            statusItem.onToggleLimits = { [weak preferences] in preferences?.showsLimitsInMenuBar = $0 }
            // A card's own switch, written back the same way: into Preferences,
            // and read back through the sink below. The controller keeps no
            // copy, so the switch and what the card draws cannot disagree.
            statusItem.onToggleDetail = { [weak preferences] id, expanded in
                preferences?.setDetailExpanded(expanded, for: id)
            }
            statusItem.expandedDetail = preferences.expandedDetailProviders
            // Read when the menu opens, so a model's line is as current as its cell.
            statusItem.cells = { [weak fleet] in fleet?.menuModel.snapshots ?? [] }
            statusItem.activity = { [weak fleet] in fleet?.menuModel.activity(for: $0) }
            // Handed over up front, like the notch's edge: the sink below
            // delivers a run loop turn later, and the item would otherwise go
            // up as one thing and then change its mind.
            statusItem.limits = preferences.menuBarLimits
            statusItem.resetTimeFormat = preferences.resetTimeFormat
            statusItem.showsWeeklyLimit = preferences.showsWeeklyLimitInMenuBar

            preferences.$appPresence
                .receive(on: RunLoop.main)
                .sink { presence in
                    NSApp.setActivationPolicy(presence.activationPolicy)
                    if presence.wantsStatusItem { statusItem.show() } else { statusItem.hide() }
                }
                .store(in: &cancellables)

            // What the item shows is presentation alone. It reaches the item and
            // nothing else — no provider is read, refreshed, or switched on or
            // off to answer it — and the item redraws from the readings it
            // already holds, so a change in Settings lands on the bar at once.
            Publishers.CombineLatest(preferences.$showsLimitsInMenuBar, preferences.$menuBarProviders)
                .map { MenuBarLimits(isOn: $0, chosen: $1) }
                .removeDuplicates()
                // Dispatch, not the run loop: switched from the menu's own
                // tick, this has to land while AppKit is still tracking that
                // menu, which the run loop's default mode would hold back.
                .receive(on: DispatchQueue.main)
                .sink { [weak statusItem] in statusItem?.limits = $0 }
                .store(in: &cancellables)

            // Dispatch, not the run loop, for the reason the limit switch
            // above gives: this lands while AppKit is still tracking the menu
            // the card is in, which is exactly when a card is opened.
            preferences.$expandedDetailProviders
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak statusItem] in statusItem?.expandedDetail = $0 }
                .store(in: &cancellables)

            // Presentation only, like the parent limit switch: redraw from the
            // current snapshots immediately and never start another fetch.
            preferences.$showsWeeklyLimitInMenuBar
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak statusItem] in statusItem?.showsWeeklyLimit = $0 }
                .store(in: &cancellables)

            preferences.$notchVisibility
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply($0) }
                .store(in: &cancellables)

            preferences.$foldsForFullScreen
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(foldsForFullScreen: $0) }
                .store(in: &cancellables)

            preferences.$deepSeekPricingEnabled
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(deepSeekPricingEnabled: $0) }
                .store(in: &cancellables)

            preferences.$deepSeekPricingSchedule
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(deepSeekPricingSchedule: $0) }
                .store(in: &cancellables)

            preferences.$minimaxRegion
                .dropFirst()
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak miniMaxWeb, weak store] region in
                    miniMaxWeb?.apply(site: Sites.minimax(region: region))
                    store?.refresh(providerID: "minimax")
                }
                .store(in: &cancellables)

            preferences.$notchEdge
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak preferences] edge in
                    // Read before `apply(edge:)` moves the panel, so the new
                    // edge's own remembered nudge is what it lands at rather
                    // than the old edge's carried over onto it.
                    fleet?.apply(alongOffset: preferences?.offset(for: edge) ?? 0)
                    fleet?.apply(edge: edge)
                }
                .store(in: &cancellables)

            // Three inputs, one answer: which control is in charge, and the
            // value each of them holds. Any of them changing has to re-ask
            // `notchScale` rather than trust the value it was handed, since
            // the preset and the slider each keep their own.
            //
            // `dropFirst` on each, because `@Published` publishes the value it
            // is given at init — without it every launch would open the notch
            // three times over before anyone had touched anything.
            Publishers.MergeMany(
                preferences.$notchSize.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                preferences.$usesCustomNotchScale.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                preferences.$customNotchScale.dropFirst().map { _ in () }.eraseToAnyPublisher()
            )
            // `DispatchQueue.main`, not `RunLoop.main`, and this is the one
            // subscription where the difference is visible. Combine's RunLoop
            // scheduler delivers in `.default` mode, which AppKit starves for
            // as long as a drag is in progress — the loop is in
            // `NSEventTrackingRunLoopMode` the whole time a slider is held. So
            // the notch sat unchanged until the mouse came up, then jumped.
            // Every `Timer` here is registered `forMode: .common` against the
            // same hazard; the scheduler offers no way to say that, and the
            // dispatch queue is not bound to run loop modes at all.
            .receive(on: DispatchQueue.main)
            .sink { [weak fleet, weak preferences] in
                guard let preferences, let fleet else { return }
                fleet.apply(scale: preferences.notchScale)
                // Resizing something you cannot see is guesswork. On the
                // hover setting the notch is folded away for as long as the
                // pointer is in Settings, which is exactly when the size is
                // being chosen — so it is opened for a moment to show what
                // just changed. Dragging the slider keeps re-arming this, so
                // it simply stays open until the drag stops. `peek` still
                // declines outright when the notch is set to Hide.
                fleet.peek(for: 1.2, focusing: nil)
            }
            .store(in: &cancellables)

            preferences.$notchScope
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(scope: $0) }
                .store(in: &cancellables)

            preferences.$displayPreference
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(displayPreference: $0) }
                .store(in: &cancellables)

            fleet.onReposition = { [weak preferences] offset in
                preferences?.setOffset(offset, for: preferences?.notchEdge ?? .right)
            }

            // Writing the preference is the whole of it: `notchEdge` is
            // `@Published` and the fleet already follows it, so the notch
            // relocates by the same path the Settings picker uses.
            fleet.onMoveToEdge = { [weak preferences] edge in
                preferences?.notchEdge = edge
            }

            preferences.$resetTimeFormat
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak statusItem] in
                    fleet?.apply(resetTimeFormat: $0)
                    statusItem?.resetTimeFormat = $0
                }
                .store(in: &cancellables)

            preferences.$accentColor
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(accentColor: $0) }
                .store(in: &cancellables)
            
            preferences.$watchLimit
                .combineLatest(preferences.$criticalLimit)
                .receive(on: RunLoop.main)
                .sink { [weak fleet] watch, critical in
                    fleet?.apply(watchLimit: watch, criticalLimit: critical)
                }
                .store(in: &cancellables)

            preferences.$showsNotchReadings
                .dropFirst()
                .sink { [weak fleet] in fleet?.apply(showsNotchReadings: $0) }
                .store(in: &cancellables)

            preferences.$weeklyRingDashed
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(weeklyRingDashed: $0) }
                .store(in: &cancellables)

            preferences.$weeklyRing
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(weeklyRing: $0) }
                .store(in: &cancellables)

            preferences.$showsMoveHandle
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(showsMoveHandle: $0) }
                .store(in: &cancellables)
                
            preferences.$notchSurfaceStyle
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(surfaceStyle: $0) }
                .store(in: &cancellables)

            preferences.$colorTransitionStyle
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(colorTransitionStyle: $0) }
                .store(in: &cancellables)

            Publishers.CombineLatest(preferences.$connectedProviders, preferences.$disabledModels)
                .receive(on: RunLoop.main)
                .sink { [weak store, weak preferences] _, _ in
                    guard let store, let preferences else { return }
                    store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
                }
                .store(in: &cancellables)

            preferences.$accountNicknames
                .receive(on: RunLoop.main)
                .sink { [weak store] in store?.nicknames = $0 }
                .store(in: &cancellables)

            preferences.$ollamaEndpoint
                .receive(on: RunLoop.main)
                .sink { [weak store] address in
                    guard let endpoint = try? OllamaEndpoint.parse(address) else { return }
                    store?.updateOllamaEndpoint(endpoint)
                }
                .store(in: &cancellables)

            preferences.$lmstudioEndpoint
                .receive(on: RunLoop.main)
                .sink { [weak store] address in
                    guard let endpoint = try? LMStudioEndpoint.parse(address) else { return }
                    store?.updateLMStudioEndpoint(endpoint)
                }
                .store(in: &cancellables)

            preferences.$providerOrder
                .receive(on: RunLoop.main)
                .sink { [weak store] in store?.order = $0 }
                .store(in: &cancellables)

            // Redraw the Gemini API ring against the new ceiling.
            //
            // `dropFirst` because `@Published` publishes the value it is given
            // at init, and a refresh there would race the store's first poll.
            // `receive(on:)` because `@Published` emits in `willSet` — the hop
            // to the next run loop pass is what lets the `didSet` persist the
            // number before the provider's closure goes looking for it.
            preferences.$geminiAPIMonthlyTokenBudget
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak store] _ in store?.refresh(providerID: "gemini-api") }
                .store(in: &cancellables)

            // Limit crossings become notifications here rather than inside
            // the store: the store fetches, the notifier decides what is
            // worth interrupting someone for, and neither needs to know the
            // other.
            let notifier = ThresholdNotifier(
                isMuted: { [weak preferences] in preferences?.isMutedAlerts(for: $0) ?? false },
                deliver: { ThresholdAlerts.deliver($0) }
            )
            self.thresholdNotifier = notifier

            let resetWatcher = UsageResetWatcher(
                isMuted: { [weak preferences] in preferences?.isMutedAlerts(for: $0) ?? false },
                deliver: { [weak self] event in
                    MainActor.assumeIsolated {
                        self?.announceUsageReset(event: event)
                    }
                }
            )
            self.resetWatcher = resetWatcher

            let limitWatcher = UsageLimitWatcher(
                isMuted: { [weak preferences] in preferences?.isMutedAlerts(for: $0) ?? false },
                deliver: { [weak self] event in
                    MainActor.assumeIsolated {
                        self?.announceUsageLimit(event: event)
                    }
                }
            )
            self.limitWatcher = limitWatcher

            // The daily-pace window is laid over the store's snapshots here,
            // on the way out, rather than inside a provider: it is a reading
            // of a preference as much as of the account, and the store keeps
            // what the vendor said. Paired with the preference so flipping the
            // toggle redraws at once, without a fetch. The weekly-first ring
            // is laid the same way, and for the same reasons — see `drawn`.
            store.$notchSnapshots
                .combineLatest(preferences.$claudeDailyPaceRing, preferences.$weeklyHeadline)
                .receive(on: RunLoop.main)
                .sink { [weak fleet] snapshots, paced, weekly in
                    fleet?.setSnapshots(Self.drawn(snapshots, weekly: weekly, paced: paced))
                }
                .store(in: &cancellables)

            // Not `drawn`: the weekly-first ring is for the rings alone. The
            // menu bar already shows the week beside the short window, under a
            // "Weekly Limit" label that would name the session after a swap.
            // The alert watchers track one headline per provider and tell
            // "session" from "week" by which window leads, so a swap under them
            // re-fires thresholds, announces a reset that did not happen, and
            // leaves a spent session with no "available again" to follow it.
            store.$snapshots
                .combineLatest(preferences.$claudeDailyPaceRing)
                .receive(on: RunLoop.main)
                .sink { [weak statusItem] snapshots, paced in
                    let snapshots = DailyPace.apply(to: snapshots, enabled: paced)
                    statusItem?.snapshots = snapshots
                    notifier.observe(snapshots)
                    resetWatcher.observe(snapshots)
                    limitWatcher.observe(snapshots)
                }
                .store(in: &cancellables)
            store.start()
            fleet.onRefresh = { [weak store] in store?.refreshNow() }
            fleet.onRefreshProvider = { [weak store] id in
                await store?.refresh(providerID: id)?.value
            }
            store.$refreshing
                .receive(on: RunLoop.main)
                .sink { [weak fleet] ids in fleet?.setRefreshing(ids) }
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
            "grok": GrokActivityMonitor(),
            "gemini-api": GeminiAPIActivityMonitor(),
            "kimi": KimiActivityMonitor(),
        ]
        for profile in antigravityProfiles {
            monitors[profile.id] = AntigravityActivityMonitor(profile: profile)
        }
        var claudeMonitors: [ClaudeSessionMonitor] = []
        var claudeMonitorsByProfile: [(ClaudeProfile, ClaudeSessionMonitor)] = []
        for profile in claudeProfiles {
            let monitor = ClaudeSessionMonitor(
                directory: profile.sessionsDirectory,
                projects: profile.projectsDirectory
            )
            claudeMonitors.append(monitor)
            claudeMonitorsByProfile.append((profile, monitor))
            monitors[profile.id] = monitor
        }

        // With one profile there is nothing to attribute: every session in the
        // directory is that account's, by definition. With two or more there
        // is, because the Claude desktop app files the sessions it hosts under
        // the *default* profile's directory whichever account it is signed in
        // to — so the second account's work spun the first account's ring, and
        // switching account in the app did not move it. See
        // `ClaudeSessionOwnership`.
        if claudeProfiles.count > 1 {
            let index = ClaudeDesktopSessionIndex()
            let directories = claudeProfiles.map(\.sessionsDirectory)
            var accounts: [String: String] = [:]
            var transcripts: [String: ClaudeTranscriptReader] = [:]
            for profile in claudeProfiles {
                let path = profile.sessionsDirectory.path
                if let account = profile.accountID() { accounts[path] = account }
                transcripts[path] = ClaudeTranscriptReader(projects: profile.projectsDirectory)
            }
            for (profile, monitor) in claudeMonitorsByProfile {
                monitor.ownership = ClaudeSessionOwnership(
                    own: profile.sessionsDirectory,
                    directories: directories,
                    accounts: accounts,
                    transcripts: transcripts,
                    index: index
                )
            }
            let named = accounts.count, total = claudeProfiles.count
            Log.sessions.info("claude session ownership: \(named, privacy: .public) of \(total, privacy: .public) profiles name an account")
        }
        for profile in codexProfiles {
            monitors[profile.id] = CodexActivityMonitor(profile: profile)
        }

        // The `/usage` probe is a Claude Code process too, and files a session
        // for the seconds it runs. Every Claude monitor steps over it by pid
        // and by its scratch directory, whether or not a token refresher runs
        // below. Without this the probe showed as a `busy` session, vanished,
        // and was announced as a turn that finished.
        for monitor in claudeMonitors {
            monitor.ignoredPIDs = { ClaudeUsageCLI.runningPIDs }
            monitor.ignoredWorkingDirectories = [ClaudeUsageCLI.scratchLocation().path]
        }

        // Renewing the token runs the Claude command, which registers a session
        // of its own for the second it lives. Every Claude monitor is told to
        // step over that pid, so it never reaches the notch and never counts as
        // work in progress.
        //
        // Only the default profile is renewed. The command writes whichever
        // directory `CLAUDE_CONFIG_DIR` names, so a second profile would need
        // that passed through — behaviour nobody has been able to try on a Mac
        // with two of them, and an unverified guess is worse here than a ring
        // that ages the way it already does.
        if let defaultProvider = claudeProviders.first(where: { $0.profile.slug == nil }) {
            let refresher = ClaudeTokenRefresher(
                expiry: { await defaultProvider.tokenExpiry },
                reload: { await defaultProvider.reloadTokenExpiry() }
            )
            for monitor in claudeMonitors {
                monitor.ignoredPIDs = { [weak refresher] in
                    var pids = ClaudeUsageCLI.runningPIDs
                    if let pid = refresher?.launchedPID { pids.insert(pid) }
                    return pids
                }
            }
            // The one place the failure becomes visible. The store carries the
            // fact; nothing here retries, and the warning clears itself the
            // moment a reading comes back.
            refresher.$outcome
                .receive(on: RunLoop.main)
                .sink { [weak self] outcome in
                    guard case .failed = outcome else { return }
                    self?.store?.reportRenewalFailed(providerID: defaultProvider.id)
                }
                .store(in: &cancellables)

            refresher.start()
            tokenRefresher = refresher
        }
        let activity = ActivityCoordinator(monitors: monitors) { [weak self, weak fleet] id, sessions in
            guard let fleet else { return }
            fleet.setSessions(providerID: id, sessions: sessions)
            self?.statusItem?.setActivity(providerID: id, sessions: sessions)
            self?.announceCompletions(sessions: fleet.sessions)
        }
        self.activityCoordinator = activity
        let monitorIDs = Set(monitors.keys)
        activity.setEnabled(Set(monitorIDs.filter { preferences.isConnected($0) }))
        preferences.$connectedProviders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak activity, weak preferences] _ in
                guard let preferences else { return }
                activity?.setEnabled(Set(monitorIDs.filter { preferences.isConnected($0) }))
            }
            .store(in: &cancellables)
        store?.isBusy = { [weak self, weak activity] in
            (activity?.isBusy ?? false) || (self?.lmstudioMetrics?.isBusy ?? false)
        }

        // Applied last, right before the panel goes up: every one of these
        // calls a `NotchFleet.apply(...)` that can trigger `reconcile()` on
        // its own — `displayPreference` always does, being how the very
        // first controller gets created — and `reconcile()` copies the
        // fleet's callbacks (`onOpenSettings`, `onRefreshProvider`, ...) into
        // that controller at creation time, not through a live reference.
        // Calling any of these earlier, before those callbacks were set
        // above, silently built the one controller this app ever has with
        // every action wired to nothing: the panel still opened and rings
        // still drew, so there was nothing to notice except every click
        // doing exactly nothing. `fleet.show()`'s own reconcile only ever
        // repositions an existing controller — it does not re-copy them —
        // so this has to be the very last thing that can create one.
        
        preferences.$phoneLinkEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard PhoneLink.isAvailable, let self = self, let srv = self.phoneLinkServer else { return }
                Task { @MainActor in
                    if enabled {
                        self.phoneLinkServerStatus?.state = .starting
                        do {
                            let prefPort = self.preferences?.phoneLinkPort ?? 8788
                            let port = try await srv.start(port: prefPort)
                            self.preferences?.phoneLinkPort = port
                            self.phoneLinkServerStatus?.state = .ready(port: port)
                        } catch {
                            self.phoneLinkServerStatus?.state = .failed(error.localizedDescription)
                        }
                    } else {
                        await srv.stop()
                        self.phoneLinkServerStatus?.state = .off
                    }
                }
            }
            .store(in: &cancellables)
        fleet.apply(displayPreference: preferences.displayPreference)
        fleet.apply(alongOffset: preferences.offset(for: preferences.notchEdge))
        fleet.apply(scale: preferences.notchScale)
        fleet.apply(resetTimeFormat: preferences.resetTimeFormat)
        fleet.apply(accentColor: preferences.accentColor)
        fleet.apply(watchLimit: preferences.watchLimit, criticalLimit: preferences.criticalLimit)
        fleet.apply(colorTransitionStyle: preferences.colorTransitionStyle)
        fleet.apply(weeklyRing: preferences.weeklyRing)
        fleet.apply(weeklyRingDashed: preferences.weeklyRingDashed)
        fleet.apply(showsNotchReadings: preferences.showsNotchReadings)
        fleet.apply(showsMoveHandle: preferences.showsMoveHandle)
        fleet.apply(foldsForFullScreen: preferences.foldsForFullScreen)
        fleet.apply(surfaceStyle: preferences.notchSurfaceStyle)
        fleet.apply(deepSeekPricingEnabled: preferences.deepSeekPricingEnabled)
        fleet.apply(deepSeekPricingSchedule: preferences.deepSeekPricingSchedule)
        fleet.show()
    }

    /// Open the notch, and make a noise, when something has just finished.
    ///
    /// The watcher is fed on every publication whether or not anything is
    /// switched on, because it is a difference engine: skipping a reading would
    /// leave it comparing against a state two changes old, and the *next*
    /// transition it reported would be one that never happened.
    ///
    /// Several sessions can land in the same reading — one turn ending often
    /// unblocks another — and that gets one peek and one chime rather than a
    /// chord. The newest is the one offered, since it is the one whose window
    /// you were most recently in.
    @MainActor
    private func announceCompletions(sessions: [String: [AgentSession]]) {
        let events = completions.absorb(sessions)
        guard let event = events.first, let preferences, let fleet = notchFleet else { return }
        Log.usage.info("session \(event.session.name, privacy: .public) \(String(describing: event.reason), privacy: .public)")

        if preferences.sessionEndSound {
            SessionChime.play(event.reason == .blocked
                              ? preferences.sessionBlockedSoundName
                              : preferences.sessionEndSoundName)
        }
        guard preferences.announceSessionEnd else { return }
        fleet.peek(for: preferences.peekDuration.seconds,
                   focusing: event.session.processID)
    }

    /// Open the notch and show a usage reset notification modal when a limit resets.
    @MainActor
    private func announceUsageReset(event: UsageResetEvent) {
        guard let preferences, let fleet = notchFleet else { return }
        Log.usage.info("usage reset for \(event.providerName, privacy: .public) (\(event.windowLabel, privacy: .public))")

        if preferences.usageResetSound {
            SessionChime.play(preferences.usageResetSoundName)
        }
        guard preferences.announceUsageReset else { return }
        if !fleet.showResetAlert(event, duration: 5.0) {
            UsageAlertNotifications.deliver(event)
        }
    }

    @MainActor
    private func previewUsageResetAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageResetEvent(
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "5-hour limit",
            glyph: .claude,
            previousFraction: 0.95,
            currentFraction: 0.00,
            resetsAt: Date().addingTimeInterval(5 * 3600)
        )
        if preferences.usageResetSound {
            SessionChime.play(preferences.usageResetSoundName)
        }
        fleet.showResetAlert(demo, duration: 5.0)
    }

    /// Open the notch and show a usage limit reached notification modal when a limit is exhausted.
    @MainActor
    private func announceUsageLimit(event: UsageAlertEvent) {
        guard let preferences, let fleet = notchFleet else { return }

        let isAnnounceEnabled: Bool
        switch event.kind {
        case .sessionLimitReached:
            isAnnounceEnabled = preferences.announceSessionLimitReached
        case .weeklyLimitReached:
            isAnnounceEnabled = preferences.announceWeeklyLimitReached
        case .reset:
            isAnnounceEnabled = preferences.announceUsageReset
        }

        guard isAnnounceEnabled else { return }

        Log.usage.info("usage limit reached for \(event.providerName, privacy: .public) (\(event.windowLabel, privacy: .public))")

        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        if !fleet.showResetAlert(event, duration: 6.0) {
            UsageAlertNotifications.deliver(event)
        }
    }

    @MainActor
    private func previewSessionLimitAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageAlertEvent(
            kind: .sessionLimitReached,
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "5-hour",
            glyph: .claude,
            previousFraction: 0.95,
            currentFraction: 1.00,
            resetsAt: Date().addingTimeInterval(45 * 60)
        )
        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        fleet.showResetAlert(demo, duration: 6.0)
    }

    @MainActor
    private func previewWeeklyLimitAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageAlertEvent(
            kind: .weeklyLimitReached,
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "Weekly",
            glyph: .claude,
            previousFraction: 0.98,
            currentFraction: 1.00,
            resetsAt: Date().addingTimeInterval(3 * 86400)
        )
        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        fleet.showResetAlert(demo, duration: 6.0)
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
        openSettings()
        return true
    }

    @MainActor func openSettings() { settings?.show() }
    @MainActor func openConnectPhone() {
        guard PhoneLink.isAvailable, let pairing = phoneLinkPairing, let registry = phoneLinkRegistry, let status = phoneLinkServerStatus else { return }
        if preferences?.phoneLinkEnabled == false { preferences?.phoneLinkEnabled = true }
        PhoneLinkWindowController.shared.show(pairing: pairing, registry: registry, port: preferences?.phoneLinkPort ?? 8788, serverStatus: status)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ollamaRelay?.configure(enabled: false, endpoint: OllamaEndpoint.defaultAddress)
        lmstudioMetrics?.stop()
        tokenRefresher?.stop()
        store?.stop()
        activityCoordinator?.stop()
        notchFleet?.stop()
        Task { await phoneLinkServer?.stop() }
    }
}
