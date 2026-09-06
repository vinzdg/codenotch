import XCTest
@testable import Codenotch

/// The Go plan windows, pinned to the live response (secret redacted) — the
/// same figures the OpenCode dashboard shows.
final class OpenCodeUsageTests: XCTestCase {
    /// Verbatim from `GET /zen/go/v1/usage`, 2026-09-06.
    private let payload = """
    {"usage":{\
    "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-06T12:31:06.611Z"},\
    "weekly":{"status":"ok","percent":0,"resetsAt":"2026-09-07T00:00:00.611Z"},\
    "monthly":{"status":"ok","percent":0,"resetsAt":"2026-10-03T13:09:45.611Z"}}}
    """

    func testReadsAllThreeWindows() throws {
        let w = try OpenCodeUsage.windows(fromJSON: payload)
        XCTAssertEqual(w.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(w.map(\.label), ["5h limit", "Weekly limit", "Monthly limit"])
        XCTAssertTrue(w.allSatisfy { ($0.usedFraction ?? -1) == 0 })
    }

    /// `percent` is used, matching the dashboard's "X% used" — the ring must
    /// not invert it.
    func testPercentIsUsedNotRemaining() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":65,"resetsAt":"2026-09-06T12:31:06.611Z"}}}
        """
        let w = try OpenCodeUsage.windows(fromJSON: json)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.65, accuracy: 0.0001)
    }

    /// The reset carries milliseconds, which the plain ISO8601 formatter
    /// refuses — reading only that form silently loses every reset time.
    func testReadsAMillisecondResetTime() throws {
        let w = try OpenCodeUsage.windows(fromJSON: payload)
        let rolling = try XCTUnwrap(w.first { $0.id == "rolling" })
        let at = try XCTUnwrap(rolling.resetsAt)
        let plain = ISO8601DateFormatter().date(from: "2026-09-06T12:31:06Z")!
        XCTAssertEqual(at.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: 1)
    }

    /// A window without a percent is dropped rather than invented; with none
    /// left at all that is a bad response, not zeros.
    func testWindowsWithoutAPercentAreDropped() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok"},"weekly":{"status":"ok","percent":3}}}
        """
        let w = try OpenCodeUsage.windows(fromJSON: json)
        XCTAssertEqual(w.map(\.id), ["weekly"])
    }

    func testAnEmptyUsageIsNotAReading() {
        for json in ["{}", #"{"usage":{}}"#,
                     #"{"usage":{"rolling":{"status":"ok"}}}"#] {
            XCTAssertThrowsError(try OpenCodeUsage.windows(fromJSON: json)) { error in
                guard case UsageProviderError.badResponse = error else {
                    return XCTFail("expected badResponse, got \(error)")
                }
            }
        }
    }
}

/// The key is borrowed from OpenCode's own sign-in, so only the `opencode-go`
/// entry may ever be claimed — any other entry is somebody else's account.
final class OpenCodeCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsTheGoKey() throws {
        let url = try file(#"{"opencode-go":{"type":"api","key":"sk-go-live"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(OpenCodeCredentials.load(from: url)?.token, "sk-go-live")
    }

    func testReadsABareStringEntry() throws {
        let url = try file(#"{"opencode-go":"sk-go-live"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(OpenCodeCredentials.load(from: url)?.token, "sk-go-live")
    }

    func testNeverClaimsAnotherVendorsKey() throws {
        let url = try file(
            #"{"openai":{"type":"api","key":"sk-openai"},"google":{"type":"api","key":"g-key"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(OpenCodeCredentials.load(from: url))
    }

    func testAnEmptyKeyIsMissing() throws {
        let url = try file(#"{"opencode-go":{"type":"api","key":""}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(OpenCodeCredentials.load(from: url))
    }
}
