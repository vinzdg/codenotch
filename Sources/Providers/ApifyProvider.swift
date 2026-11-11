import Foundation

/// This cycle's platform spend against the account's monthly usage limit —
/// the bar on the Console's Billing page — read from the endpoint that page
/// draws it from. See `ApifyUsage` for the shape and `ApifyCredentials` for
/// where the token comes from.
///
/// The numbers are Apify's own, so this is `.official`. The endpoint
/// throttles, so a 429 backs off on a schedule that outlives the process
/// rather than polling into the limit, and every failure degrades to a status
/// the UI can render honestly.
actor ApifyProvider: UsageProvider {
    nonisolated let id = "apify"
    nonisolated let displayName = "Apify"
    nonisolated let glyph = ProviderGlyph.apify

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let sources: ApifyCredentialSources
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?

    init(session: URLSession = .shared, archive: UsageArchive = UsageArchive(),
         sources: ApifyCredentialSources = ApifyCredentialSources(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.sources = sources
        self.now = now
        // Pick the back-off up where the last run left it, so relaunching
        // during a penalty does not spend an attempt extending it.
        retryNoEarlierThan = archive.loadBackoffUntil(providerID: "apify")
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Run apify login in Terminal — the notch reads that login — or paste an Apify API token below."))
    }

    nonisolated func account() -> ProviderAccount? { ApifyCredentials.account(sources) }

    /// Only the token Codenotch holds itself. An `apify login` is the CLI's
    /// to end, the same bargain every borrowed credential makes.
    nonisolated func signOut() async { sources.deleteSettingsToken() }

    nonisolated func forgetCachedCredential() { sources.forgetCached() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > now() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now()))
        }
        // Resolved on every fetch: the file and the environment are free to
        // re-read and follow a new login at once, and the two keychain reads
        // behind this are cached until their items move.
        let credential = try ApifyCredentials.load(sources)

        var request = URLRequest(url: ApifyUsage.endpoint)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach Apify. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 {
            // The one signal that the copy in hand is wrong despite its item
            // not having moved — which is what a re-login to another account
            // looks like from here. Dropped so the next read asks again.
            sources.forgetCached()
            throw UsageProviderError.needsAuth
        }
        if status == 403 {
            // A scoped token can be valid and still be refused this endpoint.
            // That is not "signed out", and sending someone to log in again
            // would not fix it.
            throw UsageProviderError.apiError(
                L10n.t("This Apify token cannot read account limits — use one with full account access")
            )
        }
        if status == 429 {
            let delay = Self.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"), now: now())
            retryNoEarlierThan = now().addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }

        let windows = try ApifyUsage.windows(from: data)
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: ApifyUsage.headlineID,
                                plan: account()?.plan)
    }

    /// A minute at least, whatever the header says: the endpoint's own hint
    /// can be `0`, and a poll that keeps firing into a rate limit is how you
    /// stay rate limited.
    private static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 60 }
        if let seconds = Double(header), seconds.isFinite { return max(60, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(60, formatter.date(from: header)?.timeIntervalSince(now) ?? 0)
    }
}
