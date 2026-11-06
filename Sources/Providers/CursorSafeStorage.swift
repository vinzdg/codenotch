import CommonCrypto
import Foundation
import Security

/// Cursor seals `cursorAuth/accessToken` as `cursor-safe-storage:v1:<base64>`.
///
/// That envelope is Chromium/Electron OSCrypt on macOS: a Keychain secret under
/// `Cursor Safe Storage`, PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds) into
/// a 16-byte AES key, then `v10` + AES-128-CBC (fixed all-spaces IV, PKCS7).
/// Older editor builds wrote the JWT in the clear; those pass through unchanged.
enum CursorSafeStorage {
    static let sealedPrefix = "cursor-safe-storage:v1:"
    private static let sealedAny = "cursor-safe-storage:"
    private static let versionTag = Data("v10".utf8)
    private static let salt = Data("saltysalt".utf8)
    private static let rounds: UInt32 = 1003
    private static let keyLength = 16
    private static let iv = Data(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)

    /// Keychain entries Cursor / Electron have used for the OSCrypt password.
    private static let keychainEntries: [(service: String, account: String)] = [
        ("Cursor Safe Storage", "Cursor Key"),
        ("Cursor Safe Storage", "Cursor"),
        ("Chromium Safe Storage", "Chromium Key"),
    ]

    /// Resolve a stored access-token value to the JWT the usage API expects.
    /// Unknown sealed versions return `nil` so the caller can surface needsAuth
    /// instead of posting ciphertext as a session cookie.
    static func decodeAccessToken(_ stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(sealedPrefix) {
            let payload = String(trimmed.dropFirst(sealedPrefix.count))
            return decryptV1(payloadB64: payload)
        }
        if trimmed.hasPrefix(sealedAny) {
            return nil
        }
        return trimmed
    }

    /// Pure decrypt under an injected password — for tests without a Keychain.
    static func decryptV1(payloadB64: String, password: Data) -> String? {
        guard let encrypted = Data(base64Encoded: payloadB64),
              encrypted.starts(with: versionTag),
              encrypted.count > versionTag.count
        else { return nil }
        let ciphertext = encrypted.dropFirst(versionTag.count)
        guard ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        let key = deriveKey(from: password)
        return aes128CBCDecrypt(ciphertext: Data(ciphertext), key: key)
    }

    private static func decryptV1(payloadB64: String) -> String? {
        for entry in keychainEntries {
            guard let secret = KeychainItem.read(service: entry.service, account: entry.account),
                  let password = secret.data(using: .utf8),
                  let plain = decryptV1(payloadB64: payloadB64, password: password)
            else { continue }
            return plain
        }
        return nil
    }

    private static func deriveKey(from password: Data) -> Data {
        var derived = Data(count: keyLength)
        derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        rounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        return derived
    }

    private static func aes128CBCDecrypt(ciphertext: Data, key: Data) -> String? {
        var outLength = 0
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, out.count,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        let text = String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
