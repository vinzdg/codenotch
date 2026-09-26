import Foundation

/// One Claude account on another machine: its token borrowed over SSH, its
/// limits read from the same endpoint as the local logins.
///
/// No Desktop cache and no CLI over there — just the token path both fall
/// through to. When the borrowed copy has rotted, the server's own Claude
/// Code is run once to renew it: the same start-up renewal the local token
/// renewal relies on, judged the same way — unless the re-read expiry moved,
/// the ring keeps its last reading. This app never mints a token itself and
/// never writes the remote file; only Claude Code touches its own credential.
/// No activity monitoring: a ring for what the account has spent, not for
/// what it is doing.
actor ClaudeRemoteProvider: UsageProvider {
    nonisolated let host: RemoteHost
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude

    /// The same bearer-token endpoint the local provider reads.
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    private let session: URLSession
    /// Held between refreshes so one SSH read serves a whole token lifetime,
    /// not one poll — a handshake per minute per server would be rude.
    private var credentials: ClaudeCredentials?
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — a poll that keeps firing into
    /// a rate limit is how you stay rate limited.
    private var retryNoEarlierThan: Date?
    /// How many 429s in a row. The endpoint answers `Retry-After: 0`, which
    /// is no guidance at all, so the wait doubles each time instead.
    private var consecutiveRateLimits = 0

    private let archive: UsageArchive
    /// How this host's token is obtained. Injected for the same reason the
    /// local provider's is: a test that actually sshed anywhere would need a
    /// server and a login to be deterministic.
    private let loadCredentials: @Sendable () throws -> ClaudeCredentials
    /// The renewal run itself, separate from the file reads: it needs its own
    /// watchdog, and the tests count it apart from them.
    private let runRenewal: @Sendable () throws -> RemoteSSH.CommandResult
    /// The expiry a renewal was already spent on. One attempt per token, which
    /// is what makes a failure stop instead of respawning a remote process on
    /// every poll: a token that did not renew has the same expiry next tick,
    /// and is refused. The local renewal's `attemptedFor`, over a wire.
    private var renewalAttemptedFor: Date?

    init(host: RemoteHost,
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredentials: (@Sendable () throws -> ClaudeCredentials)? = nil,
         runRenewal: (@Sendable () throws -> RemoteSSH.CommandResult)? = nil) {
        self.host = host
        self.id = host.providerID
        self.displayName = host.displayName
        self.session = session
        self.archive = archive
        self.loadCredentials = loadCredentials ?? { try ClaudeRemoteCredentials.load(from: host) }
        self.runRenewal = runRenewal ?? {
            try RemoteSSH.run(host: host,
                              command: ClaudeRemoteCredentials.renewalCommand(),
                              timeout: ClaudeRemoteCredentials.renewalTimeout)
        }
        // Pick the back-off back up where the last run left it, so relaunching
        // during a penalty does not spend an attempt extending it.
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: host.providerID)
    }

    /// The one minute of slack the local provider keeps, for the same
    /// resonance: the server's hint and the store's tick run at the same
    /// period, and the tick lands just before the window opens.
    private let backoffSlack: TimeInterval = 1

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if ClaudeOAuthProvider.shouldHoldOff(until: retryNoEarlierThan, slack: backoffSlack),
           let retryNoEarlierThan {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }
        do {
            let snapshot = try await fetch(retryingOnUnauthorized: true)
            retryNoEarlierThan = nil
            consecutiveRateLimits = 0
            archive.saveBackoffUntil(nil, providerID: id)
            return snapshot
        } catch let error as UsageProviderError {
            if case .rateLimited(let retryAfter) = error {
                consecutiveRateLimits += 1
                retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
                archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
                Log.usage.notice("rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            }
            throw error
        }
    }

    private func fetch(retryingOnUnauthorized: Bool) async throws -> ProviderSnapshot {
        let token = try currentToken()

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        Log.usage.debug("GET /api/oauth/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("usage endpoint answered \(status)")

        if status == 401 || status == 403 {
            // Rejected: the held copy is wrong — the server rotated or the
            // account changed under it. Re-read once in case a fresh token
            // is already waiting over there.
            credentials = nil
            if retryingOnUnauthorized {
                return try await fetch(retryingOnUnauthorized: false)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: ClaudeOAuthProvider.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: ClaudeOAuthProvider.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let payload = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
        let windows = payload.limitWindows()
        // Answered, and signed in, but no limit in it: some Enterprise and
        // team accounts come back this way. Say what happened.
        guard !windows.isEmpty else {
            Log.usage.notice("claude usage endpoint answered with no limit windows")
            throw UsageProviderError.nothingMetered(
                L10n.t("Claude answered, but listed no usage limits for this account. Some Enterprise and team plans don't report them.")
            )
        }
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "session",
            weeklyID: "weekly_all",
            plan: credentials?.subscriptionType?.nonEmptyPlan,
            resetCredits: payload.cedarEmber?.credits(at: Date())
        )
    }

    private func currentToken() throws -> String {
        if let credentials, !credentials.isExpired {
            return credentials.accessToken
        }
        var fresh = try loadCredentials()
        Log.usage.debug("\(self.id, privacy: .public): read remote token, expires \(fresh.expiresAt, privacy: .public)")
        // Expired is not signed out. The far side rotates this token whenever
        // Claude Code runs there — and when it has not run in a while, this
        // runs it once remotely rather than waiting for the user to. What
        // comes back is still judged, never trusted.
        if fresh.isExpired {
            fresh = try renew(fresh)
        }
        credentials = fresh
        return fresh.accessToken
    }

    /// Renews a rotted token through the server's own Claude Code, then
    /// re-reads. Judged on the outcome, never on the run: refusing an empty
    /// prompt is a *non-zero* exit and a successful renewal at the same time.
    private func renew(_ stale: ClaudeCredentials) throws -> ClaudeCredentials {
        guard stale.expiresAt != renewalAttemptedFor else {
            throw UsageProviderError.credentialExpired
        }
        renewalAttemptedFor = stale.expiresAt
        do {
            let result = try runRenewal()
            if RemoteSSH.isTransportFailure(result) {
                throw RemoteSSH.transportError(destination: host.destination, result: result)
            }
            if String(data: result.stdout, encoding: .utf8)?
                .contains(ClaudeRemoteCredentials.noCLISentinel) == true {
                Log.usage.error("ssh \(self.host.destination, privacy: .public): no claude command found to renew with")
            }
        } catch is RemoteSSH.TimeoutError {
            throw UsageProviderError.apiError(L10n.t("ssh to \(host.destination) timed out"))
        }
        let reread = try loadCredentials()
        guard reread.expiresAt > stale.expiresAt else {
            Log.usage.error("ssh \(self.host.destination, privacy: .public): renewal ran but the token expiry did not move")
            throw UsageProviderError.credentialExpired
        }
        Log.usage.notice("ssh \(self.host.destination, privacy: .public): remote token renewed, now expires \(reread.expiresAt, privacy: .public)")
        return reread
    }

    nonisolated func forgetCachedCredential() {
        // Nothing to drop that matters: the held token is re-read from the
        // server whenever it expires or the endpoint rejects it. Reached only
        // from "Allow access…", which this provider never shows — there is no
        // local keychain item to re-ask macOS for.
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(
            label: nil,   // the token carries no address, and the name is the user's own
            plan: nil,
            source: "Claude Code on \(host.host)",
            manageURL: URL(string: "https://claude.ai/settings/usage")
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Sign in to Claude Code on \(host.destination) — ssh there and run `claude`. SSH key auth must already work; this never asks for a password."))
    }

    /// Explicitly added, so always shown: a row that vanishes on a network
    /// blip would read as the account being forgotten.
    nonisolated var isVisibleWhenAbsent: Bool { true }
}
