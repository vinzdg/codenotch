import Foundation

/// The OpenCode Go key, borrowed from OpenCode's own sign-in.
///
/// `~/.local/share/opencode/auth.json` holds one entry per connected account.
/// The `opencode-go` entry (`{"type": "api", "key": ...}`) is the Go plan's API
/// key, and it authenticates the usage endpoint directly — no workspace id, no
/// cookie, no second sign-in. Any other entry (`openai`, `google`, …) is that
/// vendor's key, and claiming one would read the wrong account under
/// OpenCode's name.
enum OpenCodeCredentials {
    struct Credential {
        let token: String
    }

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    static func load(from url: URL = authURL) -> Credential? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"]
        else { return nil }
        // The entry is either the key itself or an object carrying it — both
        // shapes have shipped across OpenCode versions.
        if let token = nonEmpty(entry as? String) { return Credential(token: token) }
        guard let object = entry as? [String: Any] else { return nil }
        let token = ["key", "apiKey", "api_key", "token", "accessToken"]
            .compactMap { nonEmpty(object[$0] as? String) }.first
        return token.map(Credential.init(token:))
    }

    /// Non-empty strings only: an empty key is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
