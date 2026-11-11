import XCTest
@testable import Codenotch

/// The token is borrowed from the Kilo CLI's own sign-in file, so only the
/// `kilo` entry may ever be claimed, and only its access token or API key.
final class KiloCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kilo-auth-\(UUID().uuidString).json")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    func testReadsTheOAuthAccessToken() throws {
        let url = try file(#"{"kilo":{"type":"oauth","access":"acc-1","refresh":"r","expires":9999999999999}}"#)
        let c = try XCTUnwrap(KiloCredentials.load(from: url))
        XCTAssertEqual(c.token, "acc-1")
        XCTAssertNil(c.organizationID)
    }

    func testReadsAnAPIKeyEntry() throws {
        let url = try file(#"{"kilo":{"type":"api","key":"sk-kilo-123"}}"#)
        let c = try XCTUnwrap(KiloCredentials.load(from: url))
        XCTAssertEqual(c.token, "sk-kilo-123")
        XCTAssertNil(c.organizationID)
    }

    func testCarriesTheOrganizationAccountID() throws {
        let url = try file(#"{"kilo":{"type":"oauth","access":"a","refresh":"r","expires":1,"accountId":"org-7"}}"#)
        let c = try XCTUnwrap(KiloCredentials.load(from: url))
        XCTAssertEqual(c.organizationID, "org-7")
    }

    func testOtherEntriesAreNotOursToClaim() throws {
        let url = try file(#"{"openai":{"type":"api","key":"sk-someone-else"}}"#)
        XCTAssertNil(KiloCredentials.load(from: url))
    }

    func testAnEmptiedEntryIsNotACredential() throws {
        // The owner emptied it; an empty token is a request that cannot
        // succeed being sent all the same.
        let empty = try file(#"{"kilo":{"type":"oauth","access":"","refresh":"r","expires":1}}"#)
        XCTAssertNil(KiloCredentials.load(from: empty))
        let missing = try file(#"{"kilo":{"type":"oauth","refresh":"r","expires":1}}"#)
        XCTAssertNil(KiloCredentials.load(from: missing))
        let absent = try file("{}")
        XCTAssertNil(KiloCredentials.load(from: absent))
    }

    func testTheDefaultPathIsTheCLIDataDirectory() {
        XCTAssertEqual(
            KiloCredentials.authURL.path,
            NSHomeDirectory() + "/.local/share/kilo/auth.json"
        )
    }
}
