import XCTest
@testable import Codenotch

final class MimoCodeCredentialsTests: XCTestCase {
    private func temporaryFileURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimocode-cred-\(UUID().uuidString).json")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLoadsFromSettingsToken() throws {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { "mimocode-secret-from-settings" }
        sources.settingsPresent = { true }

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "mimocode-secret-from-settings")
        XCTAssertEqual(cred.source, .settings)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromMimoCodeApiKeyEnvironment() throws {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["MIMOCODE_API_KEY": "env-mimocode-key-123"]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "env-mimocode-key-123")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromMimoApiKeyEnvironment() throws {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["MIMO_API_KEY": "env-mimo-key-456"]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "env-mimo-key-456")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromMimoTokenEnvironment() throws {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["MIMO_TOKEN": "tp-token-789"]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "tp-token-789")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromMimoCodeAuthContentEnvironment() throws {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["MIMOCODE_AUTH_CONTENT": #"{"apiKey": "auth-content-key-321"}"#]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "auth-content-key-321")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromCredentialsFile() throws {
        let fileURL = try temporaryFileURL(#"{"api_key": "token-from-file-abc"}"#)
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURLs = [fileURL]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "token-from-file-abc")
        XCTAssertEqual(cred.source, .credentialsFile)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testLoadsFromNestedAuthFile() throws {
        let fileURL = try temporaryFileURL(#"{"auth": {"token": "nested-token-xyz"}}"#)
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURLs = [fileURL]

        let cred = try MimoCodeCredentials.load(sources)
        XCTAssertEqual(cred.token, "nested-token-xyz")
        XCTAssertEqual(cred.source, .credentialsFile)
        XCTAssertTrue(MimoCodeCredentials.isPresent(sources))
    }

    func testThrowsNeedsAuthWhenNoCredentialsFound() {
        var sources = MimoCodeCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURLs = [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")]
        sources.locateBinary = { nil }

        XCTAssertFalse(MimoCodeCredentials.isPresent(sources))
        XCTAssertThrowsError(try MimoCodeCredentials.load(sources)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }
}
