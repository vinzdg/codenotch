import Foundation

/// Token from `~/.kimi-code/credentials/kimi-code.json`.
///
/// Kimi Code CLI signs in through auth.kimi.com and writes the OAuth session
/// here — one file per managed provider, and `kimi-code` is the Kimi Code
/// account itself. Codenotch only reads it: the access token lives fifteen
/// minutes (`expires_in: 900`) and refreshing is the CLI's job, the same
/// bargain as Grok's — writing a new one would race the CLI for the file.
/// `KIMI_CODE_HOME` moves the whole data root, so the path honours it.
struct KimiCredentials {
    static var authURL: URL {
        let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            ?? ProcessInfo.processInfo.environment["KIMI_K_HOME"]
        let nonOverridden = override.flatMap { value -> String? in value.isEmpty ? nil : value }
        let root = nonOverridden.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-code")
        let defaultPath = root.appendingPathComponent("credentials/kimi-code.json")
        if FileManager.default.fileExists(atPath: defaultPath.path) {
            return defaultPath
        }
        let kPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-k/credentials/kimi-k.json")
        if FileManager.default.fileExists(atPath: kPath.path) {
            return kPath
        }
        return defaultPath
    }

    let accessToken: String
    let expiresAt: Date

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard (try? load(from: url)) != nil else { return nil }
        return ProviderAccount(
            label: nil,   // the token carries no address
            plan: nil,
            source: "Kimi Code",
            manageURL: URL(string: "https://www.kimi.com/code/console")
        )
    }

    static func load(from url: URL = authURL) throws -> KimiCredentials {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else { throw UsageProviderError.needsAuth }

        // `expires_at` is epoch seconds. A file without one is not a session
        // to trust with a request that cannot succeed.
        guard let expires = (root["expires_at"] as? NSNumber)?.doubleValue, expires > 0
        else { throw UsageProviderError.needsAuth }

        return KimiCredentials(accessToken: token,
                               expiresAt: Date(timeIntervalSince1970: expires))
    }
}
