import Foundation
import os

/// Reads OpenCode Go plan usage from the official endpoint, with the
/// credential OpenCode itself stores on sign-in — see `OpenCodeCredentials`.
///
/// Which credential that is decides the endpoint, because each route refuses
/// the other's: the Go API key is for `zen/go`, while an OAuth sign-in is only
/// accepted by the `inference/` route OpenCode itself uses. Both answer 401 to
/// the wrong one, and that 401 is also what a valid account with no Go plan
/// returns — so an OAuth 401 is checked against the console before it is called
/// a sign-out.
///
/// The numbers are OpenCode's, so this is `.official`. Like Claude's and
/// GLM's, the endpoint throttles — so a 429 backs off on a schedule that
/// outlives the process rather than polling into the limit, and every failure
/// degrades to a status the UI can render honestly.
///
/// Two upstream quirks worth knowing, both commented where they bite: a valid
/// key with no Go plan answers 401, the same as a bad key; and Zen
/// pay-as-you-go credit balance has no API at all, so this covers the Go
/// windows only.
actor OpenCodeProvider: UsageProvider {
    nonisolated let id = "opencode"
    nonisolated let displayName = "OpenCode"
    nonisolated let glyph = ProviderGlyph.opencode

    private let session: URLSession
    private let archive: UsageArchive
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — the same bargain Claude's and
    /// GLM's make.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    init(session: URLSession = .shared, archive: UsageArchive = UsageArchive()) {
        self.session = session
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        .command("opencode auth login", name: "OpenCode", install: URL(string: "https://opencode.ai"))
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the key is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard OpenCodeCredentials.load() != nil else { return nil }
        return ProviderAccount(
            label: nil,   // the key carries no address
            plan: "Go",
            source: "OpenCode",
            manageURL: URL(string: "https://opencode.ai")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("opencode: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        // Re-read on every fetch. This is an ordinary file, not a keychain
        // item: reading it puts no prompt in front of anyone.
        guard let credential = OpenCodeCredentials.load() else {
            throw UsageProviderError.needsAuth
        }

        do {
            let data = try await fetch(credential)
            guard let text = String(data: data, encoding: .utf8) else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let read = try OpenCodeUsage.windows(fromJSON: text)

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: read,
                headlineID: "rolling",
                weeklyID: "weekly",
                plan: "Go"
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            // Bookkeeping where the answer was, not down in `fetch`: the wait
            // has to outlive the request that earned it.
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("opencode: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    /// The route this credential is for. Not a preference: each refuses the
    /// other's credential, and refuses it with the same 401 a planless account
    /// gets — so the wrong pairing is invisible from the response alone.
    static func endpoint(for credential: OpenCodeCredentials.Credential) -> URL {
        credential.oauth ? OpenCodeUsage.oauthEndpoint : OpenCodeUsage.endpoint
    }

    private func fetch(_ credential: OpenCodeCredentials.Credential) async throws -> Data {
        let url = Self.endpoint(for: credential)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only an OAuth sign-in is issued against an org, and only the
        // `inference/` routes want it.
        if let org = credential.org {
            request.setValue(org, forHTTPHeaderField: "x-opencode-org-id")
        }
        request.timeoutInterval = 15

        Log.usage.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("go usage endpoint answered \(status)")

        if status == 401 {
            // Upstream serves a missing Go plan as 401 through the same branch as
            // a bad credential — its join finds no plan row either way. Only the
            // console can tell the two apart, and only for an OAuth sign-in: the
            // Go key has no equivalent probe, so its 401 stays a sign-out, as
            // before.
            if credential.oauth, await signedIn(credential) {
                throw UsageProviderError.nothingMetered(
                    L10n.t("No OpenCode Go subscription on this account"))
            }
            // The token's own expiry is only a hint, but it is the difference
            // between "sign in again" and "open OpenCode, it will renew this" —
            // and the last reading is still true in the second case.
            if let expires = credential.expires, expires <= Date() {
                throw UsageProviderError.credentialExpired
            }
            throw UsageProviderError.needsAuth
        }
        // A valid key that is not entitled to Go: readable, but metering
        // nothing — not an error, and it must not be shown as one.
        if status == 403 {
            throw UsageProviderError.nothingMetered(L10n.t("No OpenCode Go subscription on this key"))
        }
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

    /// Is this OAuth sign-in still good? Asked only after the usage endpoint's
    /// 401, which cannot tell a bad token from an account without a Go plan.
    ///
    /// The console's `/api/user` answers 401 only to a bad token, so a 200 here
    /// means the sign-in is fine and the account simply has no Go plan. The Zen
    /// model list cannot be used for this: it answers 200 to anything, including
    /// a made-up token.
    private func signedIn(_ credential: OpenCodeCredentials.Credential) async -> Bool {
        let console = credential.console ?? OpenCodeUsage.defaultConsole
        guard var components = URLComponents(
            url: console.appendingPathComponent("api/user"), resolvingAgainstBaseURL: false)
        else { return false }
        components.query = nil
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let org = credential.org {
            request.setValue(org, forHTTPHeaderField: "x-opencode-org-id")
        }
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            // A probe that cannot be made is not a verdict. Claiming "signed
            // out" here would replace a planless account with a sign-in prompt,
            // which is the worse of the two mistakes.
            Log.usage.debug("opencode: console sign-in probe failed, treating 401 as a sign-out")
            return false
        }
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
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
