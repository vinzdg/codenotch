import CommonCrypto
import XCTest
@testable import Codenotch

final class CursorSafeStorageTests: XCTestCase {
    func testPlaintextTokensPassThrough() {
        XCTAssertEqual(CursorSafeStorage.decodeAccessToken("header.payload.sig"),
                       "header.payload.sig")
    }

    func testUnknownSealedVersionIsRefused() {
        XCTAssertNil(CursorSafeStorage.decodeAccessToken("cursor-safe-storage:v2:abc"))
        XCTAssertNil(CursorSafeStorage.decodeAccessToken("cursor-safe-storage:"))
    }

    func testMacOSV10RoundTripUnderInjectedPassword() throws {
        let password = Data("test-keychain-key".utf8)
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.sig"
        let sealed = try sealV10(plaintext: Data(token.utf8), password: password)
        XCTAssertEqual(
            CursorSafeStorage.decryptV1(payloadB64: sealed, password: password),
            token
        )
    }

    /// Chromium OSCrypt: PBKDF2-HMAC-SHA1 → AES-128-CBC, `v10` tag, spaces IV.
    private func sealV10(plaintext: Data, password: Data) throws -> String {
        var key = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        XCTAssertEqual(status, kCCSuccess)

        let iv = Data(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)
        var outLength = 0
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        let cryptStatus = out.withUnsafeMutableBytes { outBytes in
            plaintext.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress, plaintext.count,
                            outBytes.baseAddress, out.count,
                            &outLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(Int(cryptStatus), kCCSuccess)
        out.count = outLength
        var sealed = Data("v10".utf8)
        sealed.append(out)
        return sealed.base64EncodedString()
    }
}
