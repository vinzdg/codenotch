import Foundation

enum AmpCredentials {
    static var secretsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/amp/secrets.json")
    }

    static func load(from url: URL = secretsURL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            throw UsageProviderError.needsAuth
        } catch {
            throw UsageProviderError.apiError(
                L10n.t("Couldn't read Amp's secrets.json. Check its file permissions or run amp login again.")
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageProviderError.apiError(
                L10n.t("Amp's secrets.json is invalid. Run amp login again.")
            )
        }

        // A secrets file can contain several servers. Never send a proxy or
        // another server's key to ampcode.com just because its prefix matches.
        for key in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
            if let value = object[key] as? String {
                let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty, !token.contains(where: { $0.isWhitespace }) { return token }
            }
        }
        throw UsageProviderError.needsAuth
    }
}
