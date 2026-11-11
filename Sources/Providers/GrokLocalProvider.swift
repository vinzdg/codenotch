import Foundation
import os

/// Reads Grok Build usage from the same billing endpoint the CLI's `/usage` uses.
///
/// The credential is Grok's own `~/.grok/auth.json` session. Its access token
/// lasts six hours and the CLI renews it only while it runs, which on a Mac
/// that only watches Grok — the work happening on another machine — leaves the
/// ring at `credentialExpired` for all but six hours after each `grok login`.
/// So an expired session is renewed here from the file's refresh token, the
/// way the CLI would, and the result is kept in this actor: the file is never
/// written, so there is nothing to race the CLI for. That is safe because
/// `auth.x.ai` issues a new refresh token on every renewal but does not revoke
/// the old one — the CLI's copy in the file keeps working after ours is used.
/// Credits (`?format=credits`) is the weekly Grok Build allowance, and the only
/// number this endpoint actually states.
actor GrokLocalProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.grok
    nonisolated let profile: GrokProfile

    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let session: URLSession
    private let authURL: URL

    /// The access token minted here, with the refresh token it came from. A
    /// fresh `grok login` writes a new refresh token, and a token renewed from
    /// the old one must not outlive that.
    private var renewed: (accessToken: String, expiresAt: Date, from: String)?

    init(profile: GrokProfile = .default(),
         session: URLSession = .shared,
         authURL: URL? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.authURL = authURL ?? profile.authURL
    }

    nonisolated var signInRoute: SignInRoute {
        guard profile.slug != nil else { return defaultSignInRoute }
        return .command(profile.signInCommand, name: displayName,
                        install: URL(string: "https://docs.x.ai/build/overview"))
    }

    nonisolated private var defaultSignInRoute: SignInRoute {
        .command("grok login", name: "Grok", install: URL(string: "https://docs.x.ai/build/overview"))
    }

    nonisolated func account() -> ProviderAccount? { GrokCredentials.account(from: authURL, source: profile.sourceName) }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try GrokCredentials.load(from: authURL)
        let token = try await liveToken(for: credentials)

        let credits: String
        do {
            credits = try await body(from: creditsURL, token: token)
        } catch UsageProviderError.needsAuth {
            // A token minted here was refused: forget it, so the next tick
            // renews again instead of re-presenting the same refused token.
            renewed = nil
            throw UsageProviderError.needsAuth
        }
        Log.usage.debug("grok credits -> \(credits.prefix(400), privacy: .private)")

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: try GrokUsage.windows(creditsJSON: credits),
            headlineID: "credits",
            weeklyID: "credits"
        )
    }

    /// The file's own token while it lives — the CLI renewed it, so ours is
    /// stale by definition — then the one minted here, then a new one.
    private func liveToken(for credentials: GrokCredentials) async throws -> String {
        if !credentials.isExpired {
            renewed = nil
            return credentials.accessToken
        }
        if let renewed, renewed.from == credentials.refreshToken, renewed.expiresAt > Date() {
            return renewed.accessToken
        }
        guard let refreshToken = credentials.refreshToken, let clientID = credentials.clientID else {
            throw UsageProviderError.credentialExpired
        }
        let minted = try await renew(refreshToken: refreshToken, clientID: clientID)
        renewed = (minted.accessToken, minted.expiresAt, refreshToken)
        return minted.accessToken
    }

    /// The `refresh_token` grant against the issuer's token endpoint. Any
    /// refusal is `credentialExpired`, not `needsAuth`: the session in the file
    /// is still the account's, the last reading is still true, and the guidance
    /// for both is the same `grok login`.
    private func renew(refreshToken: String, clientID: String) async throws
        -> (accessToken: String, expiresAt: Date)
    {
        var request = URLRequest(url: GrokCredentials.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = Self.form([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else {
            Log.usage.debug("grok token renewal refused: HTTP \(status, privacy: .public)")
            throw UsageProviderError.credentialExpired
        }
        // `auth.x.ai` says six hours. An issuer that does not say gets an hour,
        // sooner than any lifetime seen, rather than a token trusted past it.
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        return (accessToken, Date().addingTimeInterval(lifetime))
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&").data(using: .utf8)!
    }

    private func body(from url: URL, token: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

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
