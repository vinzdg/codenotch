import SwiftUI
import XCTest
@testable import Codenotch

final class OpenAIAPICreditTests: XCTestCase {
    func testConsecutiveRefreshesUpdateActivityWithoutChangingTheSavedBalance() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-10T18:00:00Z"))
        let grant = OpenAIAPICreditGrant(issued: "2026-06-01", expires: "2026-07-01",
                                        granted: 435, available: Decimal(string: "433.26")!, recordedAt: now)
        let provider = OpenAIAPICreditsProvider()
        let old = CodexTokenUsage(dailyUsageBuckets: [.init(startDate: "2026-06-10", tokens: 25)])
        let new = CodexTokenUsage(dailyUsageBuckets: [.init(startDate: "2026-06-10", tokens: 45)])
        let first = try await provider.fetchSnapshot(grant: grant, now: now) { _ in old }
        let next = try await provider.fetchSnapshot(grant: grant, now: now.addingTimeInterval(1)) { _ in new }

        XCTAssertEqual(first.usedFraction, 0.004)
        XCTAssertEqual(next.usedFraction, first.usedFraction)
        XCTAssertEqual(next.headline?.label, "Saved credit balance")
        XCTAssertEqual(next.fidelity, .manual)
        XCTAssertEqual(next.tokenUsage, new)
        XCTAssertFalse(provider.skipsIdleRefresh)
    }

    func testExistingSavedGrantDecodesWithoutTreatingItAsAFreshBalance() throws {
        let json = #"{"issued":"2026-06-01","expires":"2026-07-01","granted":100,"available":75,"costAtSnapshot":3}"#
        let grant = try JSONDecoder().decode(OpenAIAPICreditGrant.self, from: Data(json.utf8))
        XCTAssertNil(grant.recordedAt)
        XCTAssertEqual(grant.windows().first?.usedFraction, 0.25)
    }

    func testExpiredGrantStillRefreshesActivityButDoesNotPublishABalance() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-02T18:00:00Z"))
        let grant = OpenAIAPICreditGrant(issued: "2026-06-01", expires: "2026-07-01",
                                        granted: 100, available: 75, recordedAt: nil)
        let metrics = CodexTokenUsage(dailyUsageBuckets: [.init(startDate: "2026-07-02", tokens: 25)])
        let snapshot = try await OpenAIAPICreditsProvider().fetchSnapshot(grant: grant, now: now) { _ in metrics }
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertEqual(snapshot.tokenUsage, metrics)
    }

    func testFailedActivityRefreshDoesNotServeStaleTokensAsFresh() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-10T18:00:00Z"))
        let grant = OpenAIAPICreditGrant(issued: "2026-06-01", expires: "2026-07-01",
                                        granted: 100, available: 75, recordedAt: nil)
        let provider = OpenAIAPICreditsProvider()
        do {
            _ = try await provider.fetchSnapshot(grant: grant, now: now) { _ in
                throw UsageProviderError.badResponse(status: 500)
            }
            XCTFail("An unsuccessful refresh must not return an OK snapshot.")
        } catch UsageProviderError.badResponse(let status) {
            XCTAssertEqual(status, 500)
        }
    }

    func testGrantDateAndValueValidation() throws {
        XCTAssertNil(OpenAIAPICreditGrant.midnight("2026-02-30", timeZone: TimeZone(secondsFromGMT: 0)!))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-10T18:00:00Z"))
        XCTAssertNil(OpenAIAPICreditGrant.validated(
            issued: "2026-06-01", expires: "2026-07-01", granted: "100x", available: "10", now: now))
        XCTAssertNil(OpenAIAPICreditGrant.validated(
            issued: "2026-06-01", expires: "2026-06-09", granted: "100", available: "10", now: now))
    }

    @MainActor
    func testMenuAndNotchUsePercentageAndKeepDateInDetails() throws {
        let grant = OpenAIAPICreditGrant(issued: "2026-06-01", expires: "2026-07-01",
                                        granted: 100, available: 75, recordedAt: nil)
        let windows = grant.windows()
        let snapshot = ProviderSnapshot(id: "openai-api-credits", displayName: "ChatGPT API",
                                        glyph: .openaiAPI, fidelity: .derived, status: .ok,
                                        windows: windows, headlineID: windows.first?.id)
        XCTAssertEqual(snapshot.headlineText, "25%")
        XCTAssertEqual(StatusItemController.headline(for: snapshot), "25%")
        XCTAssertEqual(StatusItemController.headerTitle(for: snapshot, now: Date()), "ChatGPT API — 25%")
        XCTAssertEqual(windows.first?.resetDateLabel, "2026-07-01")
        XCTAssertTrue(StatusItemController.windowLine(for: try XCTUnwrap(windows.first), now: Date())
            .contains(ResetCopy.text(forDateOnly: "2026-07-01", now: Date())))
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows.first?.resetsAt)
    }
    @MainActor
    func testCreditCardUsesTheNativeCodexActivityLayout() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-10T18:00:00Z"))
        let windows = [LimitWindow(id: "quota", label: "Plan", usedFraction: 0.25)]
        let days = [CodexTokenUsage.DailyBucket(startDate: "2026-06-10", tokens: 25)]
        let codex = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                                     fidelity: .derived, status: .ok, windows: windows,
                                     tokenUsage: CodexTokenUsage(dailyUsageBuckets: days))
        let api = ProviderSnapshot(id: OpenAIAPICreditsProvider.providerID, displayName: "ChatGPT API",
                                   glyph: OpenAIAPICreditsProvider().glyph, fidelity: .derived,
                                   status: .ok, windows: windows, tokenUsage: CodexTokenUsage(
                                    dailyUsageBuckets: days, apiMetrics: .init(
                                        requests: 2, input: 20, cachedInput: 10, output: 5)))

        func render(_ snapshot: ProviderSnapshot) throws -> NSImage {
            try XCTUnwrap(ImageRenderer(content: TooltipCard(snapshot: snapshot, now: now)
                .environment(\.codenotchHeadlessGlass, true)).nsImage)
        }

        XCTAssertEqual(try render(api).size, try render(codex).size)
        XCTAssertEqual(api.glyph, .openaiAPI)
        XCTAssertNotEqual(api.glyph.outline, codex.glyph.outline)
    }

    func testDateOnlyResetUsesLocaleAndRelativeDaysWithoutATime() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-02T00:15:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let us = Locale(identifier: "en_US")
        let gb = Locale(identifier: "en_GB")
        func stamp(_ day: String, locale: Locale = Locale(identifier: "en_US")) -> String {
            ResetCopy.dateOnlyStamp(day, now: now, timeZone: zone, locale: locale)
        }
        XCTAssertEqual(stamp("2026-12-12", locale: us), "Dec 12")
        XCTAssertEqual(stamp("2026-12-12", locale: gb), "12 Dec")
        XCTAssertEqual(stamp("2026-12-01"), "today")
        XCTAssertEqual(stamp("2026-12-02"), "tomorrow")
        XCTAssertEqual(stamp("2026-12-07"), "in 6 days")
        XCTAssertEqual(stamp("2026-12-08"), "Dec 8")
        XCTAssertEqual(stamp("2026-02-30"), "2026-02-30")
    }

    func testUsageDashboardMetricsAndChartDoNotDoubleCountCache() async throws {
        let json = #"{"data":[{"start_time":0,"end_time":86400,"results":[{"num_model_requests":2,"input_tokens":20,"input_cached_tokens":10,"output_tokens":5}]}],"has_more":false}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try await OpenAIAPIUsage.metrics(start: 0) { _ in
            try decoder.decode(OpenAIAPIUsage.Page.self, from: Data(json.utf8))
        }
        XCTAssertEqual(usage.apiMetrics, .init(requests: 2, input: 20, cachedInput: 10, output: 5))
        XCTAssertEqual(usage.dailyUsageBuckets, [.init(startDate: "1970-01-01", tokens: 25)])
        XCTAssertEqual(usage.peakDailyTokens, 25)
        let encoded = try JSONEncoder().encode(usage)
        XCTAssertEqual(try JSONDecoder().decode(CodexTokenUsage.self, from: encoded), usage)
    }
}
