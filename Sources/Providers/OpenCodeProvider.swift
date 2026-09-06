import Foundation
import os

/// Reads OpenCode Go plan usage from the official endpoint, with the key
/// OpenCode itself stores on sign-in — see `OpenCodeCredentials`.
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
        .guidance("Usage rides on the opencode-go key OpenCode stores on sign-in — "
                  + "connect Go inside OpenCode (`opencode auth login`) and the notch reads it.")
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
        guard let credentials = OpenCodeCredentials.load() else {
            throw UsageProviderError.needsAuth
        }

        do {
            let data = try await fetch(token: credentials.token)
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
                headlineID: "rolling"
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

    private func fetch(token: String) async throws -> Data {
        var request = URLRequest(url: OpenCodeUsage.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        Log.usage.debug("GET opencode.ai/zen/go/v1/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("go usage endpoint answered \(status)")

        // Upstream serves a missing Go plan as 401 through the same branch as
        // a bad key (its join finds no plan row either way). Both read as
        // "nothing readable here", and the settings row says how to connect.
        if status == 401 { throw UsageProviderError.needsAuth }
        // A valid key that is not entitled to Go: readable, but metering
        // nothing — not an error, and it must not be shown as one.
        if status == 403 {
            throw UsageProviderError.nothingMetered("No OpenCode Go subscription on this key")
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
