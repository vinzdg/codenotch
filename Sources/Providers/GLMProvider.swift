import Foundation
import os

/// Reads GLM Coding Plan usage from Z.ai's own monitor endpoint, with the key
/// one of the coding tools already holds — see `GLMCredentials` for whose.
///
/// The numbers are Z.ai's, so this is `.official`. The endpoint is not a
/// published API, though, and it is known to throttle — so like Claude's, every
/// failure degrades to a status the UI can render honestly, and a 429 backs off
/// on a schedule that outlives the process rather than polling into the limit.
actor GLMProvider: UsageProvider {
    nonisolated let id = "glm"
    nonisolated let displayName = "GLM"
    nonisolated let glyph = ProviderGlyph.glm

    private let session: URLSession
    private let archive: UsageArchive
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — the same bargain Claude's makes.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    /// The plan level the last successful answer named, for the settings row.
    /// Kept here rather than re-derived: it is a fact about the account, not
    /// about this fetch. `nonisolated(unsafe)` because `account()` reads it
    /// off the actor; the worst a race can do is show the previous level for
    /// one row-draw.
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared, archive: UsageArchive = UsageArchive()) {
        self.session = session
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Usage rides on a Z.ai GLM Coding Plan key held by a coding tool — Claude Code's settings.json, ZCode or OpenCode. Set one up there and the notch reads it."))
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the key is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard let credentials = GLMCredentials.load() else { return nil }
        return ProviderAccount(
            label: nil,   // none of the borrowed keys carries an address
            plan: lastKnownPlan,
            source: credentials.source,
            manageURL: credentials.baseURL.host == "open.bigmodel.cn"
                ? URL(string: "https://open.bigmodel.cn/usage")
                : URL(string: "https://z.ai/manage-apikey/apikey-list")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("glm: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        // Re-read on every fetch. These are ordinary files, not keychain items:
        // reading them puts no prompt in front of anyone, which is why this
        // provider needs none of Claude's credential caching.
        guard let credentials = GLMCredentials.load() else {
            if GLMCredentials.zcodeHasStartPlan() || GLMCredentials.zcodeSettingsHasStartPlanOnly() {
                throw UsageProviderError.nothingMetered(
                    L10n.t("Z.ai does not publish usage for the GLM Start Plan yet, so there is nothing to read. The Coding Plan is supported.")
                )
            }
            throw UsageProviderError.needsAuth
        }

        do {
            let data = try await fetch(credentials: credentials)
            let payload = try GLMUsage.parse(data)

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)
            lastKnownPlan = payload.level

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: payload.windows,
                headlineID: "session",
                weeklyID: "weekly",
                plan: payload.level?.nonEmptyPlan
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            // Bookkeeping where the answer was, not down in `fetch`: the wait
            // has to outlive the request that earned it.
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("glm: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetch(credentials: GLMCredentials.Credential) async throws -> Data {
        let url = credentials.baseURL.appendingPathComponent("api/monitor/usage/quota/limit")
        var request = URLRequest(url: url)
        // The monitor takes the key raw — no "Bearer" scheme. Prefixing it is
        // exactly what an auth failure looks like from here.
        request.setValue(credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        Log.usage.debug("GET \(url.host ?? "", privacy: .public)/api/monitor/usage/quota/limit")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("quota endpoint answered \(status)")

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return data
    }

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own. The server's own hint
    /// is honoured only as a floor-raiser, for the reason Claude's records.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
