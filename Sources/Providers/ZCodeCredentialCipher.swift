import CryptoKit
import Foundation

/// Reads ZCode's side of `~/.zcode/v2/credentials.json`.
///
/// Every value in that file is wrapped as `enc:v1:<iv>.<tag>.<ciphertext>`
/// with base64url parts: AES-256-GCM, the key the SHA-256 of a secret that is
/// `$ZCODE_CREDENTIAL_SECRET` when set, else
/// `zcode-credential-fallback:<platform>:<home>:<user>`. ZCode's own bundled
/// CLI spells the whole construction out, and the notch mirrors it rather
/// than asking for a key of its own — recent ZCode encrypts every value at
/// rest, so skipping the wrapped ones reads a signed-in plan as signed out.
///
/// The `darwin` below is not a guess: this target builds for macOS only, and
/// that is what the fallback's platform slot holds there. The Windows port
/// derives its own with `win32`.
enum ZCodeCredentialCipher {
    static let prefix = "enc:v1:"
    static let secretEnvironmentKey = "ZCODE_CREDENTIAL_SECRET"

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    /// The secret ZCode sealed its credentials with: the environment override
    /// when set, else the fallback derived from where and who. Each input is
    /// a parameter so a test can pin the secret without becoming another user.
    static func defaultSecret(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        username: String = NSUserName()
    ) -> String {
        if let override = environment[secretEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return override
        }
        return "zcode-credential-fallback:darwin:\(homeDirectory):\(username)"
    }

    /// The plaintext, or nil when the value cannot be read — bad shape, wrong
    /// part lengths, a tag that does not verify, or bytes that are not text.
    /// Nil means "try the next key", never "send what we have": a wrong guess
    /// would read on the monitor as a signed-out plan.
    ///
    /// A value without the marker passes through untouched, the way ZCode's
    /// own decrypt does: older builds wrote the token in the clear, and those
    /// files are still out there.
    static func decrypt(_ value: String, secret: String) -> String? {
        guard isEncrypted(value) else { return value }
        let parts = value.dropFirst(prefix.count)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = Data(base64url: String(parts[0])), iv.count == 12,
              let tag = Data(base64url: String(parts[1])), tag.count == 16,
              let ciphertext = Data(base64url: String(parts[2]))
        else { return nil }
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: key),
              let text = String(data: plain, encoding: .utf8)
        else { return nil }
        return text
    }
}

private extension Data {
    /// Foundation decodes base64, not base64url; the alphabets differ in two
    /// characters and the padding, which is re-added here. A length that lands
    /// one past a quantum has no valid encoding and fails outright.
    init?(base64url: String) {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        base64 += String(repeating: "=", count: (4 - remainder) % 4)
        self.init(base64Encoded: base64)
    }
}
