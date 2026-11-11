import XCTest
@testable import Codenotch

final class HiggsfieldCredentialsTests: XCTestCase {
    private func temporaryFileURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("higgsfield-cred-\(UUID().uuidString).json")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLoadsFromSettingsToken() throws {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { "hf-secret-from-settings" }
        sources.settingsPresent = { true }

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "hf-secret-from-settings")
        XCTAssertEqual(cred.source, .settings)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testLoadsFromEnvironment() throws {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["HIGGSFIELD_API_KEY": "env-api-key-123"]

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "env-api-key-123")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testLoadsFromCredentialsFile() throws {
        let fileURL = try temporaryFileURL(#"{"access_token": "token-from-file-abc"}"#)
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = fileURL

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "token-from-file-abc")
        XCTAssertEqual(cred.source, .credentialsFile)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testThrowsNeedsAuthWhenNoCredentialsFound() {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        sources.locateBinary = { nil }

        XCTAssertFalse(HiggsfieldCredentials.isPresent(sources))
        XCTAssertThrowsError(try HiggsfieldCredentials.load(sources)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }

    /// `HF_TOKEN` belongs to Hugging Face; it must never be sent to Higgsfield.
    func testHuggingFacesTokenIsNotHiggsfields() {
        var sources = HiggsfieldCredentialSources()
        sources.environment = ["HF_TOKEN": "hf_hugging_face_secret", "HF_CREDENTIALS": "x"]
        sources.credentialsURL = URL(fileURLWithPath: "/nonexistent/credentials.json")
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.locateBinary = { nil }
        XCTAssertFalse(HiggsfieldCredentials.isPresent(sources))
        XCTAssertThrowsError(try HiggsfieldCredentials.load(sources))
    }

    /// A plain `hf` on the PATH is Hugging Face's unless it resolves into
    /// Higgsfield's package.
    func testAnHfBinaryOutsideHiggsfieldsPackageIsNotHiggsfields() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hf = dir.appendingPathComponent("hf")
        try "#!/bin/sh\n".write(to: hf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hf.path)
        XCTAssertFalse(HiggsfieldCLI.isHiggsfield(hf))
        XCTAssertNil(HiggsfieldCLI.locateBinary(environment: ["PATH": dir.path, "HOME": "/nonexistent"]))
    }

}
