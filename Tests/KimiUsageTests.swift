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

    func testReadsCurrentQuotaRatiosAndMonthlyWindows() throws {
        let json = """
        {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
        "detail":{"limit":"100","used":"38","remaining":"62","resetTime":"2026-11-05T15:58:26.882959Z"}}],
        "usages":{"limit_5h":{"used_ratio":0.3832,"reset_time":"2026-11-05T15:58:26Z"},
        "limit_month_total":{"used_ratio":0.0233,"reset_time":"2026-12-06T00:00:00Z"},
        "limit_month_code":{"used_ratio":0.0189,"reset_time":"2026-12-06T00:00:00Z"}}}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["rolling", "monthly-total", "monthly-code"])
        XCTAssertEqual(read.windows.map(\.label), ["5h limit", "Monthly limit", "Monthly code limit"])
        let rolling = try XCTUnwrap(read.windows.first { $0.id == "rolling" })
        let monthly = try XCTUnwrap(read.windows.first { $0.id == "monthly-total" })
        let code = try XCTUnwrap(read.windows.first { $0.id == "monthly-code" })
        XCTAssertEqual(rolling.usedFraction ?? -1, 0.3832, accuracy: 0.000001)
        XCTAssertEqual(monthly.usedFraction ?? -1, 0.0233, accuracy: 0.000001)
        XCTAssertEqual(code.usedFraction ?? -1, 0.0189, accuracy: 0.000001)
        XCTAssertEqual(rolling.duration, 18000)
        XCTAssertNil(monthly.duration)
        XCTAssertNil(code.duration)
        XCTAssertEqual(monthly.resetsAt,
                       ISO8601DateFormatter().date(from: "2026-12-06T00:00:00Z"))
    }

    func testReadsCurrentOnlyWeeklyAndFiveHourQuotas() throws {
        let json = #"{"usages":{"limit_5h":{"used_ratio":0.25},"limit_7d":{"used_ratio":"0.125"}}}"#
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["rolling", "weekly"])
        XCTAssertEqual(read.windows.map(\.duration), [18000, 604800])
        XCTAssertEqual(read.windows[1].usedFraction ?? -1, 0.125, accuracy: 0.000001)
    }

    func testZeroRatiosAreRealQuotaReadings() throws {
        let json = #"{"usages":{"limit_5h":{"used_ratio":0},"limit_month_total":{"used_ratio":0}}}"#
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.usedFraction), [0, 0])
    }

    func testInvalidCurrentRatiosPreserveLegacyFallback() throws {
        for ratio in ["null", "true", "false", "-0.1", #""not-a-number""#, #""NaN""#, #""Infinity""#] {
            let json = """
            {"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},
            "detail":{"limit":100,"used":8}}],
            "usages":{"limit_5h":{"used_ratio":\(ratio)},"limit_month_total":{"used_ratio":\(ratio)}}}
            """
            let read = try KimiUsage.read(fromJSON: json)
            XCTAssertEqual(read.windows.map(\.id), ["rolling"], "ratio: \(ratio)")
            XCTAssertEqual(read.windows[0].usedFraction ?? -1, 0.08, accuracy: 0.000001)
        }
    }

    func testReadsMonthlyOnlyAccountAndOverQuotaUsage() throws {
        let json = #"{"usages":{"limit_month_total":{"used_ratio":1.2},"limit_month_code":{"used_ratio":0.75}}}"#
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["monthly-total", "monthly-code"])
        XCTAssertEqual(read.windows[0].usedFraction ?? -1, 1.2, accuracy: 0.000001)
    }

    func testCurrentQuotaReplacesAllLegacyDuplicates() throws {
        let json = """
        {"usage":{"limit":100,"used":2},
        "limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":100,"used":3}}],
        "usages":{"limit_7d":{"used_ratio":0.125}}}
        """
        let read = try KimiUsage.read(fromJSON: json)
        XCTAssertEqual(read.windows.map(\.id), ["weekly"])
        XCTAssertEqual(read.windows.map(\.usedFraction), [0.125])
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
        for json in ["{}", #"{"usage":{},"limits":[]}"#, #"{"usages":{"unknown":{"used_ratio":0.5}}}"#] {
            XCTAssertThrowsError(try KimiUsage.read(fromJSON: json)) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered, got \(error)")
                }
            }
        }
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
