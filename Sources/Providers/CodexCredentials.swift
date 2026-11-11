import Foundation

/// Borrows Codex's local session without refreshing or changing its credentials.
enum CodexCredentials {
    struct Credential {
        let accessToken: String
        let accountID: String
    }

    static var authURL: URL {
        CodexProfile.default().authURL
    }

    static func load(from url: URL = authURL, now: Date = Date()) throws -> Credential {
        guard let data = try? Data(contentsOf: url) else { throw UsageProviderError.needsAuth }
        return try load(from: data, now: now)
    }

    /// The same judgement over bytes that arrived another way — the remote
    /// reader's SSH output is this file over a wire.
    static func load(from data: Data, now: Date = Date()) throws -> Credential {
        struct Auth: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String
            }
            let tokens: Tokens
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !auth.tokens.account_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageProviderError.needsAuth }

        if let expiry = claims(inJWT: auth.tokens.access_token)?["exp"] as? Double,
           expiry <= now.timeIntervalSince1970 {
            throw UsageProviderError.credentialExpired
        }
        return Credential(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
    }

    static func account(from url: URL = authURL, source: String = "Codex") -> ProviderAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = claims(inJWT: idToken)
        else { return nil }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return ProviderAccount(
            label: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            source: source,
            manageURL: URL(string: "https://chatgpt.com/#settings/Account")
        )
    }

    /// Claims supply identity labels and a local expiry hint. The server validates the token.
    static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
