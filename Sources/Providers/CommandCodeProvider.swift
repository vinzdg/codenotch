import Foundation
import os

/// Reads Command Code GOAT usage from the same `/alpha` endpoints the
/// desktop app uses, with the key in `~/.commandcode/auth.json`.
///
/// The numbers are Command Code's, so this is `.official`. The older
/// `/internal` cookie path is gone; a Chrome session is not a credential.
actor CommandCodeProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.commandcode
    nonisolated let profile: CommandCodeProfile

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let authURL: URL
    nonisolated private let environment: [String: String]
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0
    nonisolated(unsafe) private var lastKnownPlan: String?
    nonisolated(unsafe) private var lastKnownUser: String?

    init(profile: CommandCodeProfile = .default(),
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         authURL: URL? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.archive = archive
        self.authURL = authURL ?? profile.authURL
        // `COMMAND_CODE_API_KEY` names one account. Only the default profile
        // may take it, or every profile would show that same account.
        self.environment = profile.slug == nil ? environment : [:]
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
    }

    nonisolated var signInRoute: SignInRoute {
        guard profile.slug != nil else { return defaultSignInRoute }
        return .command(profile.signInCommand, name: displayName,
                        install: URL(string: "https://commandcode.ai"))
    }

    nonisolated private var defaultSignInRoute: SignInRoute {
        .guidance(L10n.t("Sign in with the Command Code app — it writes ~/.commandcode/auth.json and the notch reads it."))
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the key is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard let base = CommandCodeCredentials.account(from: authURL, environment: environment, source: profile.sourceName) else { return nil }
        return ProviderAccount(
            label: lastKnownUser ?? base.label,
            plan: lastKnownPlan ?? base.plan,
            source: base.source,
            manageURL: base.manageURL
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("commandcode: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        guard let credentials = try? CommandCodeCredentials.load(from: authURL, environment: environment) else {
            throw UsageProviderError.needsAuth
        }

        do {
            lastKnownUser = credentials.userName
            let whoami = try await body(from: CommandCodeUsage.whoami, token: credentials.apiKey)
            let orgId = CommandCodeUsage.orgId(whoamiJSON: whoami)

            let creditsURL = CommandCodeUsage.credits.withQuery(["orgId": orgId])
            let subsURL = CommandCodeUsage.subscriptions.withQuery(["orgId": orgId])
            async let creditsTask = body(from: creditsURL, token: credentials.apiKey)
            async let subsTask = body(from: subsURL, token: credentials.apiKey)
            let credits = try await creditsTask
            let subscription = try await subsTask

            let subObject = (try? JSONSerialization.jsonObject(with: Data(subscription.utf8))) as? [String: Any]
            let subData = (subObject?["data"] as? [String: Any]) ?? subObject ?? [:]
            lastKnownPlan = CommandCodeUsage.planName(subData["planId"] as? String)

            var summaryQuery: [String: String?] = ["orgId": orgId]
            if let start = CommandCodeUsage.date(subData["currentPeriodStart"]) {
                let stamp = ISO8601DateFormatter()
                stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                summaryQuery["since"] = stamp.string(from: start)
            }
            let summary = try await body(
                from: CommandCodeUsage.summary.withQuery(summaryQuery),
                token: credentials.apiKey
            )

            let windows = try CommandCodeUsage.windows(
                summaryJSON: summary,
                creditsJSON: credits,
                subscriptionJSON: subscription
            )

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: windows,
                headlineID: "monthly",
                weeklyID: "weekly",
                plan: lastKnownPlan?.nonEmptyPlan
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("commandcode: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func body(from url: URL, token: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("command-code-desktop", forHTTPHeaderField: "User-Agent")
        request.setValue("desktop", forHTTPHeaderField: "x-command-code-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        Log.usage.debug("GET \(url.host ?? "", privacy: .public)\(url.path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }
        return text
    }
}

private extension URL {
    func withQuery(_ items: [String: String?]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        let pairs = items.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !pairs.isEmpty { components.queryItems = pairs }
        return components.url ?? self
    }
}
