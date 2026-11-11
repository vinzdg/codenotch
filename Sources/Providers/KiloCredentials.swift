import Foundation

/// Kilo's own credential, borrowed from the Kilo CLI's sign-in.
///
/// The Kilo CLI (the backend the VS Code extension and the JetBrains plugin
/// both drive) keeps one entry per account in
/// `~/.local/share/kilo/auth.json` under the key `kilo`. The entry is either
/// an OAuth login (`{"type": "oauth", "access": ..., "refresh": ..., "expires":
/// ...}` — `expires` in milliseconds, written by the CLI's own refresh) or an
/// API key (`{"type": "api", "key": ...}`). The access token and the key
/// authenticate the profile endpoints directly — no organization id, no
/// second sign-in.
///
/// The file is read on every fetch, like GLM's and OpenCode's: an ordinary
/// file read puts no keychain prompt in front of anyone, and the CLI rewrites
/// the access token as it refreshes, so a cached copy would go stale behind
/// the file. Nothing here writes or refreshes the credential — the CLI owns
/// it, exactly as Codex's borrow works.
enum KiloCredentials {
    struct Credential {
        let token: String
        /// The OAuth entry carries the organization the CLI last selected in
        /// `accountId` (nil for a personal account). Sent as
        /// `x-kilocode-organizationid`, the same header the CLI sends, so a
        /// team account reads the team's numbers rather than silently
        /// personifying one member.
        let organizationID: String?
    }

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/kilo/auth.json")
    }

    static func load(from url: URL = authURL, now: Date = Date()) -> Credential? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["kilo"] as? [String: Any]
        else { return nil }

        switch entry["type"] as? String {
        case "api":
            return key(entry["key"] as? String).map { Credential(token: $0, organizationID: nil) }
        case "oauth":
            // An expired access token is still sent. The CLI refreshes it in
            // its own time — the reading just answers 401 until it does, which
            // the honest statuses already say. Guessing a refresh from here
            // would race the CLI's own.
            if let access = key(entry["access"] as? String) {
                return Credential(token: access, organizationID: key(entry["accountId"] as? String))
            }
            // An entry with no access token has been emptied by its owner; the
            // refresh token is not ours to spend.
            return nil
        default:
            return nil
        }
    }

    /// Non-empty strings only: an empty token is worse than a missing one, it
    /// is a request that cannot succeed being sent all the same.
    private static func key(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
