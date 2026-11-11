import Foundation

/// Identity and token from `~/.grok/auth.json`.
///
/// Grok CLI signs in through `auth.x.ai` and writes the session here. Codenotch
/// only reads it — the file is the CLI's, and writing a new access token into
/// it would race the CLI for the file. The access token lasts six hours and the
/// CLI renews it only while it runs, so on a Mac that merely *watches* Grok the
/// session spends most of its life expired. The file also carries the refresh
/// token and client id the CLI renews with; `GrokLocalProvider` uses those to
/// mint its own access token, held in memory and never written back.
struct GrokCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    let accessToken: String
    let expiresAt: Date
    let email: String?
    /// What the CLI would renew the session with. `nil` on a file older than
    /// the field — that one can only be renewed by `grok login`.
    let refreshToken: String?
    let clientID: String?

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL, source: String = "Grok") -> ProviderAccount? {
        guard let stored = (try? load(from: url)) else { return nil }
        return ProviderAccount(
            label: stored.email,
            plan: nil,
            source: source,
            manageURL: URL(string: "https://grok.com/?_s=usage")
        )
    }

    static func load(from url: URL = authURL) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = pick(from: root)
        else { throw UsageProviderError.needsAuth }

        guard let token = entry["key"] as? String, !token.isEmpty else {
            throw UsageProviderError.needsAuth
        }

        return GrokCredentials(
            accessToken: token,
            expiresAt: date(entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
            email: entry["email"] as? String,
            refreshToken: nonEmpty(entry["refresh_token"]),
            clientID: nonEmpty(entry["oidc_client_id"])
        )
    }

    /// Only a session minted by xAI itself. The file is keyed by
    /// `issuer::client_id`, and Grok also supports a customer IdP whose token
    /// is meant for a private proxy — sending that to cli-chat-proxy.grok.com
    /// would be handing someone else's credential to the public endpoint.
    static let trustedIssuer = "https://auth.x.ai"

    /// Where `trustedIssuer` renews a session: the `token_endpoint` its OpenID
    /// discovery document names, which the CLI's public client id may call
    /// with no secret.
    static let tokenURL = URL(string: trustedIssuer + "/oauth2/token")!

    /// The file is keyed by `issuer::client_id`. One signed-in CLI is the
    /// ordinary case; if several sit there, the one that is still live wins,
    /// otherwise the first *trusted* entry.
    static func pick(from root: [String: Any]) -> [String: Any]? {
        let entries = root.compactMap { key, value -> [String: Any]? in
            guard let entry = value as? [String: Any], isTrusted(key: key, entry: entry)
            else { return nil }
            return entry
        }
        if let live = entries.first(where: {
            guard let expiry = date($0["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
    }

    static func isTrusted(key: String, entry: [String: Any]) -> Bool {
        // The issuer is the part before `::`, compared whole. A prefix match
        // also let `https://auth.x.ai.example.com::id` through.
        if key.components(separatedBy: "::").first == trustedIssuer { return true }
        if let issuer = entry["oidc_issuer"] as? String, issuer == trustedIssuer { return true }
        return false
    }

    static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let text = any as? String, !text.isEmpty else { return nil }
        return text
    }
}
