import Foundation
import os

/// Reads Mistral AI / Mistral Vibe monthly budget usage from
/// `GET https://api.mistral.ai/v1/billing/budget` (with optional plan metadata
/// from `/v1/billing/subscription`).
actor MistralProvider: UsageProvider {
    nonisolated let id = "mistral"
    nonisolated let displayName = "Mistral"
    nonisolated let glyph = ProviderGlyph.mistral

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let sources: MistralCredentialSources
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         sources: MistralCredentialSources = MistralCredentialSources(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.sources = sources
        self.now = now
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: "mistral")
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Export MISTRAL_API_KEY, configure Mistral Vibe (~/.vibe/.env), or paste a Mistral API key below."))
    }

    nonisolated func account() -> ProviderAccount? {
        MistralCredentials.account(sources, plan: lastKnownPlan)
    }

    nonisolated func signOut() async {
        sources.deleteSettingsToken()
    }

    nonisolated func forgetCachedCredential() {
        sources.forgetCached()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > now() {
            let remaining = retryNoEarlierThan.timeIntervalSince(now())
            Log.usage.debug("mistral: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        let credential = try MistralCredentials.load(sources)

        do {
            let budgetData = try await fetchJSON(from: MistralUsage.budgetEndpoint, token: credential.token)
            let windows = try MistralUsage.parseBudgets(budgetData)

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)

            if windows.isEmpty {
                throw UsageProviderError.nothingMetered(
                    L10n.t("Mistral reported no active budget on this account.")
                )
            }

            if let subData = try? await fetchJSON(from: MistralUsage.subscriptionEndpoint, token: credential.token),
               let plan = MistralUsage.parseSubscriptionPlan(subData) {
                lastKnownPlan = plan
            }

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: windows,
                headlineID: windows.first?.id,
                plan: lastKnownPlan
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            consecutiveRateLimits += 1
            retryNoEarlierThan = now().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("mistral: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetchJSON(from url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            throw UsageProviderError.apiError(L10n.t("Couldn't reach Mistral. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            sources.forgetCached()
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: http, now: now())
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return data
    }

    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    static func retryAfter(from response: HTTPURLResponse?, now: Date) -> TimeInterval? {
        guard let header = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces),
              !header.isEmpty
        else { return nil }

        if let seconds = TimeInterval(header), seconds.isFinite {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
