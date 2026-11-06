import Foundation
import os

/// Reads MiniMax Token Plan / Coding Plan usage from MiniMax's own remains
/// endpoints, with a key or console cookie the user pasted in Settings.
///
/// Two products share this cell. Token Plan is the current one
/// (`/v1/token_plan/remains`); Coding Plan is the older prompt-count product
/// (`/v1/api/openplatform/coding_plan/remains`). The key is tried against
/// Token Plan first and the older path is only asked when that host is gone
/// (404/405) or the body is not remains JSON — a 401 is a dead key, not a
/// hint to try the other product.
///
/// A pay-as-you-go `sk-api-` key is not a Coding Plan token: MiniMax will
/// not meter it on these endpoints, so it is skipped and a cookie session
/// is used instead.
///
/// The numbers from a key are MiniMax's, so that path is `.official`. A
/// cookie is the same JSON the console paints, read with a session this
/// app holds rather than a published key, so that path is `.derived`. The
/// in-app WebView is the same scrape, so it stays `.derived` too — swapping
/// those would prefix a `~` on a key reading and present a browser session
/// as a published API.
actor MiniMaxProvider: UsageProvider {
    nonisolated let id = "minimax"
    nonisolated let displayName = "MiniMax"
    nonisolated let glyph = ProviderGlyph.minimax

    /// Re-read on every fetch so a region change in Settings applies without
    /// a restart. Tests pin a value; production reads `UserDefaults`.
    nonisolated private let resolveRegion: @Sendable () -> MiniMaxRegion
    private let session: URLSession
    private let archive: UsageArchive
    private let loadAPIKey: @Sendable () -> String?
    private let loadCookieHeader: @Sendable () -> String?

    /// Optional browser session, for a later composed sign-in sheet.
    /// `nonisolated(unsafe)` because `presentSignIn` is called off the actor
    /// through `any UsageProvider`; the reference is immutable after init.
    nonisolated(unsafe) private let web: WebSessionProvider?
    nonisolated private let presentsWebSignIn: Bool

    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    /// The plan the last successful answer named, for the settings row.
    /// `nonisolated(unsafe)` because `account()` reads it off the actor; the
    /// worst a race can do is show the previous plan for one row-draw.
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared,
         region: MiniMaxRegion? = nil,
         archive: UsageArchive = UsageArchive(),
         web: WebSessionProvider? = nil,
         loadAPIKey: @escaping @Sendable () -> String? = { MiniMaxCredentials.loadAPIKey() },
         loadCookieHeader: @escaping @Sendable () -> String? = { MiniMaxCredentials.loadCookieHeader() }) {
        self.session = session
        if let region {
            self.resolveRegion = { region }
        } else {
            self.resolveRegion = { Preferences.storedMinimaxRegion() }
        }
        self.archive = archive
        self.web = web
        self.presentsWebSignIn = web != nil
        self.loadAPIKey = loadAPIKey
        self.loadCookieHeader = loadCookieHeader
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        if presentsWebSignIn {
            return .modal(name: "MiniMax")
        }
        return .guidance(L10n.t("Paste a Coding Plan key in Settings, or Sign in to MiniMax."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard let base = MiniMaxCredentials.account(region: resolveRegion()) else { return nil }
        return ProviderAccount(
            label: base.label,
            plan: lastKnownPlan ?? base.plan,
            source: base.source,
            manageURL: base.manageURL
        )
    }

    nonisolated func forgetCachedCredential() {
        MiniMaxCredentials.forgetCached()
    }

    @MainActor func presentSignIn() {
        guard let web else { return }
        web.presentSignIn()
    }

    @MainActor func presentAccountSwitch() {
        guard let web else { return }
        web.presentAccountSwitch()
    }

    func signOut() async {
        MiniMaxCredentials.deleteAPIKey()
        MiniMaxCredentials.deleteCookieHeader()
        if let web {
            await web.signOut()
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("minimax: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        let region = resolveRegion()
        let apiKey = Self.codingPlanToken(from: loadAPIKey())
        let cookie = loadCookieHeader()

        do {
            let data: Data
            let fidelity: Fidelity
            if let apiKey {
                data = try await fetchOfficialRemains(token: apiKey, region: region)
                fidelity = .official
            } else if let cookie {
                data = try await fetchCookieRemains(cookie: cookie, region: region)
                fidelity = .derived
            } else if let web {
                let snapshot = try await fetchWebRemains(web)
                return recordedSuccess(
                    fidelity: .derived,
                    windows: snapshot.windows,
                    plan: snapshot.plan,
                    usageDetail: snapshot.usageDetail
                )
            } else {
                throw UsageProviderError.needsAuth
            }

            let body = String(decoding: data, as: UTF8.self)
            Log.usage.debug("minimax usage -> \(body.prefix(400), privacy: .public)")
            let parsed = try MiniMaxUsage.parse(data)
            return recordedSuccess(
                fidelity: fidelity,
                windows: parsed.windows,
                plan: parsed.plan
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("minimax: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    /// The WebView answers HTTP 429 as `badResponse`, which the store paints
    /// as an error and keeps polling. Map it onto the same backoff the key
    /// path uses so the last reading stays and the limiter is left alone.
    private func fetchWebRemains(_ web: WebSessionProvider) async throws -> ProviderSnapshot {
        do {
            return try await web.fetchSnapshot()
        } catch UsageProviderError.badResponse(let status) where status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(forAttempt: consecutiveRateLimits, retryAfter: nil)
            )
        }
    }

    /// International first, then the China API hosts once when the key is
    /// refused: a China-issued key asked of api.minimax.io answers as an
    /// auth failure, which would otherwise read as a signed-out plan that
    /// is merely pointed at the other country.
    private func fetchOfficialRemains(token: String, region: MiniMaxRegion) async throws -> Data {
        do {
            return try await fetchAPIKeyRemains(token: token, region: region)
        } catch UsageProviderError.needsAuth where region == .international {
            Log.usage.notice("minimax: international API hosts rejected the key, retrying china")
            return try await fetchAPIKeyRemains(token: token, region: .china)
        }
    }

    private func fetchAPIKeyRemains(token: String, region: MiniMaxRegion) async throws -> Data {
        var lastMissing = false
        var sawEmpty = false
        for url in Self.apiKeyRemainsURLs(for: region) {
            switch try await get(url, bearer: token, cookie: nil) {
            case .body(let data):
                if let usable = try acceptedRemains(data) { return usable }
                sawEmpty = true
                Log.usage.debug("minimax: remains unreadable, trying next remains path")
            case .missingEndpoint:
                lastMissing = true
                Log.usage.debug("minimax: remains path missing, trying next")
            }
        }
        if sawEmpty {
            throw UsageProviderError.nothingMetered(L10n.t("MiniMax reported no usage windows"))
        }
        throw UsageProviderError.badResponse(status: lastMissing ? 404 : 200)
    }

    /// API-host Token Plan first (same host a coding tool uses), then the
    /// documented www Token Plan path, then the older Coding Plan path.
    /// A 401 still aborts the list — that is a dead key, not a host hint.
    static func apiKeyRemainsURLs(for region: MiniMaxRegion) -> [URL] {
        var urls = [region.tokenPlanRemainsURL]
        if let host = region.remainsURL.host,
           let wwwToken = URL(string: "https://\(host)/v1/token_plan/remains"),
           !urls.contains(wwwToken) {
            urls.append(wwwToken)
        }
        if !urls.contains(region.codingPlanRemainsURL) {
            urls.append(region.codingPlanRemainsURL)
        }
        return urls
    }

    /// The cookie is sent as a Cookie header on this app's own `URLSession`.
    /// It is never written into Chrome, Safari, or the in-app WebView store.
    /// Not retried on the other region: a session cookie is origin-scoped.
    private func fetchCookieRemains(cookie: String, region: MiniMaxRegion) async throws -> Data {
        switch try await get(region.remainsURL, bearer: nil, cookie: cookie) {
        case .body(let data):
            return data
        case .missingEndpoint:
            throw UsageProviderError.badResponse(status: 404)
        }
    }

    /// `nil` means the body is not remains JSON, so the other product path
    /// is worth asking. Auth and throttle failures are not a parse miss.
    private func acceptedRemains(_ data: Data) throws -> Data? {
        do {
            _ = try MiniMaxUsage.parse(data)
            return data
        } catch UsageProviderError.nothingMetered {
            return nil
        } catch UsageProviderError.badResponse(let status) where status == 0 {
            return nil
        } catch {
            throw error
        }
    }

    private func recordedSuccess(fidelity: Fidelity, windows: [LimitWindow],
                                 plan: String?,
                                 usageDetail: ProviderUsageDetail? = nil) -> ProviderSnapshot {
        consecutiveRateLimits = 0
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        lastKnownPlan = plan
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: fidelity,
            status: .ok,
            windows: windows,
            headlineID: "session",
            weeklyID: "weekly",
            plan: plan?.nonEmptyPlan,
            usageDetail: usageDetail
        )
    }

    private enum RemainsAnswer {
        case body(Data)
        case missingEndpoint
    }

    private func get(_ url: URL, bearer: String?, cookie: String?) async throws -> RemainsAnswer {
        var request = URLRequest(url: url)
        // POST 404s on these paths; MiniMax's own docs call GET.
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A pasted Cookie header is the whole session. Letting URLSession
        // accept Set-Cookie would write MiniMax's jar into the process store,
        // which is how a console login leaked into the in-app WebView.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        Log.usage.debug("GET \(url.host ?? "", privacy: .public)\(url.path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("minimax remains answered \(status)")

        let envelope = Self.envelopeStatus(in: data)
        try throwIfAuthOrRateLimited(
            status: status,
            envelope: envelope,
            response: response,
            cookieAuth: cookie != nil
        )

        if Self.isMissingEndpoint(status: status, envelope: envelope, cookieAuth: cookie != nil) {
            return .missingEndpoint
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return .body(data)
    }

    /// Rate limit first: MiniMax has answered 429 with a 1004-shaped body,
    /// and `needsAuth` is what drops the last reading. A throttle must back
    /// off and keep the snapshot.
    private func throwIfAuthOrRateLimited(status: Int, envelope: Int?,
                                          response: URLResponse,
                                          cookieAuth: Bool) throws {
        if Self.isRateLimited(status: status, envelope: envelope) {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        if Self.isDeadCredential(status: status, envelope: envelope, cookieAuth: cookieAuth) {
            throw UsageProviderError.needsAuth
        }
    }

    /// HTTP/envelope 429, plus 2045 ("overloaded") which MiniMax rides under
    /// HTTP 200 the same way 1004 does.
    static func isRateLimited(status: Int, envelope: Int?) -> Bool {
        status == 429 || envelope == 429 || envelope == 2045
    }

    /// Cookie 1004 is a missing login. Bearer 1004 is this host wanting a
    /// cookie — try the next remains path, do not kill the key.
    static func isDeadCredential(status: Int, envelope: Int?, cookieAuth: Bool) -> Bool {
        if status == 401 || status == 403 || envelope == 401 || envelope == 403 {
            return true
        }
        if cookieAuth, status == 1004 || envelope == 1004 {
            return true
        }
        return false
    }

    static func isMissingEndpoint(status: Int, envelope: Int?, cookieAuth: Bool) -> Bool {
        if status == 404 || status == 405 { return true }
        if !cookieAuth, status == 1004 || envelope == 1004 { return true }
        return false
    }

    /// Pay-as-you-go `sk-api-` keys cannot query coding-plan remains.
    /// `sk-cp-` and any unrecognised prefix still can.
    static func codingPlanToken(from apiKey: String?) -> String? {
        guard var raw = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.lowercased().hasPrefix("bearer ") {
            raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("sk-api-") { return nil }
        return raw
    }

    private static func envelopeStatus(in data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = int(root["status_code"]) ?? int(root["code"]) { return code }
        let resp = (root["base_resp"] as? [String: Any])
            ?? ((root["data"] as? [String: Any])?["base_resp"] as? [String: Any])
        if let resp {
            return int(resp["status_code"]) ?? int(resp["code"])
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own. The server's own hint
    /// is honoured only as a floor-raiser.
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
