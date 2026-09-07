import Foundation
import Security
import CommonCrypto

/// Grok Bot 0.44 stores its active account in sand-secrets.json, encrypted
/// with Electron's macOS safeStorage. Read only; Grok Bot owns token refresh.
struct GrokBotCredentials {
    let accessToken: String
    let teamID: String?

    static let bundleID = "com.anysphere.sand"
    static let service = "Grok Bot Safe Storage"
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    private static let keyCache = CredentialCache<Data> { _ in true }

    static func forgetCached() { keyCache.forget() }

    static func activeAccount(from data: Data) throws -> [String: String] {
        struct Accounts: Decodable {
            let active: String?
            let accounts: [String: [String: String]]
        }
        let root = try JSONDecoder().decode([String: String].self, from: data)
        guard let text = root["cursor-accounts"],
              let accounts = try? JSONDecoder().decode(Accounts.self, from: Data(text.utf8)),
              let active = accounts.active,
              let account = accounts.accounts[active],
              account["cursor-access-token"] != nil else {
            throw UsageProviderError.needsAuth
        }
        return account
    }

    static func account() -> ProviderAccount? {
        guard let data = try? Data(contentsOf: file),
              (try? activeAccount(from: data)) != nil else { return nil }
        return ProviderAccount(label: nil, plan: nil, source: "Grok Bot",
                               manageURL: nil)
    }

    static func load() throws -> GrokBotCredentials {
        guard let data = try? Data(contentsOf: file) else { throw UsageProviderError.needsAuth }
        let account = try activeAccount(from: data)
        let key = try keyCache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service) },
            reload: readKey
        )
        let token = try decrypt(account["cursor-access-token"]!, key: key)
        guard !token.isEmpty else { throw UsageProviderError.needsAuth }
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let exp = json["exp"] as? Double, exp <= Date().timeIntervalSince1970 {
                throw UsageProviderError.credentialExpired
            }
        }
        let team = try account["cursor-selected-team-id"].map { try decrypt($0, key: key) }
        return GrokBotCredentials(accessToken: token,
                                  teamID: team.flatMap { Int($0).flatMap { $0 > 0 ? String($0) : nil } })
    }

    private static func readKey() throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "Grok Bot Key",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw ClaudeCredentials.wasRefused(status)
                ? UsageProviderError.accessDenied : UsageProviderError.needsAuth
        }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let resultCode = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                bytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, &key, key.count)
        }
        guard resultCode == kCCSuccess else { throw UsageProviderError.needsAuth }
        return Data(key)
    }

    static func decrypt(_ stored: String, key: Data) throws -> String {
        var encoded = stored
        if stored.hasPrefix("scoped:v1:") {
            let parts = stored.split(separator: ":", maxSplits: 3)
            guard parts.count == 4 else { throw UsageProviderError.needsAuth }
            encoded = String(parts[3])
        }
        guard key.count == kCCKeySizeAES128,
              let data = Data(base64Encoded: encoded), data.starts(with: Data("v10".utf8))
        else { throw UsageProviderError.needsAuth }
        let ciphertext = Data(data.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            ciphertext.withUnsafeBytes { bytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                        iv, bytes.baseAddress, ciphertext.count, &output, capacity, &written)
            }
        }
        guard status == kCCSuccess,
              let value = String(bytes: output.prefix(written), encoding: .utf8)
        else { throw UsageProviderError.needsAuth }
        return value
    }
}
