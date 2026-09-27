import Foundation

/// Reads Muse Code's subscription quota: the 5-hour and weekly percentages.
///
/// Meta publishes those percentages in exactly one place — a
/// `response.subscription_usage` frame inside a `/v1/responses` SSE stream —
/// so each refresh sends one minimal streaming request (a one-word prompt,
/// the smallest accepted output) on the CLI's own minted API key, borrowed
/// from the login keychain. The token activity underneath comes from the
/// CLI's session logs instead, which cost nothing to read.
///
/// Each quota poll spends one minimal metered request (~30 tokens), accepted
/// so the ring stays realtime on the idle timer.
actor MuseLocalProvider: UsageProvider {
    nonisolated let id = "muse"
    nonisolated let displayName = "Muse"
    nonisolated let glyph = ProviderGlyph.meta

    nonisolated private let sessionsURL: URL
    nonisolated private let authURL: URL
    nonisolated private let calendar: Calendar
    nonisolated private let keychain: MuseKeychain
    private let session: URLSession
    private var log = MuseUsageLog()

    init(sessionsURL: URL = MuseCredentials.sessionsURL,
         authURL: URL = MuseCredentials.authURL,
         calendar: Calendar = .current,
         session: URLSession = .shared,
         keychain: MuseKeychain = MuseKeychain()) {
        self.sessionsURL = sessionsURL
        self.authURL = authURL
        self.calendar = calendar
        self.session = session
        self.keychain = keychain
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        MuseCredentials.anySourceExists(sessions: sessionsURL, auth: authURL)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Run `muse login` in Terminal — it signs in through your browser, and the notch reads its login and its logs."))
    }

    nonisolated func account() -> ProviderAccount? {
        MuseCredentials.account(from: authURL)
    }

    nonisolated func forgetCachedCredential() { keychain.askAgain() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // A Deny is honoured before anything else is touched.
        if keychain.isRefused { throw UsageProviderError.accessDenied }
        let quota = try await fetchQuota(apiKey: keychain.load())
        let now = Date()
        let samples = log.scan(at: sessionsURL, now: now)
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: quota,
            headlineID: "window", weeklyID: "weekly",
            tokenUsage: CodexTokenUsage(
                summary: MuseUsage.summary(from: samples, now: now, calendar: calendar),
                dailyUsageBuckets: MuseUsage.dailyBuckets(from: samples, now: now, calendar: calendar))
        )
    }

    /// One minimal streaming request, kept only for its quota frame.
    private func fetchQuota(apiKey: String) async throws -> [LimitWindow] {
        var request = URLRequest(
            url: URL(string: "https://api.meta.ai/v1/responses")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "muse-spark-1.3",
            "input": [["type": "message", "role": "user", "content": "ok"]],
            "max_output_tokens": 16,
            "stream": true,
            "reasoning": ["effort": "minimal"],
        ])
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 {
            // The key rotated under us; the CLI re-mints on next use, and the
            // copy in hand is wrong until it does.
            keychain.forgetCached()
            throw UsageProviderError.credentialExpired
        }
        if status == 429 {
            let hint = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            throw UsageProviderError.rateLimited(retryAfter: hint.isFinite ? max(60, hint) : 60)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
        guard let text = String(data: data, encoding: .utf8),
              let payload = MuseUsage.subscriptionPayload(fromSSE: text),
              let windows = try? MuseUsage.quotaWindows(from: payload) else {
            throw UsageProviderError.apiError("unrecognized subscription payload")
        }
        return windows
    }
}
