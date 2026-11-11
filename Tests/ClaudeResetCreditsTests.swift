import XCTest
@testable import Codenotch

final class ClaudeResetCreditsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z")!

    private func response(_ block: String) throws -> UsageResponse {
        try UsageResponse.decoder.decode(UsageResponse.self, from: Data("""
        {"limits":[{"kind":"session","percent":8,"resets_at":"2099-01-01T00:00:00Z"}],
         "cedar_ember":\(block)}
        """.utf8))
    }

    func testLiveGrantReportsTheCountAndExpiry() throws {
        let credits = try XCTUnwrap(response(ClaudeResetFixture.block).cedarEmber?.credits(at: now))
        XCTAssertEqual(credits.availableCount, 1)
        XCTAssertEqual(credits.nextExpiry,
                       ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))
    }

    func testMissingNullAndMalformedResetDataKeepTheUsageWindows() throws {
        for block in ["null", "42", #"{"eligible":true,"grants":"changed"}"#] {
            let parsed = try response(block)
            XCTAssertEqual(parsed.limitWindows().first?.usedFraction, 0.08)
            XCTAssertNil(parsed.cedarEmber)
            XCTAssertEqual(parsed.reportsResetCredits, block != "null")
        }
        let missing = try UsageResponse.decoder.decode(UsageResponse.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.reportsResetCredits)
        XCTAssertNil(missing.cedarEmber)
    }

    func testSpentPausedFutureAndExpiredGrantsAreHidden() throws {
        for block in [
            ClaudeResetFixture.block.replacingOccurrences(of: "\"resets_left\":1", with: "\"resets_left\":0"),
            ClaudeResetFixture.block.replacingOccurrences(of: "\"resets_left\":1", with: "\"resets_left\":-1"),
            ClaudeResetFixture.block.replacingOccurrences(of: "\"paused\":false", with: "\"paused\":true"),
            ClaudeResetFixture.block.replacingOccurrences(of: "2026-09-22", with: "2026-09-24"),
            ClaudeResetFixture.block.replacingOccurrences(of: "2026-10-22", with: "2026-09-22")
        ] {
            XCTAssertEqual(try response(block).cedarEmber?.credits(at: now)?.availableCount, 0)
        }
        let parsed = try XCTUnwrap(response(ClaudeResetFixture.block).cedarEmber)
        XCTAssertEqual(parsed.credits(at: parsed.grants[0].startsAt)?.availableCount, 1)
        XCTAssertEqual(parsed.credits(at: parsed.grants[0].endsAt)?.availableCount, 0)
    }

    func testUnsupportedSurfaceIsUnknownButAnIneligibleAccountHasNoResets() throws {
        let surface = try response(#"{"eligible":false,"ineligible_reason":"surface","grants":[]}"#)
        XCTAssertNil(surface.cedarEmber?.credits(at: now))
        let account = try response(#"{"eligible":false,"ineligible_reason":"tier","grants":[]}"#)
        XCTAssertEqual(account.cedarEmber?.credits(at: now)?.availableCount, 0)
    }

    func testMalformedGrantDoesNotDiscardValidSiblings() throws {
        let block = ClaudeResetFixture.block.replacingOccurrences(of: "\"grants\":[", with: "\"grants\":[42,{\"id\":\"broken\"},")
        XCTAssertEqual(try response(block).cedarEmber?.credits(at: now)?.availableCount, 1)
    }

    func testMultipleResetsInAGrantExpireTogetherEvenOnAStaleSnapshot() throws {
        let block = ClaudeResetFixture.block.replacingOccurrences(of: "\"resets_left\":1", with: "\"resets_left\":3")
        let credits = try XCTUnwrap(response(block).cedarEmber?.credits(at: now))
        var snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                        fidelity: .official, status: .stale(since: now), windows: [])
        snapshot.resetCredits = credits
        XCTAssertEqual(snapshot.availableResetCredits(at: now)?.availableCount, 3)
        XCTAssertNil(snapshot.availableResetCredits(at: try XCTUnwrap(credits.nextExpiry)))
    }

    func testAResetRequiringTheLimitIsStillUnused() throws {
        let block = ClaudeResetFixture.block.replacingOccurrences(of: "\"usable_now\":true", with: "\"usable_now\":false")
        XCTAssertEqual(try response(block).cedarEmber?.credits(at: now)?.availableCount, 1)
    }
}

enum ClaudeResetFixture {
    // Trimmed from Claude's web/Desktop response on 2026-09-23. No account data.
    static let block = #"{"eligible":true,"ineligible_reason":null,"grants":[{"id":"launch-reset","resets_left":1,"starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00","paused":false,"usable_now":true}]}"#

    static var futureUsage: Data {
        Data("""
        {"limits":[{"kind":"session","percent":8,"resets_at":"2099-01-01T00:00:00Z"}],
         "cedar_ember":\(block.replacingOccurrences(of: "2026-10-22", with: "2099-10-22"))}
        """.utf8)
    }

    // Zstandard fixtures for the existing Chromium cache-entry builder.
    static let availableCacheBody = Data(base64Encoded: "KLUv/SD8FQUAskohHXCn1QHc/yKDuBhENEKuJfZuCP5DpMZsULMCUBWHcxrz+xhB3b4KO6B01mrwNh4QqVDqLHQIFZlcm6SWhD+fgQQq7DnIYsHmSpTqP8QV3LsXdTxi+BFZe2JjTAcoQkVCJ6GzFlJWS3as/D7aAKglfBJ/sDEscLtfqxt0BF4E1CudwT0vAQoA4OukqlLuheHZsd+MYl7ctmFZ3pCasHVR")!
    static let spentCacheBody = Data(base64Encoded: "KLUv/SD8DQUAsgohHWBHrAMaP9V+tBqcNSEsPEAyisCk6iHO5GYKgigucxKT+zFk37gZtmhCazXIPx8IaVAKLUWCikz2j+4lwu9o4IAMew6ymPwwE+Wen+ES9/jNPrKhcBFZ4+OHmA9Y1SEpSorWUvW9ZEVLbo4/AHsJ+Yi8/BwWuG7u7xt0BG8E9i2d4t6bCgDg66SqUu6F4dmx34xiXty2YVnekJqwdVE=")!
    static let malformedCacheBody = Data(base64Encoded: "KLUv/SBfxQIAosUTGoA5bSrLPQpaREC2d73iJCstZAeZ4sGGzBkBjSrO+cLyIxHliQ+hseDMAslQMmQYpnxe5NC9Pn0A511P8gkfLwSqXn1WFhrMDM66uODBTAEAhIKLAg==")!
    static let expiredWindowsCacheBody = Data(base64Encoded: "KLUv/SD8DQUAsgohHXAl1gH+dnGYElXAsJDFxscDATggYyJBI/MAVBUhcxqT+zFl37gd1qhKBNEgHz0wqGKtRGgaVmSyj9ReKvyeCgl02HOQxeWInSj3/BC3uMd/9pERho/IGidHxvxgVQulSWlS1fW9ZEdLbo5Hgr2EnERujg4DXDf39w06gD+EfUvHuPcnCgDg66SqUu6F4dmx34xiXty2YVnekJqwdVE=")!
}
