import XCTest
@testable import Codenotch

final class KreaCredentialsTests: XCTestCase {
    private func temporaryFileURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("krea-cred-\(UUID().uuidString).json")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLoadsFromSettingsToken() throws {
        var sources = KreaCredentialSources()
        sources.settingsToken = { "krea-secret-from-settings" }
        sources.settingsPresent = { true }

        let cred = try KreaCredentials.load(sources)
        XCTAssertEqual(cred.token, "krea-secret-from-settings")
        XCTAssertEqual(cred.source, .settings)
        XCTAssertTrue(KreaCredentials.isPresent(sources))
    }

    func testLoadsFromEnvironment() throws {
        var sources = KreaCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["KREA_API_KEY": "env-krea-key-123"]

        let cred = try KreaCredentials.load(sources)
        XCTAssertEqual(cred.token, "env-krea-key-123")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(KreaCredentials.isPresent(sources))
    }

    func testLoadsFromAppBuilderEnvironmentKey() throws {
        var sources = KreaCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["KREA_APP_BUILDER_API_KEY": "app-builder-key-456"]

        let cred = try KreaCredentials.load(sources)
        XCTAssertEqual(cred.token, "app-builder-key-456")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(KreaCredentials.isPresent(sources))
    }

    func testLoadsFromCredentialsFile() throws {
        let fileURL = try temporaryFileURL(#"{"api_key": "token-from-file-abc"}"#)
        var sources = KreaCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = fileURL

        let cred = try KreaCredentials.load(sources)
        XCTAssertEqual(cred.token, "token-from-file-abc")
        XCTAssertEqual(cred.source, .credentialsFile)
        XCTAssertTrue(KreaCredentials.isPresent(sources))
    }

    func testThrowsNeedsAuthWhenNoCredentialsFound() {
        var sources = KreaCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        sources.locateBinary = { nil }

        XCTAssertFalse(KreaCredentials.isPresent(sources))
        XCTAssertThrowsError(try KreaCredentials.load(sources)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }
}
