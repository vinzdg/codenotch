import AppKit
import WebKit
import os

/// Holds the only state a switch flow needs from the old session. The raw
/// browser token never leaves JavaScript and its digest is kept in memory only.
struct WebSessionAuthenticationGate: Equatable {
    private(set) var baselineFingerprint: String?
    private(set) var sawLogout = false
    private let requiresNewFingerprint: Bool
    private var unauthenticatedSamples = 0

    init(baselineFingerprint: String?, requiresNewFingerprint: Bool = true) {
        self.baselineFingerprint = baselineFingerprint
        self.requiresNewFingerprint = requiresNewFingerprint
    }

    /// A sign-in window commits only after a real logout/login transition.
    /// Switching accounts additionally requires a new session identity. This
    /// keeps an already-authenticated old page from being mistaken for the new
    /// account.
    mutating func observe(authenticated: Bool, fingerprint: String?) -> Bool {
        guard authenticated else {
            unauthenticatedSamples += 1
            // A normal sign-in only needs one settled logged-out sample because
            // the page is newly opened for this flow. Switching accounts keeps
            // two samples to avoid treating a transient probe failure as a
            // completed logout of the old account.
            if unauthenticatedSamples >= (requiresNewFingerprint ? 2 : 1) {
                sawLogout = true
            }
            return false
        }

        unauthenticatedSamples = 0
        guard sawLogout else {
            if baselineFingerprint == nil { baselineFingerprint = fingerprint }
            return false
        }

        // A normal sign-in only needs a real logged-out -> logged-in
        // transition. Switching accounts additionally requires a different
        // fingerprint, so signing back into the old account cannot commit a
        // switch accidentally.
        if requiresNewFingerprint {
            guard baselineFingerprint == nil || fingerprint == nil || fingerprint != baselineFingerprint
            else { return false }
        }
        return true
    }

    /// A user closing the window is an explicit end to the flow, so one final
    /// authenticated probe can commit a completed login even when the polling
    /// task did not get a chance to observe the logged-out state first.
    /// A switch still cannot commit the existing account on close.
    func acceptsAuthenticatedStateOnManualClose(
        authenticated: Bool,
        fingerprint: String?
    ) -> Bool {
        guard authenticated else { return false }
        guard requiresNewFingerprint else { return true }
        return baselineFingerprint == nil || fingerprint == nil || fingerprint != baselineFingerprint
    }

}

/// Reads a provider's usage from the endpoint its own web app uses, by running
/// the request *inside a browser the user signs into themselves*.
///
/// **Why a WebView rather than a cookie.** Some of these sites sit behind bot
/// management — an unauthenticated probe of Perplexity's endpoint comes back
/// `403 cf-mitigated: challenge`. A session cookie does not help, because the
/// `cf_clearance` beside it is bound to the TLS and HTTP fingerprint of the
/// browser that earned it. Making `URLSession` pass would mean impersonating
/// Chrome, which is defeating bot detection rather than reading your own usage.
/// Lifting cookies out of Chrome's encrypted store is its own problem again.
///
/// So the request is made by a browser: a WKWebView with the app's own
/// persistent store. Nothing is taken from Chrome or Safari, no fingerprint is
/// faked, and a challenge is only ever answered by the person sitting there.
@MainActor
final class WebSessionProvider: NSObject, UsageProvider {
    /// Everything site-specific, so the browser plumbing is written once.
    struct Site {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let origin: URL
        let fidelity: Fidelity
        let authProbeScript: String?
        let sessionKey: String?
        let forbiddenMessage: String?
        let logsResponseBody: Bool
        /// Extra hosts whose website data is cleared on sign-out, besides
        /// `origin.host`. MiniMax's session is created on the platform origin
        /// and used on www, so both have to go; DeepSeek has none.
        let associatedHosts: [String]
        /// Whether the sign-in window asks the probe every 1.5 s while it is
        /// open, and closes itself once signed in.
        ///
        /// Off unless a site asks for it. DeepSeek and MiniMax confirm once, when
        /// the window closes (#172): their probes are real API calls to
        /// endpoints that have throttled this app, and polling them while
        /// someone types a password is how that happened.
        let pollsDuringSignIn: Bool
        /// Whether a refused usage read gets one silent page reload and one
        /// more attempt before the provider reports `needsAuth`.
        ///
        /// Off unless a site asks for it, and on only where a refused read is
        /// the site retiring its own console session rather than the user
        /// signing out: the SSO session behind the page still answers, so
        /// reloading the page mints a fresh cookie with no credentials at all.
        /// Without it, one 401 flips `hasSignedIn` and the ring goes dark for
        /// good — every later refresh short-circuits on that flag without
        /// touching the network, so the only way back is the manual sign-in
        /// window whose reload did the same thing. A site whose 401 means a
        /// genuinely dead session (DeepSeek, MiniMax — the endpoints this app
        /// has been throttled on) stays off: one reload there buys nothing
        /// and asks a refused endpoint twice.
        let reloadsSessionOnAuthFailure: Bool
        /// The page under `origin` where this account's plan or usage can be
        /// seen — what the settings row's manage link opens. A path rather
        /// than a whole URL because it is always a page on the site the user
        /// signed into, and not always the obvious one: QianwenAI's console
        /// serves its SPA only under `/home`, so `origin/usage` is a 404.
        let managePath: String
        let initialPath: String
        let bootstrapScript: String?
        /// Semantic window roles declared by the site, rather than inferred
        /// from array order or display copy.
        let headlineID: String?
        let weeklyID: String?
        /// Runs in the page as an async function body. Must return a JSON string
        /// `{ "status": Int, "body": String }`.
        let script: String
        /// Turns the response body into windows, or throws if it cannot.
        let parse: (String) throws -> [LimitWindow]
        let detailParse: ((String) throws -> ProviderUsageDetail?)?

        init(id: String, displayName: String, glyph: ProviderGlyph, origin: URL,
             script: String, fidelity: Fidelity = .official,
             authProbeScript: String? = nil,
             sessionKey: String? = nil,
             forbiddenMessage: String? = nil,
             logsResponseBody: Bool = true,
             associatedHosts: [String] = [],
             pollsDuringSignIn: Bool = false,
             reloadsSessionOnAuthFailure: Bool = false,
             managePath: String = "usage",
             initialPath: String = "",
             bootstrapScript: String? = nil,
             headlineID: String? = nil,
             weeklyID: String? = nil,
             detailParse: ((String) throws -> ProviderUsageDetail?)? = nil,
             parse: @escaping (String) throws -> [LimitWindow]) {
            self.id = id
            self.displayName = displayName
            self.glyph = glyph
            self.origin = origin
            self.script = script
            self.fidelity = fidelity
            self.authProbeScript = authProbeScript
            self.sessionKey = sessionKey
            self.forbiddenMessage = forbiddenMessage
            self.logsResponseBody = logsResponseBody
            self.associatedHosts = associatedHosts
            self.pollsDuringSignIn = pollsDuringSignIn
            self.reloadsSessionOnAuthFailure = reloadsSessionOnAuthFailure
            self.managePath = managePath
            self.initialPath = initialPath
            self.bootstrapScript = bootstrapScript
            self.headlineID = headlineID
            self.weeklyID = weeklyID
            self.detailParse = detailParse
            self.parse = parse
        }
    }

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph: ProviderGlyph
    /// A browser-session provider is the one kind that really can sign you in:
    /// the session lives in its own WebView, so it can open one and clear one.
    nonisolated var signInRoute: SignInRoute { .modal(name: displayName) }

    /// A successful browser probe is the account identity this provider can
    /// honestly expose. DeepSeek does not include an email or plan in the
    /// usage payload we read, but the persisted session is enough to keep the
    /// settings row in its signed-in state after the sheet is reopened.
    nonisolated func account() -> ProviderAccount? {
        guard UserDefaults.standard.bool(forKey: "\(id).signedIn") else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: displayName,
            manageURL: site.origin.appendingPathComponent(site.managePath)
        )
    }

    /// `nonisolated(unsafe)` so `account()` can still read the origin the way
    /// DeepSeek does. Mutation stays on the main actor via `apply(site:)`.
    nonisolated(unsafe) private var site: Site
    private var webView: WKWebView?
    private var signInWindow: NSWindow?
    private var signInProbeTask: Task<Void, Never>?
    private var isLoaded = false
    private var contextRevision: UInt = 0
    private var lastAuthFingerprint: String?
    /// The URL of the page the sign-in poll last actually probed, so a sheet
    /// sitting unchanged on one page is not asked the same question every tick.
    private var lastProbedURL: URL?
    private var switchGate: WebSessionAuthenticationGate?
    private let loadPageForTesting: (@MainActor (WKWebView, URLRequest) async throws -> Void)?

    var onAuthenticated: (() -> Void)?

    init(site: Site, loadPageForTesting: (@MainActor (WKWebView, URLRequest) async throws -> Void)? = nil) {
        self.site = site
        self.id = site.id
        self.displayName = site.displayName
        self.glyph = site.glyph
        self.loadPageForTesting = loadPageForTesting
        super.init()
    }

    /// MiniMax's platform origin and www remains URL both follow the chosen
    /// region. DeepSeek never needs this — its site is a constant. Identity
    /// (`id` / `displayName` / `glyph`) is fixed at init; a different site
    /// id is ignored so a region switch cannot become a provider switch.
    func apply(site: Site) {
        guard site.id == id else { return }
        // Retire the old page and pending sign-in before rebinding the origin.
        signInProbeTask?.cancel()
        signInProbeTask = nil
        switchGate = nil
        signInWindow?.delegate = nil
        signInWindow?.close()
        signInWindow = nil
        webView?.stopLoading()
        webView = nil
        lastAuthFingerprint = nil
        contextRevision &+= 1
        self.site = site
        isLoaded = false
    }

    /// Set once a sign-in has been opened. Until then the provider makes no
    /// request at all: quietly loading someone's account page in a hidden
    /// WebView every minute, unasked, would be both wasteful and reasonably
    /// indistinguishable from automation.
    ///
    /// Keyed by the provider's identity, not `site.id`, so a mistaken
    /// `apply(site:)` cannot rebind DeepSeek's flag onto MiniMax or vice versa.
    nonisolated static func sessionKey(for site: Site) -> String {
        site.sessionKey ?? "\(site.id).signedIn"
    }

    /// Whether a console page is alive in the hidden view. Readable so the
    /// test can prove a page does not outlive the read it was loaded for —
    /// the six-day, 540 MB page was never visible from outside.
    var holdsPageForTesting: Bool { webView != nil }
    var pageForTesting: WKWebView? { webView }
    var signInWindowForTesting: NSWindow? { signInWindow }
    /// Forgets the sheet the way `windowWillClose` does, without its
    /// close-time probe or its page release — so a test can isolate the
    /// `keeping` guard from the window guard.
    func clearSignInWindowForTesting() { signInWindow = nil }

    private var hasSignedIn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.sessionKey(for: site)) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionKey(for: site)) }
    }

    // MARK: - The browser

    nonisolated static func matchesOrigin(_ url: URL?, expected origin: URL) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let expectedScheme = origin.scheme?.lowercased(),
              let expectedHost = origin.host?.lowercased()
        else { return false }
        return scheme == expectedScheme
            && host == expectedHost
            && effectivePort(for: url) == effectivePort(for: origin)
    }

    /// MiniMax's missing-cookie code is 1004, often under HTTP 200 (the
    /// page script maps that to 401). A raw 1004 must still be needsAuth,
    /// not `badResponse(1004)`.
    nonisolated static func isAuthenticationFailureStatus(_ status: Int) -> Bool {
        status == 401 || status == 403 || status == 1004
    }

    /// Hosts whose website data sign-out clears. Origin plus `associatedHosts`,
    /// never MiniMax's www by default — DeepSeek and Perplexity would otherwise
    /// wipe a MiniMax session (or accept www as same-origin if this list were
    /// fed into `matchesOrigin`).
    nonisolated static func websiteDataHosts(for site: Site) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for host in [site.origin.host].compactMap({ $0 }) + site.associatedHosts {
            let key = host.lowercased()
            guard seen.insert(key).inserted else { continue }
            hosts.append(key)
        }
        return hosts
    }

    private nonisolated static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // persists across launches
        // Records the API calls the page makes, so an endpoint can be found by
        // watching the site rather than by guessing at path names. Injected at
        // document start, because the interesting calls happen during load.
        configuration.userContentController.addUserScript(WKUserScript(
            source: #"""
            window.__notchCalls = [];
            (function () {
                // Capped: a console SPA makes hundreds of calls a day, and an
                // unbounded array of URL strings is one more thing that grows
                // for as long as the page lives. Discovery only needs the tail.
                const record = (url) => {
                    try {
                        if (window.__notchCalls.length >= 2000) window.__notchCalls.shift();
                        window.__notchCalls.push(String(url));
                    } catch (e) {}
                };
                const fetchImpl = window.fetch;
                window.fetch = function (...args) {
                    try {
                        const url = args[0] && args[0].url ? args[0].url : args[0];
                        record(url);
                    } catch (e) {}
                    return fetchImpl.apply(this, args);
                };
                const openImpl = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function (method, url) {
                    try { record(url); } catch (e) {}
                    return openImpl.apply(this, arguments);
                };
            })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        if let bootstrapScript = site.bootstrapScript {
            configuration.userContentController.addUserScript(WKUserScript(
                source: bootstrapScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                configuration: configuration)
        self.webView = webView
        return webView
    }

    private func checkFetchContext(for page: WKWebView, revision: UInt) throws {
        try Task.checkCancellation()
        guard revision == contextRevision, page === webView else { throw CancellationError() }
    }

    /// Settles the caller's page on the site's origin. A retired page cannot
    /// update the loaded state of its replacement.
    private func ensureLoaded(_ page: WKWebView, revision: UInt) async throws {
        try checkFetchContext(for: page, revision: revision)
        let origin = site.origin
        if isLoaded, Self.matchesOrigin(page.url, expected: origin) { return }
        let url = site.initialPath.isEmpty ? origin : origin.appendingPathComponent(site.initialPath)
        let request = URLRequest(url: url)
        if let loadPageForTesting {
            try await loadPageForTesting(page, request)
        } else {
            page.load(request)
            try await waitForPageToSettle(page, origin: origin, revision: revision)
        }
        try checkFetchContext(for: page, revision: revision)
        isLoaded = true
    }

    private func waitForPageToSettle(_ page: WKWebView, origin: URL, revision: UInt) async throws {
        // Settled is a state the page has to *stay* in, not a moment it passes
        // through. These consoles commit their HTML and hand off to SSO a beat
        // later from script, so the first instant of "same origin, not
        // loading" is often the gap *before* that hop — and a read fired there
        // goes out on the cookie the site is in the middle of retiring: the
        // 401 that took the ring down, and the reload's retry that followed it
        // straight back into the same gap 345 ms later. Four quiet ticks (a
        // second) before the page is believed; any navigation in them starts
        // the count again, so a redirecting page is followed *through* its
        // redirects — the SSO round trip included — rather than sampled ahead
        // of them. The budget covers the round trip: eighty ticks, twenty
        // seconds, well inside the store's own deadline for one pass.
        var settledTicks = 0
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 250_000_000)
            try checkFetchContext(for: page, revision: revision)
            if Self.matchesOrigin(page.url, expected: origin), !page.isLoading {
                settledTicks += 1
                if settledTicks >= 4 { return }
            } else {
                settledTicks = 0
            }
        }
        Log.usage.error("\(self.id, privacy: .public) page never reached a same-origin state")
        throw UsageProviderError.badResponse(status: 0)
    }

    /// Lets the page go between reads, keeping only the cookie jar.
    ///
    /// A live console is the one thing in this app that grows without bound.
    /// DeepSeek's platform SPA sat in a hidden view for the life of the process
    /// — six days is one WebContent process at 540 MB, still running its own
    /// timers — and on a machine already into the compressor that page cost the
    /// UI process half a second per frame whenever a poll woke it. Every refresh
    /// resumed it from process suspension and the stalls followed the resumes
    /// exactly: 203 "main thread dispatch stuck" in seven minutes, all on that
    /// page's drawing area, none on the 80 MB one beside it.
    ///
    /// The session lives in `WKWebsiteDataStore.default()` and survives the
    /// view, so the next read loads the console again with the same cookies
    /// and the same answer. What it does not carry over is the page's own heap,
    /// its timers, and the `window.__notchCalls` array the discovery script
    /// grows on every `fetch` the SPA makes. A reload per poll is the price —
    /// a second or so, against a read that already takes one.
    ///
    /// Only while the page is not on screen and nobody is asking it a question:
    /// a sign-in window showing this view is the person's to close, the sheet's
    /// close-time probe (below) is mid-read on it, and `recordCalls` reads the
    /// page it loaded.
    ///
    /// A refresh passes its concrete page so that finishing after a region
    /// change leaves the replacement page alone. Lifecycle callers can omit
    /// the page to release the current one.
    func releasePage(keeping page: WKWebView? = nil) {
        guard signInWindow == nil, signInProbeTask == nil,
              page == nil || page === webView else { return }
        webView?.stopLoading()
        webView = nil
        isLoaded = false
    }

    nonisolated static func responseFailure(status: Int, site: Site) -> UsageProviderError? {
        if status == 403, let message = site.forbiddenMessage { return .apiError(message) }
        if isAuthenticationFailureStatus(status) { return .needsAuth }
        if !(200..<300).contains(status) { return .badResponse(status: status) }
        return nil
    }

    // MARK: - Fetching

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard hasSignedIn else { throw UsageProviderError.needsAuth }
        try Task.checkCancellation()
        let revision = contextRevision
        let page = makeWebViewIfNeeded()
        // Loading may suspend before it can return. Cleanup already owns this
        // page so a region change during loading cannot redirect that cleanup.
        defer { releasePage(keeping: page) }

        // One silent reload per read at most, while the session flag stands.
        var reloadedForSession = false
        while true {
            // A sign-out during the reload must prevent another read.
            guard hasSignedIn else { throw UsageProviderError.needsAuth }
            try await ensureLoaded(page, revision: revision)
            try checkFetchContext(for: page, revision: revision)

            // `callAsyncJavaScript`, not `evaluateJavaScript`. The latter returns
            // whatever the last expression evaluates to and never awaits it, so an
            // async body hands back an unresolved Promise — an unsupported type,
            // which surfaces as an opaque failure instead of the response.
            let result: Any?
            do {
                result = try await page.callAsyncJavaScript(
                    site.script, arguments: [:], in: nil, contentWorld: .page
                )
            } catch {
                try checkFetchContext(for: page, revision: revision)
                Log.usage.error("\(self.site.id, privacy: .public) fetch script failed: \(error.localizedDescription, privacy: .public)")
                throw UsageProviderError.badResponse(status: 0)
            }

            try checkFetchContext(for: page, revision: revision)
            guard let text = result as? String,
                  let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = envelope["status"] as? Int,
                  let body = envelope["body"] as? String
            else {
                Log.usage.error("\(self.site.id, privacy: .public) response unreadable: \(String(describing: result), privacy: .public)")
                throw UsageProviderError.badResponse(status: 0)
            }

            if let failure = Self.responseFailure(status: status, site: site) {
                if case .needsAuth = failure {
                    // The status, logged before anything gives up on it: a 401
                    // (the site retired this session) and a 403 (the door shut
                    // on this client outright) used to arrive as the same
                    // undifferentiated "needsAuth", with nothing in the log to
                    // tell them apart.
                    Log.usage.notice("\(self.site.id, privacy: .public) read refused: HTTP \(status, privacy: .public)")
                    if !reloadedForSession, try await reloadToReestablishSession(page, revision: revision) {
                        reloadedForSession = true
                        continue
                    }
                    try checkFetchContext(for: page, revision: revision)
                    hasSignedIn = false
                }
                throw failure
            }

            // Recorded verbatim so a parser can be written against the real thing.
            // Not for sites whose response carries account details beyond the
            // numbers: DeepSeek's, and QianwenAI's console envelope, whose other
            // fields are undocumented.
            if !site.logsResponseBody || ["deepseek", "qianwenai"].contains(site.id) {
                Log.usage.notice("\(self.site.id, privacy: .public) usage response received")
            } else {
                Log.usage.notice("\(self.site.id, privacy: .public) usage -> \(body.prefix(1200), privacy: .public)")
            }
            if let probes = envelope["probes"] as? String {
                Log.usage.notice("\(self.site.id, privacy: .public) probes -> \(probes.prefix(2600), privacy: .public)")
            }

            let windows: [LimitWindow]
            let usageDetail: ProviderUsageDetail?
            do {
                windows = try site.parse(body)
                usageDetail = try site.detailParse?(body)
            } catch UsageProviderError.needsAuth {
                // HTTP 200 with a 1004 body that the page script missed: still a
                // dead session, not a signed-in parse error.
                if !reloadedForSession, try await reloadToReestablishSession(page, revision: revision) {
                    reloadedForSession = true
                    continue
                }
                try checkFetchContext(for: page, revision: revision)
                hasSignedIn = false
                throw UsageProviderError.needsAuth
            }

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: site.fidelity,
                status: .ok,
                windows: windows,
                headlineID: site.headlineID,
                weeklyID: site.weeklyID,
                usageDetail: usageDetail
            )
        }
    }

    /// Reloads the page once and reports whether the caller may read again.
    ///
    /// MiMo's console is the case this exists for: the site retires the
    /// cookie the usage fetch is authorized by while the SSO session behind
    /// the page still answers, so a refused read there does not mean the user
    /// signed out. Loading the console again bounces through SSO and mints a
    /// fresh cookie with no credentials at all — which is exactly why the
    /// sign-in window opens "already logged in" the moment after the ring went
    /// dark, and why closing it brought the percentage back. This is that
    /// reload, done by the provider instead of by the user's hand.
    ///
    /// If the reload never settles, or the reloaded page is refused too, the
    /// session really is gone and this returns false so the read ends in
    /// `needsAuth` precisely as it did before — and for a site with the flag
    /// off this function does nothing at all. One reload, one retry, then the
    /// silence a dead session has always had: an endpoint that has throttled
    /// this app is never asked twice on the way out.
    private func reloadToReestablishSession(_ page: WKWebView, revision: UInt) async throws -> Bool {
        try checkFetchContext(for: page, revision: revision)
        guard site.reloadsSessionOnAuthFailure else { return false }
        isLoaded = false
        do {
            try await ensureLoaded(page, revision: revision)
            return true
        } catch {
            try checkFetchContext(for: page, revision: revision)
            Log.usage.error("\(self.site.id, privacy: .public) session re-load never settled")
            return false
        }
    }

    /// Loads a page and reports the API calls it made. A discovery tool, not
    /// part of a refresh.
    func recordCalls(on url: URL, settleFor seconds: Double = 8) async -> [String] {
        let webView = makeWebViewIfNeeded()
        webView.load(URLRequest(url: url))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        isLoaded = false   // the page moved; the next refresh reloads its own
        let result = try? await webView.callAsyncJavaScript(
            "return JSON.stringify(window.__notchCalls || []);",
            arguments: [:], in: nil, contentWorld: .page
        )
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let calls = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        // No "/api/" filter: a tRPC or GraphQL endpoint would not match it, and
        // missing the one call that matters is the whole failure mode here.
        let interesting = calls.filter { url in
            !url.hasSuffix(".js") && !url.hasSuffix(".css") && !url.hasSuffix(".woff2")
                && !url.contains("/_next/static/") && !url.contains("data:")
        }
        return Array(Set(interesting)).sorted()
    }

    // MARK: - Signing in

    /// Shows the WebView so the user can sign in — and, if a challenge appears,
    /// answer it themselves. The app never answers one on their behalf.
    /// The one real logout in the app: this session belongs to Codenotch, so
    /// Codenotch can end it.
    ///
    /// Scoped to the site's own host (and any associated hosts) rather than
    /// emptying the store — the default store is shared, so clearing all of it
    /// would sign the user out of every other web provider at the same time.
    func signOut() async {
        signInProbeTask?.cancel()
        signInProbeTask = nil
        switchGate = nil
        lastAuthFingerprint = nil
        hasSignedIn = false
        // Before the cookies go: a page still holding the old session must not
        // answer the next read, and `releasePage` leaves a page alone while a
        // sign-in window shows it — so the window goes first. Signing out from
        // Settings while the sign-in sheet is open on the same account is
        // already a contradiction; the sheet closing is what resolves it.
        signInWindow?.delegate = nil
        signInWindow?.close()
        signInWindow = nil
        releasePage()

        let hosts = Self.websiteDataHosts(for: site)
        guard !hosts.isEmpty else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { record in
            let name = record.displayName.lowercased()
            return hosts.contains { host in
                name == host || host.hasSuffix(".\(name)")
            }
        }
        await store.removeData(ofTypes: types, for: records)
    }

    func presentSignIn() {
        presentSignIn(switching: false)
    }

    func presentAccountSwitch() {
        presentSignIn(switching: true)
    }

    private func presentSignIn(switching: Bool) {
        // Both flows must see an actual unauthenticated page before accepting
        // an authenticated probe. Otherwise a stale but valid WebView session
        // makes ordinary Sign in close immediately. The switching flow keeps
        // the additional different-fingerprint requirement.
        switchGate = WebSessionAuthenticationGate(
            baselineFingerprint: lastAuthFingerprint,
            requiresNewFingerprint: switching
        )
        // Watched from here on, not only at the end: a sign-in can finish on
        // another origin — QianwenAI's SSO runs through account.qianwenai.com
        // and account.aliyun.com before it comes back to /home/ — and a window
        // closed while the SSO page was still showing used to leave the user
        // signed in with the app still asking them to sign in.
        startSignInProbePoll()
        let webView = makeWebViewIfNeeded()
        if let signInWindow {
            signInWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(displayName)"
        window.contentView = webView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        signInWindow = window
        webView.load(URLRequest(url: site.initialPath.isEmpty ? site.origin : site.origin.appendingPathComponent(site.initialPath)))
        signInSheetDidOpen()
    }

    /// What opening the sheet means for the session.
    ///
    /// A site that can confirm a sign-in — DeepSeek's probe — is not signed in
    /// until it does, so the page is watched until it reports a session. A site
    /// with no probe has nothing to wait for, and waiting anyway left it at
    /// "needs sign-in" for good: the only path that sets `hasSignedIn` runs from
    /// that probe. Those keep the optimistic sign-in they always had, and the
    /// next refresh drops back to `needsAuth` if it did not take.
    func signInSheetDidOpen() {
        guard site.authProbeScript != nil else {
            isLoaded = true
            hasSignedIn = true
            return
        }
        isLoaded = false
        // Confirmation belongs to the probe, never to the opening: the poll
        // below watches the settled page and `windowWillClose` takes one last
        // look, so a page that is still loading or restoring an existing
        // session cannot pass for a new sign-in on its own.
    }

    /// Starts the sheet's probe poll. Only a site that can confirm a session
    /// has one; every other site commits optimistically in
    /// `signInSheetDidOpen`.
    private func startSignInProbePoll() {
        signInProbeTask?.cancel()
        signInProbeTask = nil
        lastProbedURL = nil
        guard site.pollsDuringSignIn, site.authProbeScript != nil else { return }
        signInProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                if await self.probeSignInPage() { return }
            }
        }
    }

    /// One probe of the page the sheet is showing. Returns true once the gate
    /// has accepted a completed sign-in, which also closes the sheet.
    ///
    /// Only `site.origin` is probed. While the flow is on an SSO host the
    /// console is not what is loaded, the probe's own fetch would be
    /// cross-origin from that page, and its answer would say nothing about the
    /// session this provider is waiting for.
    ///
    /// One probe per *page*, not one per tick. Ticking blindly put forty
    /// requests a minute on a sheet that can sit open for minutes while its
    /// owner fetches a verification code — and for DeepSeek and MiniMax those
    /// probes are real API calls, against the very endpoints this app has been
    /// throttled by. A sign-in completes by navigating back to the site, so a
    /// URL that has changed since the last probe is the event worth a request.
    /// The first tick runs regardless, and it is also what records the
    /// logged-out sample the gate requires before a normal sign-in may commit;
    /// a site that signs in without navigating falls back to the
    /// close-to-commit path `windowWillClose` already provides.
    private func probeSignInPage() async -> Bool {
        guard let probe = site.authProbeScript, let webView else { return false }
        // Guarded first, and deliberately not remembered: a tick that found the
        // page loading, or sitting on an SSO host, probed nothing, and treating
        // it as progress would skip the probe that matters once the page comes
        // back to the console.
        guard !webView.isLoading,
              Self.matchesOrigin(webView.url, expected: site.origin)
        else { return false }
        guard webView.url != lastProbedURL else { return false }
        lastProbedURL = webView.url

        guard let result = try? await webView.callAsyncJavaScript(
                  probe, arguments: [:], in: nil, contentWorld: .page
              ),
              let state = Self.authenticationState(from: result)
        else { return false }

        // Read after the probe, not before: signing out or closing the window
        // cancels this task and clears the gate, and an answer that arrives in
        // that window must commit nothing.
        let committed = switchGate?.observe(
            authenticated: state.authenticated,
            fingerprint: state.fingerprint
        ) ?? false
        guard committed else { return false }
        lastAuthFingerprint = state.fingerprint
        authenticationDidComplete()
        return true
    }

    private struct AuthenticationState {
        let authenticated: Bool
        let fingerprint: String?
    }

    private static func authenticationState(from result: Any?) -> AuthenticationState? {
        if let authenticated = result as? Bool {
            return AuthenticationState(authenticated: authenticated, fingerprint: nil)
        }
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authenticated = object["authenticated"] as? Bool
        else { return nil }
        return AuthenticationState(authenticated: authenticated,
                                   fingerprint: object["fingerprint"] as? String)
    }

    private func authenticationDidComplete() {
        hasSignedIn = true
        switchGate = nil
        signInProbeTask?.cancel()
        signInProbeTask = nil
        signInWindow?.close()
        signInWindow = nil
        isLoaded = false
        onAuthenticated?()
    }
}

extension WebSessionProvider: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === signInWindow else { return }
        let pendingGate = switchGate
        let pendingWebView = webView
        signInWindow = nil
        signInProbeTask?.cancel()
        signInProbeTask = nil
        switchGate = nil

        // Closing before login is a cancellation. If the page is already
        // authenticated, however, the user may simply have closed it after
        // finishing the login before the polling task noticed. Confirm that
        // final state and publish it so Settings does not need to relaunch.
        guard let pendingGate,
              let probe = site.authProbeScript,
              let pendingWebView
        else {
            // Nothing left to ask of the page — closed without a sign-in to
            // confirm, or a site that cannot confirm one. The sheet was the
            // only thing keeping it; let it go rather than leave a half-filled
            // login form alive until the next poll.
            releasePage()
            return
        }
        let expectedOrigin = site.origin
        // Holds the page for exactly as long as it is asking it a question,
        // then lets it go on every outcome — a committed sign-in, a refusal,
        // a page still loading, a cancellation — so a refresh racing this
        // probe cannot take the page from under it, and the probe cannot
        // leave it alive for the next poll either.
        signInProbeTask = Task { [weak self, weak pendingWebView] in
            guard let self, let pendingWebView else { return }
            defer {
                self.signInProbeTask = nil
                self.releasePage(keeping: pendingWebView)
            }
            guard !Task.isCancelled, !pendingWebView.isLoading,
                  Self.matchesOrigin(pendingWebView.url, expected: expectedOrigin),
                  let result = try? await pendingWebView.callAsyncJavaScript(
                      probe, arguments: [:], in: nil, contentWorld: .page
                  ),
                  let state = Self.authenticationState(from: result),
                  pendingGate.acceptsAuthenticatedStateOnManualClose(
                      authenticated: state.authenticated,
                      fingerprint: state.fingerprint)
            else { return }
            guard !Task.isCancelled, self.site.origin == expectedOrigin,
                  self.webView === pendingWebView else { return }
            self.lastAuthFingerprint = state.fingerprint
            self.authenticationDidComplete()
        }
    }
}
