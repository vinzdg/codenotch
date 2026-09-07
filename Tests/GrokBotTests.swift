import XCTest
@testable import Codenotch

final class GrokBotTests: XCTestCase {
    func testReportedPercentResetAndBlock() throws {
        let snapshot = try GrokBotUsage.snapshot(from: Data(#"{"usagePercent":87.5,"nextResetTimestampUtc":"2026-09-10T12:00:00Z","hasAvailableUsage":false}"#.utf8))
        XCTAssertEqual(snapshot.usedFraction, 0.875)
        XCTAssertEqual(snapshot.headlineID, "included")
        XCTAssertEqual(snapshot.headline?.resetsAt,
                       ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z"))
        XCTAssertNotNil(snapshot.block)
    }

    func testZeroAndOverageAreRealReadings() throws {
        for percent in [0.0, 120.0] {
            let snapshot = try GrokBotUsage.snapshot(from: Data("{\"usagePercent\":\(percent)}".utf8))
            XCTAssertEqual(snapshot.usedFraction, percent / 100)
            XCTAssertNil(snapshot.block)
            XCTAssertNil(snapshot.headline?.resetsAt)
        }
    }

    func testMissingOrInvalidUsageDoesNotBecomeZero() {
        for json in ["{}", "{\"usagePercent\":-1}", "{\"usagePercent\":true}", "<html>login</html>"] {
            XCTAssertThrowsError(try GrokBotUsage.snapshot(from: Data(json.utf8)))
        }
    }

    func testPooledAllowanceAndZeroLimitAreNotInvented() {
        for json in [#"{"usagePercent":25,"usesPooledEnterpriseAllowance":true}"#,
                     #"{"includedLimitZero":true}"#] {
            XCTAssertThrowsError(try GrokBotUsage.snapshot(from: Data(json.utf8))) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("Expected unmetered status, got \(error)")
                }
            }
        }
    }

    func testOnlyActiveAccountIsSelected() throws {
        let record = #"{"active":"second","accounts":{"first":{"cursor-access-token":"first-token"},"second":{"cursor-access-token":"second-token","cursor-selected-team-id":"team"}}}"#
        let data = try JSONEncoder().encode(["cursor-accounts": record])
        let account = try GrokBotCredentials.activeAccount(from: data)
        XCTAssertEqual(account["cursor-access-token"], "second-token")
        XCTAssertEqual(account["cursor-selected-team-id"], "team")
        let signedOut = try JSONEncoder().encode(["cursor-accounts": #"{"active":null,"accounts":{"first":{"cursor-access-token":"old"}}}"#])
        XCTAssertThrowsError(try GrokBotCredentials.activeAccount(from: signedOut))
    }

    func testInvalidEncryptedCredentialFailsClosed() {
        for value in ["plaintext:v1:secret", "scoped:v1:", "not-base64", Data("v11invalid".utf8).base64EncodedString()] {
            XCTAssertThrowsError(try GrokBotCredentials.decrypt(value, key: Data(repeating: 0, count: 16)))
        }
    }

    func testElectronSafeStorageAndScopedValues() throws {
        // Independent AES-128-CBC / PKCS7 fixture, zero key and space IV.
        let encrypted = "djEwcBkz7VYBQANHft+YDZwowbgsLNsX+JQKfR0BArlW9/E="
        for stored in [encrypted, "scoped:v1:\(String(repeating: "a", count: 64)):\(encrypted)"] {
            XCTAssertEqual(try GrokBotCredentials.decrypt(stored, key: Data(repeating: 0, count: 16)),
                           "test-access-token")
        }
    }
}
