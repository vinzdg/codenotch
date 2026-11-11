import SQLite3
import XCTest
@testable import Codenotch

/// Pinned to a `GetUsageLimits` CREDIT row recorded from a KIRO POWER account
/// whose plan credits were fully spent and whose overage was in use.
final class KiroLimitsTests: XCTestCase {
    /// Account identifiers are scrubbed. The numbers are the point: plan 10000,
    /// overage 3603.49, total 13603.49 — `currentUsage` includes overage.
    private let overageInUse = """
    {"daysUntilReset":0,"limits":[],"nextDateReset":1.7882208E9,
     "overageConfiguration":{"__type":"com.amazon.aws.codewhisperer#OverageConfiguration",
       "overageStatus":"ENABLED"},
     "subscriptionInfo":{"overageCapability":"OVERAGE_CAPABLE","subscriptionTitle":"KIRO POWER",
       "type":"Q_DEVELOPER_STANDALONE_POWER"},
     "usageBreakdownList":[{"bonuses":[],"currency":"USD","currentOverages":3603,
       "currentOveragesWithPrecision":3603.49,"currentUsage":13603,
       "currentUsageWithPrecision":13603.49,"displayName":"Credit","nextDateReset":1.7882208E9,
       "overageCap":10000,"overageCapWithPrecision":10000.0,"overageCharges":144.139711109352,
       "overageCredits":[],"overageRate":0.04,"resourceType":"CREDIT","unit":"INVOCATIONS",
       "usageLimit":10000,"usageLimitWithPrecision":10000.0}]}
    """

    private let usARN = "arn:aws:codewhisperer:us-east-1:123456789012:profile/test"
    private let euARN = "arn:aws:codewhisperer:eu-central-1:123456789012:profile/test"

    func testItReadsTheTokenAndProfileARNWithoutWriting() throws {
        let url = try makeDatabase(
            tokenJSON: #"{"access_token":"synthetic-kiro-token"}"#,
            profileJSON: #"{"arn":"\#(usARN)"}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let sidecars = ["-wal", "-shm", "-journal"].map { url.path + $0 }
        let beforeSidecars = Set(sidecars.filter { FileManager.default.fileExists(atPath: $0) })

        XCTAssertEqual(KiroLimits.loadAccessToken(from: url), "synthetic-kiro-token")
        XCTAssertEqual(KiroLimits.loadProfileARN(from: url), usARN)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let afterSidecars = Set(sidecars.filter { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(afterSidecars, beforeSidecars, "a read must not create sqlite sidecars")
    }

    /// The CLI owns refresh. An expired row still yields the access token
    /// that is there — never the refresh token, and never a write-back.
    func testAnExpiredTokenIsNotRefreshedOrWritten() throws {
        let url = try makeDatabase(
            tokenJSON: #"{"access_token":"expired-kiro-token","refresh_token":"refresh-me","expires_at":"2020-01-01T00:00:00Z"}"#,
            profileJSON: #"{"arn":"\#(usARN)"}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)

        XCTAssertEqual(KiroLimits.loadAccessToken(from: url), "expired-kiro-token")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testARefreshTokenAloneIsNotAnAccessToken() throws {
        let url = try makeDatabase(
            tokenJSON: #"{"refresh_token":"refresh-me"}"#,
            profileJSON: #"{"arn":"\#(usARN)"}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)

        XCTAssertNil(KiroLimits.loadAccessToken(from: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    /// Some CLI builds write camelCase; others write snake_case. Either has to
    /// yield the token or a signed-in install looks signed out.
    func testCamelCaseAccessTokenIsAccepted() throws {
        let url = try makeDatabase(
            tokenJSON: #"{"accessToken":"camel-token"}"#,
            profileJSON: #"{"arn":"\#(usARN)"}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)

        XCTAssertEqual(KiroLimits.loadAccessToken(from: url), "camel-token")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAMissingDatabaseYieldsNoCredentials() {
        let missing = URL(fileURLWithPath: "/tmp/kiro-missing-\(UUID().uuidString).sqlite3")
        XCTAssertNil(KiroLimits.loadAccessToken(from: missing))
        XCTAssertNil(KiroLimits.loadProfileARN(from: missing))
    }

    func testStateDatabaseUsesApplicationSupportAndKIRO_DATA_DIR() {
        let home = URL(fileURLWithPath: "/tmp/kiro-home", isDirectory: true)
        XCTAssertEqual(
            KiroLimits.stateDatabaseURL(home: home, environment: [:]).path,
            "/tmp/kiro-home/Library/Application Support/kiro-cli/data.sqlite3"
        )
        XCTAssertEqual(
            KiroLimits.stateDatabaseURL(
                home: home,
                environment: ["KIRO_DATA_DIR": "/tmp/kiro-data"]
            ).path,
            "/tmp/kiro-data/data.sqlite3"
        )
    }

    func testRegionalEndpointsFollowTheProfileARN() {
        XCTAssertEqual(
            KiroLimits.endpoint(forARN: usARN)?.absoluteString,
            "https://codewhisperer.us-east-1.amazonaws.com/"
        )
        XCTAssertEqual(
            KiroLimits.endpoint(forARN: euARN)?.absoluteString,
            "https://q.eu-central-1.amazonaws.com/"
        )
    }

    func testUnsupportedARNHasNoEndpoint() {
        let invalid = [
            "",
            "not-an-arn",
            "arn:aws:codewhisperer:eu-central-1:123456789012",
            "arn:aws-cn:codewhisperer:eu-central-1:123456789012:profile/test",
            "arn:aws:s3:eu-central-1:123456789012:profile/test",
            "arn:aws:codewhisperer::123456789012:profile/test",
            "arn:aws:codewhisperer:ap-southeast-1:123456789012:profile/test",
            "arn:aws:codewhisperer:EU-CENTRAL-1:123456789012:profile/test",
            "arn:aws:codewhisperer:us-east-1::profile/test",
            "arn:aws:codewhisperer:eu-central-1:123456789012:profile/",
            "arn:aws:codewhisperer:eu-central-1:123456789012:other/test",
            "arn:aws:codewhisperer:eu-central-1:123456789012:profile/test ",
        ]
        for arn in invalid {
            XCTAssertNil(KiroLimits.endpoint(forARN: arn), arn)
        }
    }

    func testItParsesThePowerOverageResponse() throws {
        let limits = try KiroLimits.parse(Data(overageInUse.utf8))
        XCTAssertEqual(limits.planLimit, 10_000)
        XCTAssertEqual(limits.planUsed, 10_000)
        XCTAssertEqual(limits.overageUsed, 3603.49)
        XCTAssertEqual(limits.overageCap, 10_000)
        XCTAssertEqual(limits.overageEnabled, true)
        XCTAssertEqual(limits.overageCharges, 144.139711109352)
        XCTAssertEqual(limits.resetAt, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertFalse(limits.hasUnseparatedBonus)
    }

    /// Some payloads omit the `WithPrecision` twin. The integer overage
    /// still has to come out of the plan total, or 8000 used of 10000
    /// with 3000 overage reads as 80% plan spend.
    func testIntegerOverageIsSubtractedFromPlanUsed() throws {
        let json = """
        {"nextDateReset":1.7882208E9,"usageBreakdownList":[{
          "resourceType":"CREDIT","currentUsageWithPrecision":8000,
          "usageLimitWithPrecision":10000,"currentOverages":3000,"bonuses":[]}]}
        """
        let limits = try KiroLimits.parse(Data(json.utf8))
        XCTAssertEqual(limits.planUsed, 5_000)
        XCTAssertEqual(limits.overageUsed, 3_000)
        XCTAssertEqual(limits.planLimit, 10_000)
    }

    func testIntegerCreditFieldsAloneStillSplitOverage() throws {
        let json = """
        {"nextDateReset":1.7882208E9,
         "overageConfiguration":{"overageStatus":"ENABLED"},
         "usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":13603,
           "currentOverages":3603,"usageLimit":10000,"overageCap":10000,"bonuses":[]}]}
        """
        let limits = try KiroLimits.parse(Data(json.utf8))
        XCTAssertEqual(limits.planUsed, 10_000)
        XCTAssertEqual(limits.overageUsed, 3603)
        XCTAssertEqual(limits.planLimit, 10_000)
        XCTAssertEqual(limits.overageCap, 10_000)
        XCTAssertEqual(limits.overageEnabled, true)
    }

    func testOverageAboveTotalUsageIsRejected() {
        let json = overageInUse.replacingOccurrences(
            of: "\"currentUsageWithPrecision\":13603.49",
            with: "\"currentUsageWithPrecision\":100"
        )
        XCTAssertThrowsError(try KiroLimits.parse(Data(json.utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testPlanUsageAboveTheLimitIsRejectedUnlessBonusesArePresent() {
        let overPlan = overageInUse.replacingOccurrences(
            of: "\"currentOveragesWithPrecision\":3603.49",
            with: "\"currentOveragesWithPrecision\":0"
        )
        XCTAssertThrowsError(try KiroLimits.parse(Data(overPlan.utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }

        let withBonus = overPlan.replacingOccurrences(
            of: "\"bonuses\":[]",
            with: "\"bonuses\":[{}]"
        )
        do {
            let limits = try KiroLimits.parse(Data(withBonus.utf8))
            XCTAssertEqual(limits.planUsed, 13603.49)
            XCTAssertTrue(limits.hasUnseparatedBonus)
        } catch {
            XCTFail("bonus-inclusive usage should parse, got \(error)")
        }
    }

    /// Disabling overage does not un-spend it: `currentUsage` still includes
    /// those credits, so the plan portion stays the remainder.
    func testDisabledOverageDropsTheCap() throws {
        let json = overageInUse.replacingOccurrences(
            of: "\"overageStatus\":\"ENABLED\"",
            with: "\"overageStatus\":\"DISABLED\""
        )
        let limits = try KiroLimits.parse(Data(json.utf8))
        XCTAssertNil(limits.overageCap)
        XCTAssertEqual(limits.overageEnabled, false)
        XCTAssertEqual(limits.overageUsed, 3603.49)
        XCTAssertEqual(limits.planUsed, 10_000)
    }

    func testEnabledOverageWithoutACapIsIncomplete() throws {
        let json = overageInUse
            .replacingOccurrences(of: "\"overageCap\":10000,", with: "")
            .replacingOccurrences(of: "\"overageCapWithPrecision\":10000.0,", with: "")
        let limits = try KiroLimits.parse(Data(json.utf8))
        XCTAssertNil(limits.overageEnabled)
        XCTAssertNil(limits.overageCap)
        XCTAssertEqual(limits.overageUsed, 3603.49)
    }

    /// Milliseconds, not seconds — parsed as seconds the reset lands centuries
    /// out, so it is dropped rather than shown as a countdown.
    func testAMillisecondResetIsNotADate() throws {
        let json = overageInUse.replacingOccurrences(
            of: "\"nextDateReset\":1.7882208E9",
            with: "\"nextDateReset\":1.7882208E12"
        )
        let limits = try KiroLimits.parse(Data(json.utf8))
        XCTAssertNil(limits.resetAt)
        XCTAssertEqual(limits.planUsed, 10_000)
    }

    func testSeveralCreditBalancesAreRejected() {
        let json = """
        {"nextDateReset":1.7882208E9,"usageBreakdownList":[
          {"resourceType":"CREDIT","currentUsageWithPrecision":1.0,"usageLimitWithPrecision":10.0},
          {"resourceType":"CREDIT","currentUsageWithPrecision":2.0,"usageLimitWithPrecision":20.0}]}
        """
        XCTAssertThrowsError(try KiroLimits.parse(Data(json.utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testRubbishIsRejected() {
        XCTAssertThrowsError(try KiroLimits.parse(Data("not json".utf8)))
    }

    /// Social login tokens (Google, GitHub, etc.) or external IdP tokens are accepted.
    func testSocialLoginTokenIsAccepted() throws {
        let url = try makeDatabase(
            tokenJSON: #"{"access_token":"social-kiro-token"}"#,
            profileJSON: #"{"arn":"\#(usARN)"}"#,
            tokenKey: "kirocli:social:token"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(KiroLimits.loadAccessToken(from: url), "social-kiro-token")
    }

    func testStateDatabaseURLDiscoversLocalSharePath() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)")
        let localShare = tempHome.appendingPathComponent(".local/share/kiro-cli")
        try FileManager.default.createDirectory(at: localShare, withIntermediateDirectories: true)
        let dbFile = localShare.appendingPathComponent("data.sqlite3")
        try Data().write(to: dbFile)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let resolved = KiroLimits.stateDatabaseURL(home: tempHome, environment: [:])
        XCTAssertEqual(resolved.path, dbFile.path)
    }

    /// Closing checkpoints the WAL, so the file reads back the way it would
    /// after kiro-cli has quit.
    private func makeDatabase(tokenJSON: String, profileJSON: String, tokenKey: String = "kirocli:odic:token") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-\(UUID().uuidString).sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE auth_kv(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT);
            """, nil, nil, nil), SQLITE_OK)
        insert(db, table: "auth_kv", key: tokenKey, value: tokenJSON)
        insert(db, table: "state", key: "api.codewhisperer.profile", value: profileJSON)
        sqlite3_close(db)
        return url
    }

    private func insert(_ db: OpaquePointer?, table: String, key: String, value: String) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO \(table) (key, value) VALUES (?, ?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
