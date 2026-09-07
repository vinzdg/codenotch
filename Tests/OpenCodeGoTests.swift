import XCTest
@testable import Codenotch

/// Guards the shape of `GET https://opencode.ai/zen/go/v1/usage`. It is not a
/// published API — it is the endpoint OpenCode's own console dashboard reads —
/// so these are the tests that will fail first if the shape moves.
final class OpenCodeGoTests: XCTestCase {
    private func parse(_ json: String) throws -> [LimitWindow] {
        try OpenCodeGoUsage.windows(from: Data(json.utf8))
    }

    /// Trimmed from a real response: three windows, each a used-percentage and
    /// an ISO reset time carrying fractional seconds.
    private let live = """
    { "usage": {
        "rolling": { "status": "ok", "percent": 4, "resetsAt": "2026-08-13T16:27:38.287Z" },
        "weekly":  { "status": "ok", "percent": 3, "resetsAt": "2026-08-17T00:00:00.287Z" },
        "monthly": { "status": "ok", "percent": 1, "resetsAt": "2026-09-13T06:06:01.287Z" } } }
    """

    func testReadsTheThreeWindows() throws {
        let windows = try parse(live)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(windows.map(\.label), ["5-hour session", "Weekly limit", "Monthly limit"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.04, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.03, accuracy: 0.0001)
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0.01, accuracy: 0.0001)
    }

    /// `percent` is how much has been *used*, the same figure the OpenCode
    /// dashboard leads with — read as remaining, a fresh account reads full.
    func testPercentIsUsedNotRemaining() throws {
        let windows = try parse(live)
        XCTAssertEqual(windows[0].summary, "4% Used · 96% left")
    }

    /// Fractional seconds: parsed without them the millisecond tail makes the
    /// whole string unparseable and the countdown goes missing.
    func testResetTimesCarryFractionalSeconds() throws {
        let windows = try parse(live)
        let expected = Date(timeIntervalSince1970: 1_786_638_458.287)
        XCTAssertEqual(windows[0].resetsAt?.timeIntervalSince1970 ?? -1,
                       expected.timeIntervalSince1970, accuracy: 0.5)
    }

    /// With "Use balance" enabled, spending rides past the plan limit — the
    /// percentage is still a true statement and must not be clamped.
    func testPercentPastOneHundredIsKept() throws {
        let json = """
        { "usage": { "rolling": { "status": "ok", "percent": 104,
                                   "resetsAt": "2026-08-13T16:27:38.287Z" } } }
        """
        let windows = try parse(json)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 1.04, accuracy: 0.0001)
    }

    /// A window with no percentage is not a reading to invent a scale for.
    func testWindowWithoutPercentIsDropped() throws {
        let json = """
        { "usage": { "rolling": { "status": "ok" },
                     "weekly":  { "status": "ok", "percent": 3,
                                  "resetsAt": "2026-08-17T00:00:00.287Z" } } }
        """
        let windows = try parse(json)
        XCTAssertEqual(windows.map(\.id), ["weekly"])
    }

    func testNothingReadableThrows() {
        XCTAssertThrowsError(try parse("{}"))
        XCTAssertThrowsError(try parse(#"{ "usage": { "rolling": {} } }"#))
        XCTAssertThrowsError(try parse("not json"))
    }

    // MARK: Credentials

    private func credentials(_ json: String?) throws -> OpenCodeGoCredentials {
        try OpenCodeGoCredentials.load(authJSON: json)
    }

    /// The shape `/connect` writes: an `api` entry with a `key`.
    func testReadsTheAPIEntry() throws {
        let json = """
        { "opencode-go": { "type": "api", "key": "go-key-123" },
          "anthropic": { "type": "api", "key": "somebody-elses" } }
        """
        XCTAssertEqual(try credentials(json).key, "go-key-123")
    }

    /// An OAuth entry is a browser session, not a key to send anywhere.
    func testOAuthEntryIsNotUsable() {
        let json = #"{"opencode-go": {"type": "oauth", "access": "a", "refresh": "r"}}"#
        XCTAssertThrowsError(try credentials(json))
    }

    /// Empty and missing keys read as signed out rather than as a request that
    /// cannot succeed being sent all the same.
    func testEmptyKeyIsSignedOut() {
        XCTAssertThrowsError(try credentials(#"{"opencode-go": {"type": "api", "key": ""}}"#))
        XCTAssertThrowsError(try credentials(#"{"opencode-go": {}}"#))
        XCTAssertThrowsError(try credentials("{}"))
        XCTAssertThrowsError(try credentials(nil))
    }
}
