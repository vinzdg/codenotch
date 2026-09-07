import Foundation

/// Who is paying for the Gemini calls this ring counts — as far as that can be
/// told without ever touching the key.
///
/// Google publishes no usage endpoint for an API key, so there is nothing here
/// to authenticate with and no reason to read a secret: the key stays wherever
/// its owner put it (`GEMINI_API_KEY`, an `.env` file, `auth.json`, the
/// keychain) and none of that is opened. The only things worth naming on the
/// settings row are which tools' logs the numbers came from, and how Gemini CLI
/// was told to pay — the free `oauth-personal` login is a quota, not a bill,
/// and calling it "metered" would put a price on it.
///
/// `~/.gemini/settings.json` is where the CLI records that choice:
///
/// ```
/// {"security":{"auth":{"selectedType":"gemini-api-key"}}}
/// ```
///
/// The CLI accepts comments in that file and `JSONSerialization` does not, so
/// every failure to read it answers "unknown" rather than guessing — the label
/// is a courtesy, and a wrong one would be worse than none.
enum GeminiAPICredentials {
    static var settingsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/settings.json")
    }

    static func authType(at file: URL = GeminiAPICredentials.settingsFile) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = root["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let type = auth["selectedType"] as? String,
              !type.isEmpty
        else { return nil }
        return type
    }

    /// No tool kept a log means there is no account to describe — not an empty
    /// one, none — so the settings row stays quiet rather than claiming a key.
    static func account(tools: [String], authType: String?) -> ProviderAccount? {
        guard !tools.isEmpty else { return nil }
        let isGoogleAccount = authType == "oauth-personal"
        return ProviderAccount(
            label: isGoogleAccount ? "Google account" : "API key",
            // "metered" rather than a plan name: a bare key is not on a plan,
            // it is charged per token at a price that changes under the app.
            plan: isGoogleAccount ? nil : "metered",
            // The tools that wrote the numbers, which is the honest answer to
            // "whose reading is this" when no credential was borrowed at all.
            source: tools.joined(separator: ", "),
            manageURL: nil
        )
    }
}
