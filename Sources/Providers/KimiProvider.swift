import Foundation
import os

/// Reads Kimi Code usage from the endpoint the CLI's own `/usage` asks, with
/// the OAuth token the CLI stores on sign-in — see `KimiCredentials`.
///
/// The numbers are Kimi's, so this is `.official`. The token expires every
/// fifteen minutes and the CLI renews it as it runs; an expired one is
/// `.credentialExpired`, because minting a new token here would race the CLI
/// for the file. A 404 is the endpoint's own answer for an account with no
/// Kimi Code plan — readable, but metering nothing, and not an error.
actor KimiProvider: UsageProvider {
    nonisolated let id = "kimi"
    nonisolated let displayName = "Kimi"
    nonisolated let glyph = ProviderGlyph.kimi

    private let session: URLSession
    private let authURL: URL

    init(session: URLSession = .shared, authURL: URL = KimiCredentials.authURL) {
        self.session = session
        self.authURL = authURL
    }

    nonisolated var signInRoute: SignInRoute {
        .command("kimi", name: "Kimi", install: URL(string: "https://moonshotai.github.io/kimi-cli/en/guides/getting-started.html"))
    }

    nonisolated func account() -> ProviderAccount? { KimiCredentials.account() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try KimiCredentials.load(from: authURL)
        if credentials.isExpired { throw UsageProviderError.credentialExpired }

        let body = try await fetch(token: credentials.accessToken)
        Log.usage.debug("kimi usages -> \(body.prefix(400), privacy: .public)")
        let read = try KimiUsage.read(fromJSON: body)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: read.windows,
            headlineID: "rolling",
            weeklyID: "weekly",
            plan: read.plan
        )
    }

    private func fetch(token: String) async throws -> String {
        var request = URLRequest(url: KimiUsage.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        Log.usage.debug("GET api.kimi.com/coding/v1/usages")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("kimi usages endpoint answered \(status)")

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        // The endpoint's answer for an account without a Kimi Code plan — the
        // CLI's own message for it is "Usage endpoint not available".
        if status == 404 {
            throw UsageProviderError.nothingMetered(L10n.t("No Kimi Code plan on this account"))
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }
        return text
    }
}
