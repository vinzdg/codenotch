import AppKit
import Combine
import os

/// Fetches every provider on a timer and keeps the last good answer around, so
/// a dropped network shows yesterday's number dimmed rather than a blank ring.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    /// Providers with a fetch in flight, so the cell can show it happening.
    @Published private(set) var refreshing: Set<String> = []
    /// Providers whose last fetch was refused by macOS, cleared as soon as one
    /// succeeds. The settings row's only honest basis for offering to ask again.
    @Published private(set) var refusedAccess: Set<String> = []

    private let providers: [UsageProvider]
    /// A response belongs to the connection that started it. Checking only
    /// `disconnected` would accept an old response after a quick off/on toggle.
    private var connectionVersions: [String: UUID] = [:]
    /// Providers the user has switched off. They are not fetched at all — their
    /// credential is never read, which is the whole point of switching one off.
    /// Filtering the results afterwards would still touch the keychain.
    @Published var disconnected: Set<String> = [] {
        didSet {
            guard disconnected != oldValue else { return }
            for id in disconnected.symmetricDifference(oldValue) {
                connectionVersions[id] = UUID()
            }
            snapshots.removeAll { disconnected.contains($0.id) }
            refusedAccess.subtract(disconnected)
            // The remembered reading has to go as well. Dropping it from
            // `snapshots` alone left it in `lastGood`, which is written to the
            // archive wholesale on every fetch — so a switched-off provider was
            // remembered forever and rebuilt from the archive at the next
            // launch, ring and all.
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
            refreshNow()
        }
    }

    /// The order the user has put the rings in, as provider ids.
    ///
    /// Held here rather than at each consumer because there are two consumers —
    /// the notch reads `snapshots`, settings reads `providerSummaries` — and
    /// they have to agree. Sorting each of them separately makes that agreement
    /// something two call sites have to keep remembering.
    @Published var order: [String] = [] {
        didSet {
            guard order != oldValue else { return }
            // Reordered in place, not refetched. The user has just dragged a
            // row and the rings have to follow now; re-reading every credential
            // to answer a question about layout would spend Claude's
            // rate-limit budget on nothing.
            snapshots = ProviderOrder.arrange(snapshots, by: order, id: \.id)
        }
    }

    /// `providers` in the user's order. Every read of `providers` that ends up
    /// on screen goes through this.
    private var orderedProviders: [UsageProvider] {
        ProviderOrder.arrange(providers, by: order, id: \.id)
    }

    /// Whether any provider is actively being used right now. Your usage cannot
    /// move while nothing is running, so polling hard through a quiet afternoon
    /// spends rate-limit budget to re-read a number that has not changed.
    var isBusy: () -> Bool = { false }

    private let refreshInterval: TimeInterval
    /// How long a snapshot stays believable after its last successful fetch.
    ///
    /// Comfortably above `idleRefreshInterval`, on purpose. With the two equal,
    /// a ring dimmed the instant the *first* idle refresh attempt failed —
    /// which reads as "nothing is being read any more" when what actually
    /// happened is one attempt, five minutes ago, out of what will keep being
    /// tried every five minutes after. The margin buys room for a couple of
    /// those attempts to have genuinely failed before the ring says so; it
    /// must never fire merely because the idle schedule hasn't come round yet.
    private let staleAfter: TimeInterval
    /// How often to look when nothing is running.
    private let idleRefreshInterval: TimeInterval
    private var lastAttempt: Date?

    private let archive: UsageArchive
    private var lastGood: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// Set synchronously before the task exists, so "is one already running"
    /// never depends on when the task body happens to start.
    private var isRefreshing = false
    private var wakeObserver: NSObjectProtocol?

    init(
        providers: [UsageProvider],
        refreshInterval: TimeInterval = 60,
        idleRefreshInterval: TimeInterval = 5 * 60,
        staleAfter: TimeInterval = 15 * 60,
        archive: UsageArchive = UsageArchive(),
        disconnected: Set<String> = [],
        order: [String] = []
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        self.idleRefreshInterval = idleRefreshInterval
        self.staleAfter = staleAfter
        self.archive = archive

        // Open on what we knew last time rather than on an empty ring; the
        // first fetch will either confirm it or replace it.
        // Set through the wrapper's storage, not `self.disconnected = …`.
        // `disconnected` is `@Published`, so a plain assignment here runs its
        // `didSet` — which saves `lastGood` to the archive. At this point
        // `lastGood` is still empty, so it wrote an empty archive and destroyed
        // every remembered reading on any launch with a provider switched off.
        _disconnected = Published(initialValue: disconnected)
        // Through the wrapper's storage for the same reason `_disconnected` is:
        // a plain assignment runs the `didSet`, which sorts a `snapshots` that
        // does not exist yet and is then immediately thrown away below.
        _order = Published(initialValue: order)
        lastGood = archive.load()
        // Pruned here as well as in `didSet`, because `didSet` cannot be relied
        // on to run: it guards against a no-op change, and the value the
        // preference binding delivers a moment later is usually identical to
        // the one passed in here. A provider switched off in a previous session
        // would then keep its archived reading indefinitely.
        if lastGood.keys.contains(where: disconnected.contains) {
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
        }
        // Filtered here, not only in `didSet`. The store is built before the
        // preference reaches it, so an unfiltered first pass draws every
        // switched-off provider for as long as it takes the binding to arrive.
        snapshots = orderedProviders.filter { !disconnected.contains($0.id) }.map { provider in
            guard let remembered = lastGood[provider.id] else { return Self.placeholder(provider) }
            var snapshot = remembered.snapshot
            snapshot.status = .stale(since: remembered.fetchedAt)
            return snapshot
        }
    }

    /// Enough to list the providers in settings without exposing them.
    var providerSummaries: [ProviderSummary] {
        orderedProviders.map { provider in
            ProviderSummary(id: provider.id, name: provider.displayName,
                            glyph: provider.glyph,
                            account: disconnected.contains(provider.id) ? nil : provider.account(),
                            signIn: provider.signInRoute,
                            wasRefusedAccess: refusedAccess.contains(provider.id))
        }
    }

    func start() {
        refreshNow()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Waking up is the one moment the numbers are guaranteed to be wrong.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        isRefreshing = false
        // Block-based observers are not removed by `removeObserver(self)`.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Decides whether this tick is worth a request at all.
    private func tick() {
        let waited = lastAttempt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard Self.shouldRefresh(
            isBusy: isBusy(),
            sinceLastAttempt: waited,
            idleInterval: idleRefreshInterval
        ) else { return }
        refreshNow()
    }

    /// Poll at full rate while something is running; otherwise wait out the
    /// idle interval. Pure, so the schedule can be tested without a clock.
    static func shouldRefresh(
        isBusy: Bool,
        sinceLastAttempt: TimeInterval,
        idleInterval: TimeInterval
    ) -> Bool {
        isBusy || sinceLastAttempt >= idleInterval
    }

    func refreshNow() {
        guard !isRefreshing else {
            Log.usage.notice("refresh skipped: one already in flight")
            return
        }
        isRefreshing = true
        lastAttempt = Date()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.isRefreshing = false
        }
    }

    func refresh() async {
        let live = orderedProviders.filter { !disconnected.contains($0.id) }
        let versions = connectionVersions
        refreshing = Set(live.map(\.id))
        defer { refreshing = [] }
        var next: [ProviderSnapshot] = []
        for provider in live {
            if let fresh = await snapshot(from: provider, version: versions[provider.id]) {
                next.append(fresh)
            }
        }
        // An earlier result can have been disconnected while a later provider
        // was awaiting its response. Do not put that reading back on screen.
        snapshots = next.filter { isCurrent($0.id, version: versions[$0.id]) }
    }

    /// Refetch one provider, leaving the others alone.
    ///
    /// Deliberately not routed through `refreshNow`: asking one cell for a fresh
    /// reading should not spend every other provider's rate-limit budget, and
    /// Claude's in particular is easy to exhaust.
    func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              !disconnected.contains(providerID),
              !refreshing.contains(providerID) else { return }

        refreshing.insert(providerID)
        let version = connectionVersions[providerID]
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing.remove(providerID) }
            guard let fresh = await self.snapshot(from: provider, version: version) else { return }
            if let index = self.snapshots.firstIndex(where: { $0.id == providerID }) {
                self.snapshots[index] = fresh
            }
            self.lastAttempt = Date()
            // A beat of visible work even when the answer was instant: a spinner
            // that flashes for one frame reads as a glitch, not as a refresh.
            try? await Task.sleep(nanoseconds: 380_000_000)
        }
    }

    /// Sign out of one provider: discard anything of its account that this app
    /// is holding, and stop reading it.
    ///
    /// Deliberately more than `disconnected` alone. Switching a provider off
    /// stops the *next* read; it leaves the last one archived, so the numbers
    /// come back on the next launch. Someone who presses Sign out means those
    /// numbers to be gone.
    ///
    /// What it cannot do is end the session at the vendor: for every provider
    /// shipping today the credential belongs to Claude Code, Cursor or Codex,
    /// and deleting their keychain item would sign the user out of an app they
    /// did not ask us to touch. `SignInRoute.signOutCaveat` says so on the row.
    func signOut(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }

        // The settings binding calls signOut before delivering disconnected.
        // Invalidate pending responses immediately, before that binding arrives.
        connectionVersions[providerID] = UUID()
        refusedAccess.remove(providerID)
        snapshots.removeAll { $0.id == providerID }
        lastGood.removeValue(forKey: providerID)
        archive.forget(providerID)

        Task { await provider.signOut() }
    }

    /// Take the user to wherever this provider's account is signed into.
    ///
    /// Three different places, because the providers differ in what they own: a
    /// `WebSessionProvider` presents its own modal, Cursor and Codex hold the
    /// credential in their app so the app is launched, and Claude Code is a
    /// command with nothing to open — the row's guidance is all there is.
    /// Returns whether anything was actually opened, so the sheet can say so
    /// when nothing was.
    @discardableResult
    func signIn(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        // Already holding a usable credential: connecting is the whole job, and
        // throwing up a sign-in window over a signed-in account is just noise.
        if provider.account() != nil {
            refresh(providerID: providerID)
            return true
        }

        return openAccountSource(providerID: providerID)
    }

    /// Ask macOS for this provider's credential again.
    ///
    /// The remedy for a declined keychain prompt. Dropping the in-memory copy
    /// first is the part that matters: a plain refresh is served from the cache
    /// whenever the token is still valid, so the keychain is never touched and
    /// the prompt never returns — the button would appear to do nothing.
    func reauthorize(providerID: String) {
        providers.first { $0.id == providerID }?.forgetCachedCredential()
        refresh(providerID: providerID)
    }

    /// Take the user to where this provider's account is *changed*.
    ///
    /// Same destination as signing in, but unconditional: switching accounts is
    /// something you do while already signed in, so the shortcut `signIn` takes
    /// when a credential exists is exactly wrong here.
    ///
    /// Codenotch cannot switch the account itself. The credential belongs to
    /// Claude Code, Cursor or Codex, and the most this can honestly do is open
    /// the thing that owns it.
    @discardableResult
    func openAccountSource(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        switch provider.signInRoute {
        case .modal:
            provider.presentSignIn()
            return true
        case .openApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return false }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        case .guidance:
            // Claude Code: nothing to open. The row's guidance is the whole
            // answer, so the sheet has to show it rather than pretend.
            return false
        }
    }

    private func isCurrent(_ providerID: String, version: UUID?) -> Bool {
        !Task.isCancelled && !disconnected.contains(providerID)
            && connectionVersions[providerID] == version
    }

    private func snapshot(from provider: UsageProvider, version: UUID?) async -> ProviderSnapshot? {
        // A provider may have been switched off while waiting behind another
        // provider in the serial refresh. Do not read its credential at all.
        guard isCurrent(provider.id, version: version) else { return nil }
        do {
            let fresh = try await provider.fetchSnapshot()
            guard isCurrent(provider.id, version: version) else { return nil }
            lastGood[provider.id] = (fresh, Date())
            archive.save(lastGood)
            refusedAccess.remove(provider.id)
            Log.usage.debug("\(provider.id, privacy: .public): \(fresh.windows.count) window(s)")
            return fresh
        } catch {
            guard isCurrent(provider.id, version: version) else { return nil }
            Log.usage.error("\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return degraded(provider: provider, error: error)
        }
    }

    /// A failed fetch never invents a number: it either re-shows the last good
    /// one marked stale, or shows the cell with no reading at all.
    private func degraded(provider: UsageProvider, error: Error) -> ProviderSnapshot {
        let status = Self.status(for: error)

        // Remembered apart from the snapshot on purpose. The snapshot answers
        // "how good are the numbers I am showing", and for a refusal the honest
        // answer is "still fine, just ageing" — which is why `supersedesHistory`
        // keeps the old reading and its status. That deliberately loses the one
        // fact the settings row needs: whether macOS let us in last time. Two
        // different questions, so two different places to keep the answer.
        if case .accessDenied = status {
            refusedAccess.insert(provider.id)
        } else {
            refusedAccess.remove(provider.id)
        }

        // Some failures are statements about the account rather than a hiccup:
        // signed out, or a plan that meters nothing. Re-showing an old reading
        // through one of those would present a number that is no longer true —
        // and, after an endpoint change, one that came from somewhere we no
        // longer read. So the remembered reading is dropped, not dimmed.
        if Self.supersedesHistory(status) {
            lastGood[provider.id] = nil
            archive.save(lastGood)
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        guard let previous = lastGood[provider.id] else {
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        // A stale-but-recent reading is still worth showing undimmed; past the
        // window it gets marked, and the ring dims.
        let age = Date().timeIntervalSince(previous.fetchedAt)
        var snapshot = previous.snapshot
        snapshot.status = age > staleAfter ? .stale(since: previous.fetchedAt) : previous.snapshot.status
        return snapshot
    }

    /// True when the new status makes any remembered reading untrue rather than
    /// merely old.
    static func supersedesHistory(_ status: ProviderStatus) -> Bool {
        switch status {
        case .needsAuth, .unsupported: return true
        // A refusal says nothing about the reading — the credential is there
        // and still valid, we were simply not let in to re-read it. Discarding
        // the last number would punish someone for pressing the wrong button.
        case .accessDenied:            return false
        case .ok, .stale, .error:      return false
        }
    }

    /// Exposed for the tests: the store never invents a reading, so what a
    /// failure looks like is worth pinning down.
    static func statusForTesting(_ error: Error) -> ProviderStatus { status(for: error) }

    /// Exposed so a test can hold the shipped defaults to the margin they are
    /// supposed to keep, without re-typing the numbers on both sides.
    var staleAfterForTesting: TimeInterval { staleAfter }
    var idleRefreshIntervalForTesting: TimeInterval { idleRefreshInterval }

    private static func status(for error: Error) -> ProviderStatus {
        switch error {
        case UsageProviderError.needsAuth:
            return .needsAuth
        case UsageProviderError.credentialExpired:
            // Ages the reading rather than discarding it: the number was true
            // when it was taken, and the token will refresh itself in the
            // ordinary course of using the app that owns it.
            return .stale(since: Date())
        case UsageProviderError.rateLimited:
            // Not an error the user can do anything about, and the last good
            // reading is still roughly true, so it reads as staleness.
            return .stale(since: Date())
        case UsageProviderError.accessDenied:
            return .accessDenied
        case UsageProviderError.nothingMetered(let why):
            return .unsupported(why)
        case UsageProviderError.badResponse(let code):
            return .error("HTTP \(code)")
        default:
            return .error((error as NSError).localizedDescription)
        }
    }

    private static func placeholder(_ provider: UsageProvider) -> ProviderSnapshot {
        ProviderSnapshot(
            id: provider.id,
            displayName: provider.displayName,
            glyph: provider.glyph,
            fidelity: .official,
            status: .stale(since: .distantPast),
            windows: []
        )
    }
}
