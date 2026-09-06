import Foundation
import os

/// Reads SuperGrok's shared weekly credits the same way Grok Build does, with
/// the OIDC token already in `~/.grok/auth.json`.
///
/// The numbers are xAI's, so this is `.official`. The endpoint is not a
/// published API, so every failure degrades to a status the UI can render
/// rather than a guess. Refreshing the token is deliberately left to `grok`:
/// writing a credential this app does not own would race the CLI for it.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok

    private let session: URLSession
    private let archive: UsageArchive
    private let loadCredentials: @Sendable () -> GrokCredentials.Credential?
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    /// The plan `/v1/settings` last named. Kept here rather than re-derived:
    /// it is a fact about the account, not about this fetch.
    nonisolated(unsafe) private var lastKnownPlan: String?

    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredentials: (@Sendable () -> GrokCredentials.Credential?)? = nil) {
        self.session = session
        self.archive = archive
        self.loadCredentials = loadCredentials ?? { GrokCredentials.load() }
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Run `grok login` once — it signs in and refreshes the token this reads.")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let credentials = loadCredentials() else { return nil }
        return ProviderAccount(
            label: credentials.email,
            plan: lastKnownPlan,
            source: "Grok Build",
            manageURL: URL(string: "https://grok.com/?_s=usage")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("grok: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        guard let credentials = loadCredentials() else {
            throw UsageProviderError.needsAuth
        }
        // Expired is not signed out. `grok` rotates this whenever it runs, and
        // this app deliberately does not. After a quiet stretch the token is
        // usually stale until the CLI is next used; keep the last reading
        // rather than demand a login that is not needed.
        guard !credentials.isExpired else { throw UsageProviderError.credentialExpired }

        do {
            let data = try await fetch(url: billingURL, token: credentials.accessToken, timeout: 15)
            var payload = try GrokUsage.parse(data)
            if let settings = try? await fetch(url: settingsURL, token: credentials.accessToken, timeout: 2),
               let plan = GrokUsage.planName(from: settings) {
                payload.plan = plan
                lastKnownPlan = plan
            }

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: payload.windows,
                headlineID: "weekly"
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("grok: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetch(url: URL, token: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        Log.usage.debug("GET \(url.host ?? "", privacy: .public)\(url.path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("grok \(url.path, privacy: .public) answered \(status)")

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: GLMProvider.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: GLMProvider.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return data
    }
}
