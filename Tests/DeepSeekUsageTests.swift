import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class DeepSeekUsageTests: XCTestCase {
    func testPricingUsesDeepSeekUTCWeekdayAndWindows() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T02:00:00Z"))), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T04:00:00Z"))), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T07:00:00Z"))), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T10:00:00Z"))), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-13T02:00:00Z"))), .offPeak)
    }

    func testPricingFindsTheNextLocalBillingPhaseBoundaryInUTC() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let now = try XCTUnwrap(formatter.date(from: "2026-09-14T02:30:00Z"))
        let transition = DeepSeekPricing.nextTransition(after: now)

        XCTAssertEqual(transition.phase, .offPeak)
        XCTAssertEqual(transition.date,
                       try XCTUnwrap(formatter.date(from: "2026-09-14T04:00:00Z")))

        let friday = try XCTUnwrap(formatter.date(from: "2026-09-18T10:30:00Z"))
        let monday = DeepSeekPricing.nextTransition(after: friday)
        XCTAssertEqual(monday.phase, .peak)
        XCTAssertEqual(monday.date,
                       try XCTUnwrap(formatter.date(from: "2026-09-21T01:00:00Z")))
    }

    func testPricingUsesTheMaintainedSchedule() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [2],
            windows: [.init(startMinute: 120, endMinute: 180)]
        )

        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T02:30:00Z")),
            schedule: schedule
        ), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T03:00:00Z")),
            schedule: schedule
        ), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-15T02:30:00Z")),
            schedule: schedule
        ), .offPeak)
    }

    func testPricingSupportsMoreThanTwoPeakWindows() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [2],
            windows: [
                .init(startMinute: 60, endMinute: 120),
                .init(startMinute: 360, endMinute: 420),
                .init(startMinute: 1_080, endMinute: 1_140)
            ]
        )

        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T18:30:00Z")),
            schedule: schedule
        ), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T19:00:00Z")),
            schedule: schedule
        ), .offPeak)
    }

    /// Trimmed from holiday-cn's 2026.json: National Day, the Spring Festival,
    /// and a make-up working day, which must not count as a day off.
    private static let holidays2026 = #"""
    {"year": 2026, "papers": [], "days": [
      {"name": "春节", "date": "2026-02-15", "isOffDay": true},
      {"name": "春节", "date": "2026-02-16", "isOffDay": true},
      {"name": "春节", "date": "2026-02-17", "isOffDay": true},
      {"name": "春节", "date": "2026-02-18", "isOffDay": true},
      {"name": "春节", "date": "2026-02-19", "isOffDay": true},
      {"name": "春节", "date": "2026-02-20", "isOffDay": true},
      {"name": "春节", "date": "2026-02-21", "isOffDay": true},
      {"name": "春节", "date": "2026-02-22", "isOffDay": true},
      {"name": "春节", "date": "2026-02-23", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-01", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-02", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-05", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-06", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-07", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-10", "isOffDay": false}
    ]}
    """#

    private func holidayCalendar() throws -> ChineseHolidayCalendar {
        try XCTUnwrap(ChineseHolidayCalendar.empty.merging(holidayCNJSON: Data(Self.holidays2026.utf8)))
    }

    func testChineseHolidaysAreOffPeakOnAWeekday() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let holidays = try holidayCalendar()
        // Friday 2 October 2026, 10:00 in Beijing.
        let nationalDay = try XCTUnwrap(formatter.date(from: "2026-10-02T02:00:00Z"))

        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: .current, holidays: holidays), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: .current), .peak)

        var weekdaysOnly = DeepSeekPricing.Schedule.current
        weekdaysOnly.offPeakOnChineseHolidays = false
        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: weekdaysOnly, holidays: holidays), .peak)

        // Thursday 8 October is a working day again.
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-10-08T02:00:00Z")),
            schedule: .current, holidays: holidays
        ), .peak)
    }

    func testHolidayCalendarIgnoresMakeUpDaysAndUnpublishedYears() throws {
        let holidays = try holidayCalendar()

        XCTAssertEqual(holidays.years, [2026])
        XCTAssertTrue(holidays.offDays.contains("2026-10-01"))
        XCTAssertFalse(holidays.offDays.contains("2026-10-10"))
        XCTAssertNil(holidays.merging(holidayCNJSON: Data(#"{"year": 2027, "papers": [], "days": []}"#.utf8)))
        XCTAssertNil(holidays.merging(holidayCNJSON: Data("not json".utf8)))
    }

    func testNextPeakSkipsTheWholeHoliday() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let holidays = try holidayCalendar()

        let nationalDay = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-10-02T02:00:00Z")),
            schedule: .current, holidays: holidays
        )
        XCTAssertEqual(nationalDay.phase, .peak)
        XCTAssertEqual(nationalDay.date, try XCTUnwrap(formatter.date(from: "2026-10-08T01:00:00Z")))

        // Friday evening before the Spring Festival: eleven days to the next peak.
        let springFestival = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-02-13T10:30:00Z")),
            schedule: .current, holidays: holidays
        )
        XCTAssertEqual(springFestival.phase, .peak)
        XCTAssertEqual(springFestival.date, try XCTUnwrap(formatter.date(from: "2026-02-24T01:00:00Z")))
    }

    func testAHolidayEndsAWindowThatRunsAcrossBeijingMidnight() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [1, 2, 3, 4, 5, 6, 7],
            windows: [.init(startMinute: 900, endMinute: 1_020)]
        )

        let transition = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-09-30T15:30:00Z")),
            schedule: schedule, holidays: try holidayCalendar()
        )
        XCTAssertEqual(transition.phase, .offPeak)
        XCTAssertEqual(transition.date, try XCTUnwrap(formatter.date(from: "2026-09-30T16:00:00Z")))
    }

    func testAScheduleSavedBeforeTheHolidayRuleStillDecodes() throws {
        let saved = #"{"peakWeekdays": [2, 3], "windows": [{"startMinute": 60, "endMinute": 240}]}"#
        let schedule = try JSONDecoder().decode(DeepSeekPricing.Schedule.self, from: Data(saved.utf8))

        XCTAssertEqual(schedule.peakWeekdays, [2, 3])
        XCTAssertTrue(schedule.offPeakOnChineseHolidays)
    }

    func testTheBundledHolidayCalendarCoversTheYearItShipsWith() {
        XCTAssertTrue(ChineseHolidays.bundled.years.contains(2026))
        XCTAssertNotNil(Bundle.main.url(forResource: "holiday-cn-LICENSE", withExtension: "txt"))
    }

    func testDisablingPricingOnlyRemovesPricingRowsFromTheCardHeight() {
        XCTAssertGreaterThan(
            NotchLayout.usageDetailHeight(1, showsPricing: true),
            NotchLayout.usageDetailHeight(1, showsPricing: false)
        )
    }

    func testSwitchGateIgnoresTheExistingSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testNormalSignInDoesNotCommitAnExistingSessionBeforeLogout() {
        var gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testManualCloseCanCommitACompletedNormalSignIn() {
        let gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: false,
            fingerprint: nil
        ))
    }

    func testManualCloseCannotCommitTheExistingAccountDuringASwitch() {
        let gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "new"
        ))
    }

    func testDeepSeekAuthenticationProbeUsesThePlatformHeader() {
        let probe = try! XCTUnwrap(Sites.deepSeek.authProbeScript)

        XCTAssertTrue(probe.contains("'x-client-platform': 'web'"))
    }

    func testSwitchGateCommitsOnlyAfterLogoutAndANewSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "new"))
    }

    func testSignedInSessionAppearsAsAnAccountInSettings() {
        let key = "deepseek.signedIn"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let provider = WebSessionProvider(site: Sites.deepSeek)
        let account = provider.account()

        XCTAssertNotNil(account)
        XCTAssertEqual(account?.source, "DeepSeek")
        XCTAssertEqual(account?.manageURL?.absoluteString, "https://platform.deepseek.com/usage")
    }

    func testPlatformSummaryBuildsMoneyWindow() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.87"}],"total_costs":[{"currency":"CNY","amount":"9.20"}],"total_available_token_estimation":"3300000"}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.spent, 9.20, accuracy: 0.001)
        XCTAssertEqual(reading.balance, 10.87, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
        XCTAssertEqual(reading.availableTokens, 3_300_000)
    }

    func testAmountAndCostSeriesMergeByAPIKeyAndModel() throws {
        let summary = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"1"}],"total_costs":[]}}}"#
        let amountObject: [String: Any] = ["data": ["biz_data": ["series": [[
            "api_key": ["name": "main", "tracking_id": "key-1"],
            "model": "deepseek-chat", "buckets": [[
                "time": 1800000000,
                "usage": ["PROMPT_CACHE_HIT_TOKEN": "100", "PROMPT_CACHE_MISS_TOKEN": 50,
                           "RESPONSE_TOKEN": 25, "REQUEST": 2]
            ]]
        ]]]]]
        let amount = String(data: try JSONSerialization.data(withJSONObject: amountObject), encoding: .utf8)!
        let costObject: [String: Any] = ["data": ["biz_data": ["data": [[
            "currency": "CNY", "series": [[
                "api_key": ["name": "main", "tracking_id": "key-1"],
                "model": "deepseek-chat", "buckets": [["time": 1800000000, "cost": "0.12"]]
            ]]
        ]]]]]
        let cost = String(data: try JSONSerialization.data(withJSONObject: costObject), encoding: .utf8)!
        let object: [String: Any] = ["summary": summary, "amount": amount, "cost": cost,
                                      "start": 1800000000, "end": 1800086400,
                                      "time_zone_seconds": 28800]
        let payload = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let detail = try XCTUnwrap(DeepSeekUsage.detail(fromJSON: payload))
        let group = try XCTUnwrap(detail.groups.first)
        XCTAssertEqual(group.apiKeyLabel, "main")
        XCTAssertEqual(group.model, "deepseek-chat")
        XCTAssertEqual(group.totalTokens, 175)
        XCTAssertEqual(group.requests, 2)
        XCTAssertEqual(group.totalCost, 0.12, accuracy: 0.001)
        XCTAssertEqual(detail.visibleAPIKeyCount, 1)
        XCTAssertEqual(detail.totalTokens, 175)
        XCTAssertEqual(detail.totalRequests, 2)
    }

    func testDeepSeekCardRendersMoneySummaryAndCharts() throws {
        let detail = ProviderUsageDetail(
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_086_400),
            timeZoneSeconds: 28_800,
            currency: "CNY",
            groups: [UsageDetailGroup(apiKeyID: "key-1", apiKeyLabel: "main",
                                      model: "deepseek-chat",
                                      days: [UsageDetailDay(date: Date(timeIntervalSince1970: 1_800_000_000),
                                                            cacheHitTokens: 100,
                                                            cacheMissTokens: 50,
                                                            outputTokens: 25,
                                                            requests: 2,
                                                            cost: 0.12)])]
        )
        let snapshot = ProviderSnapshot(
            id: "deepseek", displayName: "DeepSeek", glyph: .deepseek,
            fidelity: .derived, status: .ok,
            windows: [LimitWindow(id: "spend", label: "Account usage (CNY)",
                                  usedFraction: 9.20 / 20.07,
                                  money: UsageMoneyBreakdown(currency: "CNY", spent: 9.20, remaining: 10.87))],
            usageDetail: detail
        )
        let image = try XCTUnwrap(ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date())).nsImage)
        XCTAssertGreaterThan(image.size.height, NotchLayout.cardHeight(windowCount: 1) + NotchLayout.usageDetailChartHeight)
        if let path = ProcessInfo.processInfo.environment["DEEPSEEK_TOOLTIP_RENDER_PATH"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
