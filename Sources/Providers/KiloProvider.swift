import Foundation
import os

/// Reads Kilo's coding-plan quota windows and credit balance from Kilo
/// Cloud's own endpoints, with the token the Kilo CLI stores on sign-in —
/// see `KiloCredentials`.
///
/// The numbers are Kilo's, so this is `.official`. Like Claude's, GLM's and
/// OpenCode's, the endpoints throttle — so a 429 backs off on a schedule that
/// outlives the process rather than polling into the limit, and every failure
/// degrades to a status the UI can render honestly.
///
/// A coding plan draws its windows; a pay-as-you-go account has no windows and
/// shows the credit balance as a count-up row instead. An API key from the
/// Kilo Gateway reads the balance only — the coding-plan procedures belong to
/// an OAuth login.
actor KiloProvider: UsageProvider {
    nonisolated let id = "kilo"
    nonisolated let displayName = "Kilo"
    nonisolated let glyph = ProviderGlyph.kilo

    private let session: URLSession
    private let archive: UsageArchive
    private let authURL: URL
    private let baseURL: URL
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — the same bargain Claude's and
    /// GLM's make.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0
    /// The plan the last successful answer named, for the settings row.
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared, archive: UsageArchive = UsageArchive(),
         authURL: URL = KiloCredentials.authURL, baseURL: URL = URL(string: "https://api.kilo.ai")!) {
        self.session = session
        self.archive = archive
        self.authURL = authURL
        self.baseURL = baseURL
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Usage rides on the account Kilo CLI signs into — run `kilo` once and sign in, and the notch reads it."))
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the token is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard let credentials = KiloCredentials.load(from: authURL) else { return nil }
        return ProviderAccount(
            label: nil,   // the token carries no address
            plan: lastKnownPlan,
            source: "Kilo",
            manageURL: URL(string: "https://app.kilo.ai")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("kilo: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        // Re-read on every fetch. This is an ordinary file, not a keychain
        // item: reading it puts no prompt in front of anyone, and the CLI
        // refreshes the access token in place.
        guard let credentials = KiloCredentials.load(from: authURL) else {
            throw UsageProviderError.needsAuth
        }

        do {
            var windows: [LimitWindow] = []
            var planName: String?

            // Coding plans meter in windows. An API key is refused here by the
            // server the same way a missing plan is — both mean "no plan to
            // read", and the balance below is what such an account shows.
            do {
                let subscriptionsJSON = try await fetch(
                    token: credentials.token,
                    organizationID: credentials.organizationID,
                    procedure: KiloUsage.subscriptionsProcedure,
                    input: nil
                )
                let plans = try KiloUsage.subscriptions(fromJSON: subscriptionsJSON).filter(\.meters)
                for plan in plans {
                    let input: [String: Any] = ["subscriptionId": plan.id]
                    guard let body = try? JSONSerialization.data(withJSONObject: input),
                          let inputJSON = String(data: body, encoding: .utf8),
                          let usageJSON = try await fetch(
                            token: credentials.token,
                            organizationID: credentials.organizationID,
                            procedure: KiloUsage.usageProcedure,
                            input: inputJSON
                          ) as String? else { continue }
                    let planWindows = try KiloUsage.windows(fromJSON: usageJSON)
                    // Several plans would multiply the ring's subject; the
                    // first active one is the account, the rest stay unshown.
                    if planName == nil {
                        planName = plan.planName
                        windows = planWindows
                    }
                }
            } catch UsageProviderError.needsAuth {
                // An API key: the coding-plan procedure refuses it the same
                // way it refuses a plan-less account, and neither is a
                // sign-out — the balance below is what such an account reads.
            }

            let balanceJSON = try await fetch(
                token: credentials.token,
                organizationID: credentials.organizationID,
                path: KiloUsage.balancePath
            )
            if let balance = KiloUsage.balanceWindow(fromJSON: balanceJSON) {
                windows.append(balance)
            }

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)
            lastKnownPlan = planName

            guard !windows.isEmpty else {
                // Signed in, and nothing metered: an honest empty, not an
                // error — the same shape Cursor's free plan reports.
                throw UsageProviderError.nothingMetered(
                    L10n.t("This Kilo account has no usage to read yet — top up credits or subscribe to a coding plan.")
                )
            }

            let headlineID = planName == nil ? "balance" : KiloUsage.headlineID(in: windows)
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: windows,
                headlineID: headlineID,
                weeklyID: windows.first { $0.id != headlineID && $0.usedFraction != nil }?.id,
                plan: planName
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            // Bookkeeping where the answer was, not down in `fetch`: the wait
            // has to outlive the request that earned it.
            let attempt = consecutiveRateLimits
            consecutiveRateLimits += 1
            let wait = Self.backoff(forAttempt: attempt, retryAfter: retryAfter)
            retryNoEarlierThan = Date().addingTimeInterval(wait)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("kilo: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    /// One tRPC GET. The procedure and its input ride in the query string;
    /// the token authenticates as the CLI's does.
    private func fetch(token: String, organizationID: String?, procedure: String, input: String?) async throws -> String {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/trpc/\(procedure)"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let input {
            items.append(URLQueryItem(name: "input", value: input))
        }
        if !items.isEmpty { components.queryItems = items }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "x-kilocode-organizationid")
        }
        request.timeoutInterval = 15

        Log.usage.debug("GET \(components.url?.host ?? "", privacy: .public)/api/trpc/\(procedure, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        return try Self.read(data, from: response)
    }

    /// The REST balance endpoint, whose answer is plain JSON.
    private func fetch(token: String, organizationID: String?, path: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "x-kilocode-organizationid")
        }
        request.timeoutInterval = 15

        Log.usage.debug("GET \(self.baseURL.host ?? "", privacy: .public)/\(path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        return try Self.read(data, from: response)
    }

    private static func read(_ data: Data, from response: URLResponse) throws -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            // A minute floor here; `backoff(forAttempt:retryAfter:)` raises
            // it per consecutive limit when the caller books the wait. The
            // server's `Retry-After`, when present, is honoured as a
            // floor-raiser, for the reason Claude's records.
            throw UsageProviderError.rateLimited(
                retryAfter: backoff(
                    forAttempt: 0,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return text
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

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }
}
