import Foundation

/// One Codex account on another machine: its session borrowed over SSH, its
/// limits read from the same backend as the local logins.
///
/// The remote Codex rotates its own token when it runs; here the file is
/// re-read whenever the held copy expires or the endpoint rejects it. No
/// activity monitoring: a ring for what the account has spent, not for what
/// it is doing.
actor CodexRemoteProvider: UsageProvider {
    nonisolated let host: RemoteHost
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai

    private let session: URLSession
    /// Held between refreshes so one SSH read serves a whole token lifetime,
    /// not one poll — a handshake per minute per server would be rude.
    private var credential: CodexCredentials.Credential?
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network.
    private var retryNoEarlierThan: Date?

    private let archive: UsageArchive
    /// How this host's session is obtained. Injected for the same reason the
    /// local provider's file is: a test that actually sshed anywhere would
    /// need a server and a login to be deterministic.
    private let loadCredential: @Sendable () throws -> CodexCredentials.Credential

    init(host: RemoteHost,
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredential: (@Sendable () throws -> CodexCredentials.Credential)? = nil) {
        self.host = host
        self.id = host.providerID
        self.displayName = host.displayName
        self.session = session
        self.archive = archive
        self.loadCredential = loadCredential ?? { try CodexRemoteCredentials.load(from: host) }
        // Recreating the provider or relaunching must not bypass the server's retry deadline.
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: host.providerID)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        if let retryNoEarlierThan, retryNoEarlierThan > now {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now))
        }
        do {
            let snapshot = try await fetch(retryingOnUnauthorized: true)
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)
            return snapshot
        } catch let error as UsageProviderError {
            if case .rateLimited(let retryAfter) = error {
                retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
                archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            }
            throw error
        }
    }

    private func fetch(retryingOnUnauthorized: Bool) async throws -> ProviderSnapshot {
        let credential = try currentCredential()

        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            // Rejected: the held copy is wrong — the server rotated it. The
            // local provider reads its file fresh on every fetch and gives up
            // here; here one re-read may already find the new session.
            self.credential = nil
            if retryingOnUnauthorized {
                return try await fetch(retryingOnUnauthorized: false)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            let receivedAt = Date()
            let delay = max(60, CodexLocalProvider.retryAfter(from: http, now: receivedAt) ?? 0)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        async let resetCredits = CodexLocalProvider.fetchResetCredits(session: session, credential: credential)

        let windows = try CodexUsage.windows(
            from: data,
            includeExtras: Preferences.storedShowCodexExtraLimits()
        )
        let profileUsage = try? await CodexLocalProvider.fetchProfileUsage(
            session: session, credential: credential
        )
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: "primary",
            // The weekly ring is the account weekly, never Spark's own weekly.
            weeklyID: "secondary",
            tokenUsage: profileUsage,
            plan: CodexUsage.plan(from: data) ?? account()?.plan?.nonEmptyPlan,
            resetCredits: await resetCredits
        )
    }

    private func currentCredential(now: Date = Date()) throws -> CodexCredentials.Credential {
        // The local provider re-reads its file on every fetch, so expiry is
        // judged for free; the held copy here must be re-judged instead. The
        // rule is the loader's own: a token with no `exp` claim is trusted
        // and left for the server to validate.
        if let credential, !Self.isExpired(credential, now: now) { return credential }
        let fresh = try loadCredential()
        Log.usage.debug("\(self.id, privacy: .public): read remote codex session")
        credential = fresh
        return fresh
    }

    private static func isExpired(_ credential: CodexCredentials.Credential, now: Date) -> Bool {
        guard let expiry = CodexCredentials.claims(inJWT: credential.accessToken)?["exp"] as? Double
        else { return false }
        return expiry <= now.timeIntervalSince1970
    }

    nonisolated func forgetCachedCredential() {
        // Nothing to drop that matters: the held session is re-read from the
        // server whenever it expires or the endpoint rejects it. Reached only
        // from "Allow access…", which this provider never shows — there is no
        // local keychain item to re-ask macOS for.
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(
            label: nil,   // the session carries an address, but reading it takes SSH
            plan: nil,
            source: "Codex on \(host.host)",
            manageURL: URL(string: "https://chatgpt.com/#settings/Account")
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Sign in to Codex on \(host.destination) — ssh there and run `codex`. SSH key auth must already work; this never asks for a password."))
    }

    /// Explicitly added, so always shown: a row that vanishes on a network
    /// blip would read as the account being forgotten.
    nonisolated var isVisibleWhenAbsent: Bool { true }
}
