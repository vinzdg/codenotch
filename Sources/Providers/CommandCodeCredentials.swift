import Foundation

/// Identity from `~/.commandcode/auth.json`, the same file the Command Code
/// desktop app writes on login.
///
/// Codenotch never signs in — it borrows that key. Refreshing is Command
/// Code's job. `COMMAND_CODE_API_KEY` wins when set, matching the desktop
/// harness; a differently named Hermes leftover is ignored on purpose.
struct CommandCodeCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".commandcode/auth.json")
    }

    let apiKey: String
    let userName: String?

    static func account(from url: URL = authURL,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        source: String = "Command Code") -> ProviderAccount? {
        guard let stored = try? load(from: url, environment: environment) else { return nil }
        return ProviderAccount(
            label: stored.userName,
            plan: nil,
            source: source,
            manageURL: URL(string: "https://commandcode.ai")
        )
    }

    static func load(from url: URL = authURL,
                     environment: [String: String] = ProcessInfo.processInfo.environment)
                    throws -> CommandCodeCredentials {
        if let env = environment["COMMAND_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return CommandCodeCredentials(apiKey: env, userName: nil)
        }

        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = nonEmpty(root["apiKey"] as? String)
        else { throw UsageProviderError.needsAuth }

        return CommandCodeCredentials(
            apiKey: key,
            userName: nonEmpty(root["userName"] as? String)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
