import Foundation

/// The OIDC session Grok Build keeps in `~/.grok/auth.json`.
///
/// Codenotch only ever *reads* this file. Refreshing is left to `grok` itself:
/// minting a token would mean writing a credential this app does not own, so
/// when the access token ages out the notch says `credentialExpired` and waits
/// for the CLI to rotate it in the ordinary course of being used.
enum GrokCredentials {
    struct Credential {
        let accessToken: String
        let expiresAt: Date
        let email: String?
        var isExpired: Bool { expiresAt <= Date() }
    }

    /// `GROK_HOME` if set, otherwise `~/.grok` — the same rule the CLI uses.
    static func homeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static func authFileURL(home: URL = homeDirectory()) -> URL {
        home.appendingPathComponent("auth.json")
    }

    static func load() -> Credential? { load(from: authFileURL()) }

    /// The file is a map of OIDC issuer URLs to session objects. Official Grok
    /// Build logins live under `https://auth.x.ai::<client>`; older sessions
    /// used `https://accounts.x.ai/sign-in`. Prefer the former so a leftover
    /// accounts.x.ai blob cannot shadow the CLI's current login.
    static func load(from url: URL) -> Credential? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var candidates: [(preferred: Bool, expires: Date, credential: Credential)] = []
        for (scope, value) in root {
            guard let entry = value as? [String: Any],
                  let token = string(entry["key"]),
                  let expiryText = string(entry["expires_at"]),
                  let expires = parseDate(expiryText)
            else { continue }
            let preferred = scope.hasPrefix("https://auth.x.ai")
            candidates.append((
                preferred,
                expires,
                Credential(
                    accessToken: token,
                    expiresAt: expires,
                    email: string(entry["email"])
                )
            ))
        }
        let pool = candidates.contains(where: \.preferred)
            ? candidates.filter(\.preferred)
            : candidates
        return pool.max(by: { $0.expires < $1.expires })?.credential
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
