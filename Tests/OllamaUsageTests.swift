import XCTest
@testable import Codenotch

/// Parses the response from Ollama's `GET /api/usage` endpoint, covering both
/// modern (Pro 20/60/100/500) and legacy plan shapes.
final class OllamaUsageTests: XCTestCase {
    /// Verbatim from the API spec — a modern Pro plan with three models.
    private let modernResponse = """
    {
      "activity": {
        "cost": "0.00000",
        "period": {
          "type": "last_4_weeks",
          "starting_at": "2026-08-17T00:00:00Z",
          "ending_at": "2026-09-08T08:28:05.581584229Z"
        },
        "models": []
      },
      "limits": {
        "monthly": {
          "usage": 0.152,
          "models": [
            { "name": "glm-5.3", "request_count": 468 },
            { "name": "glm-5.3-flash", "request_count": 1176 },
            { "name": "deepseek-v4-flash:0731", "request_count": 3415 }
          ]
        }
      }
    }
    """

    /// Legacy plan shape — session and weekly windows, no monthly, no reset.
    private let legacyResponse = """
    {
      "limits": {
        "session": { "usage": 0.12, "models": [{ "name": "gpt-oss:120b", "request_count": 7 }] },
        "weekly":  { "usage": 0.41, "models": [{ "name": "gpt-oss:120b", "request_count": 86 }] }
      },
      "activity": { "cost": "0.10", "period": { "type": "last_4_weeks" } }
    }
    """

    // MARK: - Modern plans

    func testModernHeadlineIsMonthlyUsageFraction() throws {
        let result = try OllamaUsage.parse(modernResponse)
        XCTAssertEqual(result.headlineID, "monthly")
        let headline = result.windows.first { $0.id == "monthly" }
        XCTAssertEqual(headline?.usedFraction, 0.152)
    }

    func testModernPerModelRows() throws {
        let result = try OllamaUsage.parse(modernResponse)
        let modelRows = result.windows.filter { $0.id.hasPrefix("monthly.") }
        XCTAssertEqual(modelRows.count, 3)
        XCTAssertEqual(modelRows.first?.label, "glm-5.3")
        XCTAssertEqual(modelRows.first?.used, 468)
        XCTAssertNil(modelRows.first?.usedFraction)
    }

    func testModernHasNoResetDateBecauseApiDoesNotExposeBillingCycle() throws {
        let result = try OllamaUsage.parse(modernResponse)
        let monthly = result.windows.first { $0.id == "monthly" }
        // The API exposes only a rolling 4-week activity window, not the billing
        // cycle reset — so `resetsAt` must be nil rather than a guess.
        XCTAssertNil(monthly?.resetsAt)
    }

    // MARK: - Legacy plans

    func testLegacyHasSessionAndWeeklyWindows() throws {
        let result = try OllamaUsage.parse(legacyResponse)
        XCTAssertNotNil(result.windows.first { $0.id == "session" })
        XCTAssertNotNil(result.windows.first { $0.id == "weekly" })
        XCTAssertNil(result.windows.first { $0.id == "monthly" })
    }

    func testLegacyHeadlineIsWeekly() throws {
        let result = try OllamaUsage.parse(legacyResponse)
        XCTAssertEqual(result.headlineID, "weekly")
    }

    func testLegacyModelRows() throws {
        let result = try OllamaUsage.parse(legacyResponse)
        let sessionModel = result.windows.first { $0.id == "session.gpt-oss:120b" }
        XCTAssertEqual(sessionModel?.used, 7)
        let weeklyModel = result.windows.first { $0.id == "weekly.gpt-oss:120b" }
        XCTAssertEqual(weeklyModel?.used, 86)
    }

    func testLegacyHasNoResetDate() throws {
        let result = try OllamaUsage.parse(legacyResponse)
        let session = result.windows.first { $0.id == "session" }
        XCTAssertNil(session?.resetsAt)
    }

    // MARK: - Edge cases

    func testEmptyUsageThrowsNothingMetered() {
        let empty = """
        { "activity": { "cost": "0.00", "period": {}, "models": [] },
          "limits": { "monthly": { "usage": 0, "models": [] } } }
        """
        XCTAssertThrowsError(try OllamaUsage.parse(empty)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testModelsOnlyWithZeroUsage() throws {
        // No usage fraction, but models have request counts — the model rows
        // keep the result from being "nothing metered".
        let noFraction = """
        { "activity": { "period": { "ending_at": "2026-09-08T08:28:05Z" } },
          "limits": { "monthly": {
            "usage": 0,
            "models": [ { "name": "tiny", "request_count": 3 } ] } } }
        """
        let result = try OllamaUsage.parse(noFraction)
        XCTAssertNil(result.headlineID)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.label, "tiny")
        XCTAssertEqual(result.windows.first?.used, 3)
    }

    func testGarbageThrowsBadResponse() {
        XCTAssertThrowsError(try OllamaUsage.parse("not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    // MARK: - Cloud totals & buckets (Issue #436)

    func testCloudTotalsRequestCountFromIssue436() throws {
        let issueJson = """
        {
          "range": "7d",
          "scope": "self",
          "granularity": "day",
          "from": "2026-10-01T00:00:00Z",
          "until": "2026-10-08T18:59:58Z",
          "totals": { "request_count": 6912 },
          "buckets": [
            { "from": "2026-10-01T00:00:00Z", "until": "2026-10-02T00:00:00Z", "request_count": 895 }
          ]
        }
        """
        let result = try OllamaUsage.parse(issueJson)
        XCTAssertEqual(result.headlineID, "requests")
        let requestsWindow = result.windows.first { $0.id == "requests" }
        XCTAssertNotNil(requestsWindow)
        XCTAssertEqual(requestsWindow?.used, 6912)
        XCTAssertEqual(requestsWindow?.label, "Requests (7d)")
        XCTAssertNil(requestsWindow?.usedFraction)
        XCTAssertNil(requestsWindow?.resetsAt)
        XCTAssertNotNil(requestsWindow?.duration)
    }

    func testCloudTotalsWithCostAndTokens() throws {
        let json = """
        {
          "range": "24h",
          "scope": "self",
          "granularity": "hour",
          "from": "2026-10-07T00:00:00Z",
          "until": "2026-10-08T00:00:00Z",
          "totals": {
            "request_count": 125,
            "usage_usd": 0.01718,
            "input_tokens": 106000,
            "output_tokens": 13600
          }
        }
        """
        let result = try OllamaUsage.parse(json)
        XCTAssertEqual(result.headlineID, "requests")
        XCTAssertEqual(result.windows.count, 3)

        let requests = result.windows.first { $0.id == "requests" }
        XCTAssertEqual(requests?.used, 125)
        XCTAssertEqual(requests?.label, "Requests (24h)")

        let cost = result.windows.first { $0.id == "cost" }
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost?.label, "Cost")
        XCTAssertEqual(cost?.usedText, "$0.02")

        let tokens = result.windows.first { $0.id == "tokens" }
        XCTAssertNotNil(tokens)
        XCTAssertEqual(tokens?.label, "Tokens")
        XCTAssertEqual(tokens?.used, 119600)
    }

    func testCloudBucketsFallbackWithoutTotals() throws {
        let json = """
        {
          "range": "7d",
          "buckets": [
            { "request_count": 100 },
            { "request_count": 250 }
          ]
        }
        """
        let result = try OllamaUsage.parse(json)
        XCTAssertEqual(result.headlineID, "requests")
        let requests = result.windows.first { $0.id == "requests" }
        XCTAssertEqual(requests?.used, 350)
        XCTAssertEqual(requests?.label, "Requests (7d)")
    }

    func testCloudEmptyTotalsThrowsNothingMetered() {
        let empty = """
        {
          "range": "7d",
          "totals": { "request_count": 0 },
          "buckets": []
        }
        """
        XCTAssertThrowsError(try OllamaUsage.parse(empty)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// The cloud summary can carry the same model in its totals and at the
    /// top level; the tooltip lists it once.
    func testAModelNamedTwiceInTheSummaryIsListedOnce() throws {
        let json = """
        {
          "range": "7d",
          "totals": { "request_count": 12, "models": [{ "name": "gpt-oss:120b", "request_count": 12 }] },
          "models": [{ "name": "gpt-oss:120b", "request_count": 12 }],
          "activity": { "models": [{ "name": "gpt-oss:120b", "request_count": 12 }] }
        }
        """
        let result = try OllamaUsage.parse(json)
        XCTAssertEqual(result.windows.filter { $0.label == "gpt-oss:120b" }.count, 1)
    }

}
