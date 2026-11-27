import XCTest
@testable import Codenotch

final class MiMoCredentialsTests: XCTestCase {
    private func temporaryFileURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimo-auth-\(UUID().uuidString).json")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLoadsFromKeychain() {
        let key = MiMoCredentials.loadAPIKey(
            environment: [:],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"),
            keychain: { "sk-mimo-keychain-test" }
        )
        XCTAssertEqual(key, "sk-mimo-keychain-test")
    }

    func testLoadsFromEnvironmentKey() {
        let key = MiMoCredentials.loadAPIKey(
            environment: ["MIMO_API_KEY": "env-mimo-key-123"],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"),
            keychain: { nil }
        )
        XCTAssertEqual(key, "env-mimo-key-123")
    }

    func testLoadsFromMimoCodeEnvironmentKey() {
        let key = MiMoCredentials.loadAPIKey(
            environment: ["MIMOCODE_API_KEY": "env-mimocode-key-456"],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"),
            keychain: { nil }
        )
        XCTAssertEqual(key, "env-mimocode-key-456")
    }

    func testLoadsFromAuthContentEnvironmentVariable() {
        let jsonContent = #"{"xiaomi": {"apiKey": "inline-auth-token-789"}}"#
        let key = MiMoCredentials.loadAPIKey(
            environment: ["MIMOCODE_AUTH_CONTENT": jsonContent],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"),
            keychain: { nil }
        )
        XCTAssertEqual(key, "inline-auth-token-789")
    }

    func testLoadsFromCLIAuthFileWithNestedXiaomiKey() throws {
        let fileURL = try temporaryFileURL(#"{"xiaomi": {"apiKey": "cli-auth-key-nested"}}"#)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let key = MiMoCredentials.loadAPIKey(
            environment: [:],
            authURL: fileURL,
            keychain: { nil }
        )
        XCTAssertEqual(key, "cli-auth-key-nested")
        XCTAssertTrue(MiMoCredentials.isCLICredentialPresent(authURL: fileURL))
    }

    func testLoadsFromCLIAuthFileWithRootKey() throws {
        let fileURL = try temporaryFileURL(#"{"apiKey": "cli-root-key"}"#)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let key = MiMoCredentials.loadAPIKey(
            environment: [:],
            authURL: fileURL,
            keychain: { nil }
        )
        XCTAssertEqual(key, "cli-root-key")
        XCTAssertTrue(MiMoCredentials.isCLICredentialPresent(authURL: fileURL))
    }

    func testReturnsNilWhenNoCredentialsFound() {
        let key = MiMoCredentials.loadAPIKey(
            environment: [:],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"),
            keychain: { nil }
        )
        XCTAssertNil(key)
    }

    func testIsAPIKeyPresentWhenEnvironmentKeyExists() {
        XCTAssertTrue(MiMoCredentials.isAPIKeyPresent(
            environment: ["MIMO_API_KEY": "test-key"],
            authURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        ))
    }
}
