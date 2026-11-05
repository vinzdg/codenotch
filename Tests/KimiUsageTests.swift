import XCTest
@testable import Codenotch

/// The managed account's windows, pinned to the live response (user id
/// redacted) — the same figures the CLI's `/usage` leads with.
final class KimiUsageTests: XCTestCase {
    /// Verbatim from `GET /coding/v1/usages`, 2026-09-11.
    private let payload = """
    {"user":{"userId":"…","region":"REGION_OVERSEA","membership":{"level":"LEVEL_ADVANCED"}},\
    "usage":{"limit":"100","used":"2","remaining":"98","resetTime":"2026-09-15T19:39:34.389610Z"},\
    "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},\
    "detail":{"limit":"100","used":"8","remaining":"92","resetTime":"2026-09-11T16:39:34.389610Z"}}],\
    "parallel":{"limit":"30"}}
    """

    func testReadsTheWeeklySummaryAndTheFiveHourWindow() throws {
        let read = try KimiUsage.read(fromJSON: payload)
        XCTAssertEqual(read.windows.map(\.id), ["weekly", "rolling"])
        XCTAssertEqual(read.windows.map(\.label), ["Weekly limit", "5h limit"])
        XCTAssertEqual(read.windows.map(\.duration), [604800, 18000])
        // Element by element: `XCTAssertEqual` has no array form that takes an
        // accuracy, so the array comparison did not compile.
        let fractions = read.windows.compactMap(\.usedFraction)
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(fractions.first ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertEqual(fractions.last ?? -1, 0.08, accuracy: 0.0001)
    }

    /// Counts arrive as decimal strings, and the 5-hour window ships as 300
    /// minutes — normalised to hours, as the CLI does.
    func testStringCountsAndAMinuteWindowAreUnderstood() throws {
        let read = try KimiUsage.read(fromJSON: payload)
        let rolling = try XCTUnwrap(read.windows.first { $0.id == "rolling" })
        XCTAssertEqual(rolling.usedFraction ?? -1, 0.08, accuracy: 0.0001)
        XCTAssertEqual(rolling.duration, 5 * 3600)
    }

    /// Kimi can omit `used` when all quota remains. The remaining and limit
    /// values still describe a real zero-usage quota, for both row shapes.
    func testInfersZeroUsageFromLimitAndRemainingWhenUsedIsOmitted() throws {
        let json = """
        {"usage":{"limit":"100","remaining":"100","resetTime":"2026-09-15T19:39:34Z"},\
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},\
        "detail":{"limit":"100","remaining":"100","resetTime":"2026-09-11T16:39:34Z"}}]}
        """

        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["weekly", "rolling"])
        let fractions = read.windows.compactMap(\.usedFraction)
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(fractions[0], 0, accuracy: 0.0001)
        XCTAssertEqual(fractions[1], 0, accuracy: 0.0001)
    }

    /// The reset carries microseconds, which the plain ISO8601 formatter
    /// refuses — reading only that form silently loses every reset time.
    func testReadsAFractionalResetTime() throws {
        let read = try KimiUsage.read(fromJSON: payload)
        let weekly = try XCTUnwrap(read.windows.first { $0.id == "weekly" })
        let at = try XCTUnwrap(weekly.resetsAt)
        let plain = ISO8601DateFormatter().date(from: "2026-09-15T19:39:34Z")!
        XCTAssertEqual(at.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: 1)
    }

    func testReadsTheMembershipTierAsThePlan() throws {
        let read = try KimiUsage.read(fromJSON: payload)
        XCTAssertEqual(read.plan, "Advanced")
    }

    /// A window whose unit Codenotch cannot name is dropped rather than
    /// mislabelled; the weekly summary carries no window of its own and is a
    /// week by the CLI's own assumption.
    func testAnUnnamedWindowIsDroppedNotInvented() throws {
        let json = """
        {"usage":{"limit":"100","used":"2"},\
        "limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},\
        "detail":{"limit":"10","used":"1"}}]}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["weekly"])
        XCTAssertEqual(read.windows[0].duration, 604800)
    }

    /// An account that meters nothing — no summary, no limits — is not a
    /// reading, and it must not be shown as one.
    func testAnEmptyPayloadIsNothingMetered() {
        for json in ["{}", #"{"usage":{},"limits":[]}"#] {
            XCTAssertThrowsError(try KimiUsage.read(fromJSON: json)) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered, got \(error)")
                }
            }
        }
    }

    func testReadsKimiKModelQuotasInLimits() throws {
        let json = """
        {"usage":{"limit":"100","used":"2","remaining":"98"},\
        "limits":[\
        {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"8","remaining":"92"}},\
        {"model":"kimi-k","window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","used":"5","remaining":"45"}}\
        ]}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["weekly", "rolling", "kimi-k-rolling"])
        XCTAssertEqual(read.windows.map(\.group), [nil, nil, "Kimi K"])
        let kWindow = try XCTUnwrap(read.windows.first { $0.id == "kimi-k-rolling" })
        XCTAssertEqual(kWindow.usedFraction ?? -1, 0.1, accuracy: 0.0001)
    }

    func testReadsDedicatedKimiKSection() throws {
        let json = """
        {"usage":{"limit":"100","used":"2","remaining":"98"},\
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"8","remaining":"92"}}],\
        "kimi_k":{\
        "usage":{"limit":"60","used":"6","remaining":"54"},\
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"30","used":"3","remaining":"27"}}]\
        }}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["weekly", "rolling", "kimi-k-weekly", "kimi-k-rolling"])
        XCTAssertEqual(read.windows.map(\.group), [nil, nil, "Kimi K", "Kimi K"])
    }

    func testReadsOnlyKimiKQuotasWhenTopLevelEmpty() throws {
        let json = """
        {"kimi_k":{\
        "usage":{"limit":"50","used":"10","remaining":"40"},\
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","used":"5","remaining":"45"}}]\
        }}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["kimi-k-weekly", "kimi-k-rolling"])
        XCTAssertEqual(read.windows.map(\.group), ["Kimi K", "Kimi K"])
    }

    func testGarbageIsABadResponse() {
        XCTAssertThrowsError(try KimiUsage.read(fromJSON: "not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }
}

/// The token is borrowed from the CLI's own sign-in, and `expires_at` is
/// epoch seconds — a file without one is not a session to trust.
final class KimiCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-credentials-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsTheTokenAndItsExpiry() throws {
        let url = try file(#"{"access_token":"k-live","refresh_token":"r","expires_at":1789139960,"token_type":"Bearer"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let credentials = try KimiCredentials.load(from: url)
        XCTAssertEqual(credentials.accessToken, "k-live")
        XCTAssertEqual(credentials.expiresAt.timeIntervalSince1970, 1789139960, accuracy: 0.5)
    }

    func testAMissingFileIsNeedsAuth() {
        XCTAssertThrowsError(try KimiCredentials.load(
            from: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kimi-no-such-file.json"))) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAnEmptyTokenIsMissing() throws {
        let url = try file(#"{"access_token":"","expires_at":1789139960}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try KimiCredentials.load(from: url)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAMissingExpiryIsNotTrusted() throws {
        let url = try file(#"{"access_token":"k-live"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try KimiCredentials.load(from: url)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAnExpiredTokenReportsExpired() throws {
        let url = try file(#"{"access_token":"k-live","expires_at":1}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try KimiCredentials.load(from: url).isExpired)
    }
}
