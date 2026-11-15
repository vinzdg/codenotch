import Foundation

/// The LM Studio API token, for a server that has been told to require one.
///
/// LM Studio ships with authentication off, so most servers answer with no
/// token at all and nothing here is needed. When "Require API token" is on,
/// tokens are minted in LM Studio's own Server Settings and kept there only as
/// SHA-512 hashes (`~/.lmstudio/.internal/permissions-store.json`) — so unlike
/// every other credential this app reads, there is nothing on disk to borrow.
/// The user pastes one into Settings and it lives in the login keychain under a
/// service name no other app uses, the same arrangement `OllamaCredentials`
/// has. `LM_API_TOKEN` is checked first because it is the variable LM Studio's
/// own documentation uses in its examples.
enum LMStudioCredentials {
    static let keychainService = "lmstudio-api-token"
    static let keychainAccount = "codenotch"
    static let environmentKey = "LM_API_TOKEN"

    /// Posted after the stored token changes, so a live connection can
    /// authenticate again with whatever is there now rather than at relaunch.
    static let didChange = Notification.Name("LMStudioCredentialsDidChange")

    /// Held until the item moves, for the reason spelled out in
    /// `CredentialCache`: a data read can prompt, and this is reached every
    /// second from the local-runtime timer, every 2 s from `LMStudioLink`'s
    /// reconnect loop while the server is down, and twice per render of
    /// `LMStudioSettingsRow` — an uncached read there turns one prompt into
    /// one every few seconds. A stored token never expires on its own.
    private static let cache = CredentialCache<String> { _ in false }

    private static func cachedKeychainToken() -> String? {
        try? cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) },
            reload: {
                guard let token = KeychainItem.read(service: keychainService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return token
            }
        )
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     keychain: () -> String? = cachedKeychainToken) -> String? {
        if let env = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return keychain()
    }

    /// Whether a token is available, judged without a data read: the
    /// environment variable, else the item's attributes, which are free to
    /// ask about unlike its contents. Never the cache — that would not
    /// reflect a `store`/`delete` that just happened.
    static var isPresent: Bool {
        load(keychain: { nil }) != nil || KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
    }

    @discardableResult
    static func store(_ token: String) -> Bool {
        cache.forget()
        let stored = KeychainItem.store(service: keychainService, account: keychainAccount,
                                        value: token.trimmingCharacters(in: .whitespacesAndNewlines))
        if stored { NotificationCenter.default.post(name: didChange, object: nil) }
        return stored
    }

    @discardableResult
    static func delete() -> Bool {
        cache.forget()
        let deleted = KeychainItem.delete(service: keychainService, account: keychainAccount)
        if deleted { NotificationCenter.default.post(name: didChange, object: nil) }
        return deleted
    }

    static func forgetCached() { cache.forget() }

    /// The two halves LM Studio reads a token as.
    ///
    /// `sk-lm-<8 alphanumerics>:<20 alphanumerics>` is the exact pattern the
    /// `lms` command validates with, and the same pair authenticates the SDK
    /// socket: the identifier names the client and the passkey proves it.
    struct Parts: Equatable {
        let clientIdentifier: String
        let clientPasskey: String
    }

    static func parts(of token: String) -> Parts? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-lm-") else { return nil }
        let body = trimmed.dropFirst("sk-lm-".count).split(separator: ":", omittingEmptySubsequences: false)
        guard body.count == 2, body[0].count == 8, body[1].count == 20,
              body.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return nil }
        return Parts(clientIdentifier: String(body[0]), clientPasskey: String(body[1]))
    }
}

/// Where the LM Studio server is listening.
enum LMStudioEndpoint {
    static let defaultAddress = "http://127.0.0.1:1234"

    /// The same loopback-only rules as the Ollama address: plain HTTP to this
    /// Mac, no credentials in the URL, no path. A monitor must not be pointed
    /// at another machine by a typo.
    static func parse(_ address: String) throws -> URL {
        do {
            return try OllamaEndpoint.parse(address)
        } catch {
            throw LMStudioError.invalidEndpoint
        }
    }

    /// The port LM Studio itself is configured to serve on, read from its own
    /// settings file, so a server moved off 1234 is found without anyone
    /// retyping it here. Nil when LM Studio has never run on this Mac.
    static func configuredAddress(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        let file = home.appendingPathComponent(".lmstudio/.internal/http-server-config.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int, (1...65535).contains(port)
        else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    /// The SDK socket shares the HTTP port; each namespace is a path.
    static func websocketURL(_ endpoint: URL, namespace: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "ws"
        parts.host = endpoint.host ?? "127.0.0.1"
        parts.port = endpoint.port ?? 80
        parts.path = "/" + namespace
        return parts.url!
    }

    /// Where LM Studio writes its server log, one file per day.
    static func serverLogsDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".lmstudio/server-logs")
    }
}

enum LMStudioError: LocalizedError, Equatable {
    case invalidEndpoint
    case unavailable
    case invalidResponse
    /// The server requires an API token and none, or the wrong one, was sent.
    case needsToken
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L10n.t("Use an HTTP address on this Mac, such as http://127.0.0.1:1234.")
        case .unavailable:
            return L10n.t("LM Studio server unavailable. Start the server in LM Studio's Developer tab and check the address.")
        case .invalidResponse:
            return L10n.t("This server did not return an LM Studio model listing.")
        case .needsToken:
            return L10n.t("LM Studio requires an API token. Create one in LM Studio → Developer → Server Settings and paste it in Settings → LM Studio.")
        case .http(let code):
            return L10n.t("LM Studio returned HTTP \(code). Check the server address and configuration.")
        }
    }
}
